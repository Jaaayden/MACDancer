import Foundation
import ServiceManagement

/// Registers the bundled LaunchDaemon with ServiceManagement. It never talks
/// to the daemon and never changes a MAC address.
@MainActor
final class ServiceController: ServiceControlling {
  private let service = SMAppService.daemon(plistName: MACDancerConstants.daemonPlistName)

  func registration() async -> ServiceRegistration {
    let status = await Task.detached(priority: .utility) {
      SMAppService.daemon(plistName: MACDancerConstants.daemonPlistName).status
    }.value
    switch status {
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notRegistered, .notFound: return .notInstalled
    @unknown default: return .unknown
    }
  }

  func legacyServiceInstalled() async -> Bool {
    await Task.detached(priority: .utility) { LegacyServiceDetector.isInstalled() }.value
  }

  func install() async throws {
    guard !(await legacyServiceInstalled()) else { throw MACDancerError.legacyServiceConflict }
    switch await registration() {
    case .enabled:
      return
    case .requiresApproval:
      openApprovalSettings()
    case .notInstalled, .unknown:
      try service.register()
      if await registration() == .requiresApproval { openApprovalSettings() }
    }
  }

  /// Only stops future launches. MAC addresses, policies and history are kept.
  func uninstall() async throws {
    guard await registration() != .notInstalled else { return }
    try await service.unregister()
  }

  func repair() async throws {
    guard !(await legacyServiceInstalled()) else { throw MACDancerError.legacyServiceConflict }
    switch await registration() {
    case .requiresApproval:
      openApprovalSettings()
    case .notInstalled, .unknown:
      try service.register()
    case .enabled:
      try await service.unregister()
      // unregister() can return before backgroundtaskmanagementd publishes the
      // change; registering in that window fails with EPERM on macOS 14/15.
      for _ in 0..<40 {
        if await registration() == .notInstalled { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      try await Task.sleep(for: .milliseconds(200))
      do {
        try service.register()
      } catch {
        try await Task.sleep(for: .seconds(1))
        try service.register()
      }
    }
  }

  func openApprovalSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
