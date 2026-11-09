import CoreWLAN
import Foundation

/// CoreWLAN adapter. Only the daemon links it; core tests use a fake.
struct WiFiController: WiFiControlling {
  private func interface(_ name: String) -> CWInterface? {
    CWWiFiClient.shared().interface(withName: name)
  }

  func isAssociated(_ interfaceName: String) -> Bool {
    guard let interface = interface(interfaceName) else { return false }
    return interface.interfaceMode() != .none
  }

  /// Since macOS 14.4 the network name is hidden from processes without
  /// Location access, root included. Then this is nil and the app, which can
  /// ask for that access, rejoins instead.
  func currentNetwork(_ interfaceName: String) -> WiFiNetwork {
    WiFiNetwork(ssid: interface(interfaceName)?.ssidData())
  }

  func leaveNetwork(_ interfaceName: String) {
    interface(interfaceName)?.disassociate()
  }

  func rejoin(_ interfaceName: String, network: WiFiNetwork) -> Bool {
    guard let ssid = network.ssid, let interface = interface(interfaceName) else { return false }
    do {
      guard let best = try interface.scanForNetworks(withSSID: ssid).max(by: { $0.rssiValue < $1.rssiValue }) else {
        return false
      }
      try interface.associate(to: best, password: nil)
      return true
    } catch {
      Log.daemon.notice("Wi-Fi rejoin from the helper failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  /// One log line per Wi-Fi interface: whether the helper can rejoin by itself.
  static func logDiagnostics() {
    for interface in CWWiFiClient.shared().interfaces() ?? [] {
      Log.daemon.notice(
        "Wi-Fi \(interface.interfaceName ?? "?", privacy: .public): network name visible to the helper \(interface.ssidData() != nil)"
      )
    }
  }
}
