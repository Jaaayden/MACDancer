import CoreWLAN
import Foundation

/// CoreWLAN adapter. Only the daemon links it; core tests use a fake.
struct WiFiController: WiFiControlling {
  func isAssociated(_ interfaceName: String) -> Bool {
    guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else { return false }
    return interface.interfaceMode() != .none
  }

  func leaveNetwork(_ interfaceName: String) {
    CWWiFiClient.shared().interface(withName: interfaceName)?.disassociate()
  }
}
