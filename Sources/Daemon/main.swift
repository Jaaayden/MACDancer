import Foundation

/// Caches the LinkLiar check: it forks `launchctl`, so it runs at launch and
/// then every ten minutes instead of on every request.
final class LegacyServiceCache: @unchecked Sendable {
  private let lock = NSLock()
  private var detected = false

  var value: Bool { lock.withLock { detected } }

  func refresh() {
    let result = LegacyServiceDetector.isInstalled()
    lock.withLock { detected = result }
  }
}

/// Notices when the app bundle around this executable is replaced by an
/// update. The running process keeps the old binary open, so it exits and lets
/// launchd start the new one (KeepAlive restarts it after a non-zero exit).
struct ExecutableWatcher {
  let path: String
  private let original: (dev: Int32, ino: UInt64, mtime: Int)?

  init() {
    path = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    original = Self.identity(of: path)
  }

  /// True only when a *different* executable now exists at the same path. A
  /// missing file (app moved to the Trash) does not count: relaunching would fail.
  var wasReplaced: Bool {
    guard let original, let current = Self.identity(of: path) else { return false }
    return current.dev != original.dev || current.ino != original.ino || current.mtime != original.mtime
  }

  private static func identity(of path: String) -> (dev: Int32, ino: UInt64, mtime: Int)? {
    var info = stat()
    guard stat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
    return (info.st_dev, info.st_ino, info.st_mtimespec.tv_sec)
  }
}

/// The daemon lives at App.app/Contents/MacOS/<daemon>; read the app's version.
func appBundleVersion(executablePath: String) -> String? {
  let appURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  return Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
}

let watcher = ExecutableWatcher()
let version = appBundleVersion(executablePath: watcher.path)
Log.daemon.notice("MACDancer daemon \(version ?? "?", privacy: .public) starting (protocol \(MACDancerConstants.protocolVersion))")

let legacyCache = LegacyServiceCache()
legacyCache.refresh()

let reader = SystemInterfaceReader()
let coordinator = DaemonCoordinator(environment: .init(
  reader: reader,
  writer: MACWriter(runner: ProcessRunner(), wifi: WiFiController(), reader: reader),
  store: ConfigurationStore(),
  legacyServiceDetected: { legacyCache.value },
  version: version
))

let monitor = SystemEventMonitor { coordinator.handle($0) }
do {
  try monitor.start()
} catch {
  let message = MACDancerError(error).message
  Log.daemon.error("\(message, privacy: .public)")
  coordinator.setWarning("monitor", "\(message) Automatic rotation after sleep, wake or network changes will not run.")
}

let listener: DaemonListener
do {
  listener = try DaemonListener(coordinator: coordinator)
} catch {
  Log.daemon.fault("\(MACDancerError(error).message, privacy: .public)")
  exit(EXIT_FAILURE)
}
listener.resume()

let tickTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
tickTimer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
tickTimer.setEventHandler { coordinator.tick() }
tickTimer.resume()

let legacyTimer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
legacyTimer.schedule(deadline: .now() + 600, repeating: 600, leeway: .seconds(30))
legacyTimer.setEventHandler { legacyCache.refresh() }
legacyTimer.resume()

// Checked every 10 s (a single stat call). Waits for any running MAC write.
let updateTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
updateTimer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
updateTimer.setEventHandler {
  guard watcher.wasReplaced else { return }
  coordinator.whenIdle {
    Log.daemon.notice("The app was updated; exiting so launchd starts the new daemon")
    exit(75) // EX_TEMPFAIL: non-zero, so launchd relaunches us
  }
}
updateTimer.resume()

dispatchMain()
