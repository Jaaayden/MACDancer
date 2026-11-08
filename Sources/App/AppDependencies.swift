import Foundation

/// The XPC connection as the GUI sees it.
enum ConnectionState: Equatable, Sendable {
  case idle
  case connecting
  case connected
  /// The daemon could not be reached; the client keeps retrying.
  case unreachable(String)
  case incompatible(daemonVersion: Int)
}

@MainActor
protocol DaemonClientProviding: AnyObject {
  var onSnapshot: ((DaemonSnapshot) -> Void)? { get set }
  var onConnectionChange: ((ConnectionState) -> Void)? { get set }

  /// Connects, subscribes to pushed snapshots and keeps reconnecting until `stop()`.
  func start()
  func stop()
  func send(_ request: DaemonRequest) async throws -> DaemonSnapshot
}

enum ServiceRegistration: Equatable, Sendable {
  case unknown
  case notInstalled
  case requiresApproval
  case enabled
}

@MainActor
protocol ServiceControlling: AnyObject {
  func registration() async -> ServiceRegistration
  /// Checks for LinkLiar's helper. Slow (forks launchctl); call rarely.
  func legacyServiceInstalled() async -> Bool
  func install() async throws
  func uninstall() async throws
  /// Unregisters and registers again, so launchd loads the daemon from this build.
  func repair() async throws
  func openApprovalSettings()
}

protocol LocalInterfaceReading: Sendable {
  func interfaces() async throws -> [InterfaceSnapshot]
}

/// Reads interfaces off the main thread. Never talks to the daemon.
struct BackgroundInterfaceReader: LocalInterfaceReading {
  let reader: InterfaceReading

  func interfaces() async throws -> [InterfaceSnapshot] {
    try await Task.detached(priority: .userInitiated) { try reader.interfaces() }.value
  }
}
