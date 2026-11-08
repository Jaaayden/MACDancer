import Foundation
import os

enum MACDancerConstants {
  static let appIdentifier = "local.macdancer.MACDancer"
  static let daemonIdentifier = "local.macdancer.MACDancer.daemon"
  static let daemonPlistName = "local.macdancer.MACDancer.daemon.plist"
  static let legacyDaemonIdentifier = "io.github.halo.LinkLiar.linkdaemon"
  /// Bumped whenever the XPC request/response shapes change. GUI and daemon
  /// refuse to talk across versions; "Repair connection" reloads the daemon.
  static let protocolVersion = 2
  static let maximumPayloadSize = 1_048_576
  static let errorDomain = "local.macdancer.MACDancer.error"
  static let errorPayloadKey = "local.macdancer.MACDancer.errorPayload"
}

enum Log {
  static let daemon = Logger(subsystem: MACDancerConstants.appIdentifier, category: "daemon")
  static let app = Logger(subsystem: MACDancerConstants.appIdentifier, category: "app")
}

/// Every failure that crosses the XPC boundary. The whole value is encoded
/// into the NSError, so the GUI sees exactly what the daemon reported and can
/// show it in the user's language.
enum MACDancerError: Error, Codable, Equatable, Sendable {
  case invalidRequest(String)
  case interfaceNotFound(String)
  case unsupportedInterface(String)
  case interfaceBusy(String)
  case confirmationRequired
  case legacyServiceConflict
  case addressGenerationFailed
  case addressInUse(MACAddress)
  case globalAddressNeedsConfirmation
  case hardwareAddressUnavailable
  case historyEntryMissing(MACAddress)
  case wifiDisconnectFailed
  case commandFailed(String)
  case readbackMismatch(expected: MACAddress, observed: MACAddress?)
  case daemonUnavailable(String)
  case timeout
  case incompatibleProtocol(expected: Int, actual: Int)
  case persistence(String)

  /// English fallback text. The GUI localizes by case, not by this string.
  var message: String {
    switch self {
    case let .invalidRequest(detail): "Invalid request: \(detail)"
    case let .interfaceNotFound(name): "Network interface \(name) was not found."
    case let .unsupportedInterface(name): "\(name) is not a Wi-Fi or Ethernet interface."
    case let .interfaceBusy(name): "Another MAC change on \(name) is still running."
    case .confirmationRequired: "This interface is in use. Confirm the possible interruption first."
    case .legacyServiceConflict: "LinkLiar's background service is installed. Remove it before MACDancer changes MAC addresses."
    case .addressGenerationFailed: "Could not generate an unused random MAC address."
    case let .addressInUse(address): "\(address) is already used by another interface."
    case .globalAddressNeedsConfirmation: "This is a globally administered (vendor) address and needs an extra confirmation."
    case .hardwareAddressUnavailable: "macOS did not report a hardware MAC address for this interface."
    case let .historyEntryMissing(address): "\(address) is not in this interface's history."
    case .wifiDisconnectFailed: "Wi-Fi did not disconnect, so the MAC address was not changed."
    case let .commandFailed(detail): "macOS rejected the MAC change: \(detail)"
    case let .readbackMismatch(expected, observed):
      "macOS reports \(observed?.stringValue ?? "no address") instead of \(expected)."
    case let .daemonUnavailable(detail): detail
    case .timeout: "The background service did not answer in time. The result is being re-read."
    case let .incompatibleProtocol(expected, actual):
      "The app (protocol \(expected)) and background service (protocol \(actual)) do not match. Use Repair connection."
    case let .persistence(detail): "Could not save MACDancer settings: \(detail)"
    }
  }

  var code: Int {
    switch self {
    case .invalidRequest: 1
    case .interfaceNotFound: 2
    case .unsupportedInterface: 3
    case .interfaceBusy: 4
    case .confirmationRequired: 5
    case .legacyServiceConflict: 6
    case .addressGenerationFailed: 7
    case .addressInUse: 8
    case .globalAddressNeedsConfirmation: 9
    case .hardwareAddressUnavailable: 10
    case .historyEntryMissing: 11
    case .wifiDisconnectFailed: 12
    case .commandFailed: 13
    case .readbackMismatch: 14
    case .daemonUnavailable: 15
    case .timeout: 16
    case .incompatibleProtocol: 17
    case .persistence: 18
    }
  }
}

extension MACDancerError: LocalizedError {
  var errorDescription: String? { message }
}

extension MACDancerError {
  /// Encodes the full error for XPC. NSError userInfo only carries plist
  /// types, so the error travels as JSON data.
  var nsError: NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
    if let data = try? JSONEncoder().encode(self) {
      userInfo[MACDancerConstants.errorPayloadKey] = data
    }
    return NSError(domain: MACDancerConstants.errorDomain, code: code, userInfo: userInfo)
  }

  /// Recovers a daemon error; anything else (a transport failure) becomes
  /// `daemonUnavailable` with the system's description.
  init(_ error: Error) {
    if let error = error as? MACDancerError {
      self = error
      return
    }
    let nsError = error as NSError
    if nsError.domain == MACDancerConstants.errorDomain,
       let data = nsError.userInfo[MACDancerConstants.errorPayloadKey] as? Data,
       let decoded = try? JSONDecoder().decode(MACDancerError.self, from: data) {
      self = decoded
    } else {
      self = .daemonUnavailable(nsError.localizedDescription)
    }
  }
}
