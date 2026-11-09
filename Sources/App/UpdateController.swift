import AppKit
import Foundation
import Security

/// Checks GitHub for a newer release and installs it in place.
///
/// An update is installed only if its code signature is valid and comes from
/// the same developer team as the running app; the download location is not
/// trusted on its own. After the swap the app relaunches, and the daemon
/// notices its executable changed and restarts into the new version.
@MainActor
final class UpdateController: ObservableObject {
  static let autoCheckKey = "automaticallyCheckForUpdates"
  static let lastCheckKey = "lastUpdateCheck"

  @Published private(set) var state: UpdateState = .idle
  /// Results of a check the user asked for are shown; background ones only when an update exists.
  @Published private(set) var lastCheckWasManual = false
  @Published var automaticallyChecks: Bool {
    didSet { UserDefaults.standard.set(automaticallyChecks, forKey: Self.autoCheckKey) }
  }

  let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  private let teamIdentifier = CodeSigningIdentity.currentTeamIdentifier()

  init() {
    let defaults = UserDefaults.standard
    automaticallyChecks = defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true
  }

  /// Why this copy cannot update itself, or nil when it can.
  var installBlockedReason: String? {
    if teamIdentifier == nil {
      return L("update.blocked.unsigned", "This build is not signed with a developer team, so updates cannot be verified. Download the release manually.")
    }
    if !FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) {
      return L("update.blocked.location", "MACDancer cannot write to the folder it is in. Move it to Applications or download the release manually.")
    }
    return nil
  }

  var isBusy: Bool {
    switch state {
    case .checking, .downloading, .installing: true
    default: false
    }
  }

  func checkOnLaunchIfDue() {
    let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    guard automaticallyChecks, UpdatePlanner.isCheckDue(lastCheck: last) else { return }
    check(userInitiated: false)
  }

  func check(userInitiated: Bool) {
    guard !isBusy else { return }
    state = .checking
    lastCheckWasManual = userInitiated
    Task {
      do {
        var request = URLRequest(url: UpdatePlanner.latestReleaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MACDancer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await FileDownloader.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        if status == 404 {
          state = .upToDate // No release published yet.
          return
        }
        guard status == 200 else { throw UpdateError.http(status) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        if let update = UpdatePlanner.update(from: release, current: currentVersion) {
          state = .available(update)
        } else {
          state = .upToDate
        }
      } catch {
        // A silent background check that fails stays quiet.
        state = userInitiated ? .failed(Self.describe(error)) : .idle
      }
    }
  }

  /// Hides a finished manual check ("up to date" or an error).
  func dismissResult() {
    switch state {
    case .upToDate, .failed: state = .idle
    default: break
    }
  }

  func install(_ update: AvailableUpdate) {
    guard !isBusy else { return }
    lastCheckWasManual = true
    if let reason = installBlockedReason {
      state = .failed(reason)
      return
    }
    state = .downloading(0)
    Task {
      do {
        let workspace = try FileManager.default.url(
          for: .itemReplacementDirectory, in: .userDomainMask,
          appropriateFor: Bundle.main.bundleURL, create: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = try await download(update, into: workspace)
        state = .installing
        let newApp = try await Self.unpackAndVerify(
          archive, in: workspace, expectedVersion: update.version, teamIdentifier: teamIdentifier ?? ""
        )
        try Self.replaceRunningApp(with: newApp)
        Log.app.notice("Installed MACDancer \(update.version, privacy: .public); relaunching")
        relaunch()
      } catch {
        Log.app.error("Update failed: \(Self.describe(error), privacy: .public)")
        state = .failed(Self.describe(error))
      }
    }
  }

  // MARK: - Steps

  /// Downloads with a plain download task on a background queue. (It used to
  /// iterate the response byte by byte on the main actor, which made a 4 MB
  /// update take many seconds and stall the window.)
  func download(_ update: AvailableUpdate, into directory: URL) async throws -> URL {
    let destination = directory.appendingPathComponent("update.zip")
    try await FileDownloader.download(update.downloadURL, to: destination, expectedSize: Int64(update.size)) { progress in
      Task { @MainActor [weak self] in
        guard let self, case .downloading = self.state else { return }
        self.state = .downloading(progress)
      }
    }
    return destination
  }

  /// Unzips with ditto (keeps signatures intact) and checks the signature,
  /// bundle identifier, team and version of the app inside.
  nonisolated static func unpackAndVerify(
    _ archive: URL, in directory: URL, expectedVersion: String, teamIdentifier: String
  ) async throws -> URL {
    try await Task.detached(priority: .userInitiated) {
      let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
      let ditto = Process()
      ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
      try ditto.run()
      ditto.waitUntilExit()
      guard ditto.terminationStatus == 0 else { throw UpdateError.unpack }

      let app = unpacked.appendingPathComponent("MACDancer.app", isDirectory: true)
      guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.unpack }

      var code: SecStaticCode?
      var requirement: SecRequirement?
      guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(
              UpdatePlanner.codeRequirement(teamIdentifier: teamIdentifier) as CFString, [], &requirement
            ) == errSecSuccess, let requirement else {
        throw UpdateError.signature
      }
      let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
      guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw UpdateError.signature }

      let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      guard version.flatMap(AppVersion.init) == AppVersion(expectedVersion) else { throw UpdateError.versionMismatch }

      // Downloads made by this app are not quarantined, but be explicit.
      removexattr(app.path, "com.apple.quarantine", XATTR_NOFOLLOW)
      return app
    }.value
  }

  /// Swaps the bundle on disk (the running app by default). The running process keeps its open files, so
  /// this is safe; the new version starts on relaunch.
  static func replaceRunningApp(with newApp: URL, at location: URL = Bundle.main.bundleURL) throws {
    _ = try FileManager.default.replaceItemAt(location, withItemAt: newApp)
  }

  /// Starts the new copy once this process has exited, then quits.
  private func relaunch() {
    let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", script, Bundle.main.bundlePath]
    do {
      try helper.run()
    } catch {
      state = .failed(L("update.relaunch_failed", "The update is installed. Quit and reopen MACDancer to start it."))
      return
    }
    NSApplication.shared.terminate(nil)
  }

  private static func describe(_ error: Error) -> String {
    if let error = error as? UpdateError { return error.message }
    return error.localizedDescription
  }
}

