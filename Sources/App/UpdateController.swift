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
    Task {
      do {
        var request = URLRequest(url: UpdatePlanner.latestReleaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MACDancer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
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

  func install(_ update: AvailableUpdate) {
    guard !isBusy else { return }
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

  func download(_ update: AvailableUpdate, into directory: URL) async throws -> URL {
    let destination = directory.appendingPathComponent("update.zip")
    let (bytes, response) = try await URLSession.shared.bytes(from: update.downloadURL)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    let expected = max(response.expectedContentLength, Int64(update.size))
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }

    var buffer = Data()
    buffer.reserveCapacity(1 << 16)
    var received: Int64 = 0
    var lastReported = 0.0
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= 1 << 16 {
        try handle.write(contentsOf: buffer)
        received += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        if expected > 0 {
          let progress = min(Double(received) / Double(expected), 1)
          if progress - lastReported >= 0.01 {
            lastReported = progress
            state = .downloading(progress)
          }
        }
      }
    }
    try handle.write(contentsOf: buffer)
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
