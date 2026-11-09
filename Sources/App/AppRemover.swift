import AppKit
import Foundation

/// Removes every trace of MACDancer for "Uninstall MACDancer".
@MainActor
final class SystemAppRemover: AppRemoving {
  static let serviceDataPath = "/Library/Application Support/local.macdancer.MACDancer"

  func serviceDataExists() -> Bool {
    FileManager.default.fileExists(atPath: Self.serviceDataPath)
  }

  func removeServiceDataWithPrompt() async throws {
    let source = "do shell script \"/bin/rm -rf '\(Self.serviceDataPath)'\" with administrator privileges"
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error {
      let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
      throw MACDancerError.persistence(message)
    }
  }

  func trashAppAndQuit() async throws {
    let identifier = Bundle.main.bundleIdentifier ?? MACDancerConstants.appIdentifier
    let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    let leftovers = [
      "Caches/\(identifier)",
      "HTTPStorages/\(identifier)",
      "HTTPStorages/\(identifier).binarycookies",
      "Saved Application State/\(identifier).savedState",
      "Preferences/\(identifier).plist",
    ].map { library.appendingPathComponent($0).path }

    try await NSWorkspace.shared.recycle([Bundle.main.bundleURL])

    // Preferences are written again while the app quits (window frames), so
    // they are removed by a helper after this process has exited.
    let script = """
    while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
    /usr/bin/defaults delete "$0" >/dev/null 2>&1
    for path in "$@"; do /bin/rm -rf "$path"; done
    """
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", script, identifier] + leftovers
    try helper.run()
    NSApplication.shared.terminate(nil)
  }
}