/// One download with progress. Uses an ephemeral session so nothing is
/// cached or stored under ~/Library for MACDancer.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  static let session = URLSession(configuration: .ephemeral)

  private let destination: URL
  private let expectedSize: Int64
  private let progress: @Sendable (Double) -> Void
  private var continuation: CheckedContinuation<Void, Error>?
  private var lastReported = 0.0
  private var moveError: Error?

  private init(destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.expectedSize = expectedSize
    self.progress = progress
  }

  static func download(
    _ url: URL, to destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let delegate = FileDownloader(destination: destination, expectedSize: expectedSize, progress: progress)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.continuation = continuation
        session.downloadTask(with: url).resume()
      }
    } onCancel: {
      session.invalidateAndCancel()
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
    guard total > 0 else { return }
    let fraction = min(Double(totalBytesWritten) / Double(total), 1)
    if fraction - lastReported >= 0.02 || fraction == 1 {
      lastReported = fraction
      progress(fraction)
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // The temporary file is deleted when this method returns.
    let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      moveError = UpdateError.http(status)
      return
    }
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
    } catch {
      moveError = error
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error ?? moveError {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
    continuation = nil
  }
}

private enum UpdateError: Error {
  case http(Int)
  case unpack
  case signature
  case versionMismatch

  var message: String {
    switch self {
    case let .http(status): L("update.error.http", "GitHub answered with HTTP %d.", status)
    case .unpack: L("update.error.unpack", "The downloaded archive does not contain MACDancer.app.")
    case .signature:
      L("update.error.signature", "The update is not signed by the same developer as this copy of MACDancer, so it was not installed.")
    case .versionMismatch: L("update.error.version", "The downloaded app is not the expected version, so it was not installed.")
    }
  }
}
