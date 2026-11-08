import Foundation

struct CommandResult: Equatable, Sendable {
  let exitCode: Int32
  let output: String
  let error: String
}

protocol CommandRunning: Sendable {
  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

// Core tests are built without any way to start a real process.
#if !MACDANCER_CORE_TESTS
struct ProcessRunner: CommandRunning {
  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    process.standardInput = FileHandle.nullDevice

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    // Read both pipes concurrently so a chatty child cannot block on a full pipe.
    let group = DispatchGroup()
    var outData = Data()
    var errData = Data()
    DispatchQueue.global(qos: .utility).async(group: group) {
      outData = output.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global(qos: .utility).async(group: group) {
      errData = error.fileHandleForReading.readDataToEndOfFile()
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 0.5) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.5)
      }
      _ = group.wait(timeout: .now() + 0.5)
      throw MACDancerError.commandFailed("\((executable as NSString).lastPathComponent) timed out after \(Int(timeout)) s")
    }
    group.wait()
    return CommandResult(
      exitCode: process.terminationStatus,
      output: String(decoding: outData, as: UTF8.self),
      error: String(decoding: errData, as: UTF8.self)
    )
  }
}

/// Looks for LinkLiar's privileged helper, which would fight MACDancer over
/// the same interfaces. Callers cache the answer: it forks `launchctl`.
enum LegacyServiceDetector {
  static func isInstalled(runner: CommandRunning = ProcessRunner()) -> Bool {
    let identifier = MACDancerConstants.legacyDaemonIdentifier
    let plists = ["/Library/LaunchDaemons", "/Library/LaunchAgents"].map { "\($0)/\(identifier).plist" }
    if plists.contains(where: FileManager.default.fileExists(atPath:)) { return true }
    // An SMAppService registration leaves no plist in /Library, so ask launchd.
    // If launchd cannot be asked, assume no conflict rather than locking the
    // app; the plist check above already covers classic installs.
    let result = try? runner.run("/bin/launchctl", ["print", "system/\(identifier)"], timeout: 3)
    return result?.exitCode == 0
  }
}
#endif
