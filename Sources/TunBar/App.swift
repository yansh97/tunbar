import AppKit
import Darwin
import Dispatch
import ServiceManagement
import UserNotifications

#if !arch(arm64)
  #error("TunBar supports Apple Silicon (arm64) only.")
#endif

@main
@MainActor
final class App: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private var notificationAuthorization: Task<Void, Never>?

  static func main() {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }

  func applicationWillFinishLaunching(_: Notification) {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let firstInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).min
    {
      ($0.launchDate ?? .distantPast, $0.processIdentifier)
        < ($1.launchDate ?? .distantPast, $1.processIdentifier)
    }
    if let firstInstance, firstInstance.processIdentifier != getpid() {
      firstInstance.activate(options: [])
      NSApp.terminate(nil)
    }
  }

  func applicationDidFinishLaunching(_: Notification) {
    UNUserNotificationCenter.current().delegate = self
    notificationAuthorization = Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }
    statusItem.button?.image = NSImage(
      systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "TunBar")
    statusItem.button?.setAccessibilityLabel("TunBar")
    statusItem.button?.target = self
    statusItem.button?.action = #selector(showMenu(_:))
    statusItem.button?.sendAction(on: .leftMouseUp)
    requestScan()
  }

  func applicationWillTerminate(_: Notification) {
    scanTask?.cancel()
    for alias in pidByAlias.keys { stopTunnel(alias) }
  }

  @objc private func showMenu(_ button: NSStatusBarButton) {
    guard NSApp.currentEvent?.modifierFlags.contains(.control) != true else { return }
    let menu = NSMenu()
    func addItem(_ title: String, action: Selector, isChecked: Bool = false) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = self
      item.state = isChecked ? .on : .off
    }

    addItem("登录时启动", action: #selector(toggleLoginItem), isChecked: isLoginItemRegistered)
    menu.addItem(.separator())
    for alias in configuredAliases.sorted() {
      addItem(alias, action: #selector(toggleTunnel(_:)), isChecked: pidByAlias[alias] != nil)
    }
    if !configuredAliases.isEmpty { menu.addItem(.separator()) }
    addItem("扫描配置", action: #selector(requestScan))
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    ).target = NSApp
    menu.popUp(
      positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY), in: button)
  }

  private var isLoginItemRegistered: Bool {
    let status = SMAppService.mainApp.status
    return status == .enabled || status == .requiresApproval
  }

  @objc private func toggleLoginItem() {
    let service = SMAppService.mainApp
    let wasRegistered = isLoginItemRegistered
    do {
      if wasRegistered {
        try service.unregister()
      } else {
        try service.register()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
      }
    } catch {
      let alert = NSAlert()
      alert.messageText = wasRegistered ? "登录项停用失败" : "登录项启用失败"
      alert.addButton(withTitle: "确认")
      NSApp.activate()
      alert.runModal()
    }
  }

  private var configuredAliases: Set<String> = []
  private var scanTask: Task<Void, Never>?

  @objc private func requestScan() {
    guard scanTask == nil else { return }
    scanTask = Task(priority: .utility) {
      defer { scanTask = nil }
      let aliases = try? await Self.readTunnelAliases()
      guard !Task.isCancelled else { return }
      guard let aliases else {
        notify("配置扫描失败", body: "~/.ssh/config")
        return
      }
      configuredAliases = aliases
      for alias in pidByAlias.keys where !aliases.contains(alias) {
        stopTunnel(alias)
        notify("隧道失效关闭", body: alias)
      }
    }
  }

  nonisolated private static func readTunnelAliases(
    at url: URL = .homeDirectory.appending(path: ".ssh/config")
  ) async throws -> Set<String> {
    let contents = try String(contentsOf: url, encoding: .utf8)
    guard !contents.utf8.contains(where: { $0 == 0 || $0 == 13 }) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let hostPrefix = /Host[ \t]+/
    let quoteOrEscape = /['"\\]/
    let aliasPattern = /(?:[A-Za-z0-9]+-)+tun/
    var aliases: Set<String> = []
    for line in contents.split(separator: "\n") {
      guard let directive = line.prefixMatch(of: hostPrefix) else { continue }
      let fields = line[directive.range.upperBound...]
        .split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix { !$0.hasPrefix("#") }
      guard fields.first?.first != "=", !fields.contains(where: { $0.contains(quoteOrEscape) })
      else {
        continue
      }
      for alias in fields where alias.wholeMatch(of: aliasPattern) != nil {
        aliases.insert(String(alias))
      }
    }
    return aliases
  }

  private var pidByAlias: [String: pid_t] = [:]

  @objc private func toggleTunnel(_ item: NSMenuItem) {
    let alias = item.title
    if item.state == .on {
      stopTunnel(alias)
      return
    }
    guard configuredAliases.contains(alias), pidByAlias[alias] == nil else { return }

    guard let pid = Self.spawnSSH(alias) else {
      notify("隧道建立失败", body: alias)
      return
    }
    pidByAlias[alias] = pid
    let exitSource = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: .exit, queue: .main)
    exitSource.setEventHandler {
      exitSource.cancel()
      Self.stopProcessGroup(pid)
      var exitStatus: Int32 = 0
      var reapedPID: pid_t
      repeat { reapedPID = waitpid(pid, &exitStatus, 0) } while reapedPID < 0 && errno == EINTR
      guard self.pidByAlias[alias] == pid else { return }
      self.pidByAlias[alias] = nil
      if reapedPID == pid && exitStatus != 0 { self.notify("隧道意外停止", body: alias) }
    }
    exitSource.activate()
  }

  private static func spawnSSH(_ alias: String) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attributes) }

    var signalMask = sigset_t()
    var defaultSignals = sigset_t()
    for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaultSignals, signal) }
    let flags =
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_CLOEXEC_DEFAULT
    guard
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
      posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
      posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
      posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
      posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
      posix_spawnattr_setflags(&attributes, Int16(flags)) == 0
    else { return nil }

    let arguments = [
      "/usr/bin/ssh", "-N", "-n", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
      "-o", "ForkAfterAuthentication=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
      "-o", "ControlPersist=no", "-o", "ServerAliveInterval=60", "-o", "ServerAliveCountMax=3",
      "--", alias,
    ]
    var argv = arguments.map { strdup($0) }
    defer { for string in argv { free(string) } }
    guard argv.allSatisfy({ $0 != nil }) else { return nil }
    argv.append(nil)
    var pid: pid_t = 0
    guard posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, environ) == 0 else {
      return nil
    }
    return pid
  }

  private func stopTunnel(_ alias: String) {
    if let pid = pidByAlias.removeValue(forKey: alias) { Self.stopProcessGroup(pid) }
  }

  private static func stopProcessGroup(_ pid: pid_t) {
    guard pid > 1 else { return }
    _ = kill(-pid, SIGKILL)
  }

  private func notify(_ title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    Task {
      await notificationAuthorization?.value
      try? await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }

  nonisolated func userNotificationCenter(
    _: UNUserNotificationCenter, willPresent _: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }
}
