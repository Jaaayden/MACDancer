import Foundation

protocol WiFiControlling: Sendable {
  func isAssociated(_ interfaceName: String) -> Bool
  /// Leaves the current network. macOS rejoins known networks by itself.
  func leaveNetwork(_ interfaceName: String)
}

protocol MACWriting: Sendable {
  /// Blocking. Writes `target` and reports success only after macOS reads it back.
  func write(_ target: MACAddress, to interface: InterfaceSnapshot, disconnectWiFi: Bool) -> MACWriteOutcome
}

struct MACWriteOutcome: Equatable, Sendable {
  var observed: MACAddress?
  var error: MACDancerError?
  var disconnectedWiFi = false

  var succeeded: Bool { error == nil }
}

/// Applies one already-authorized address with `ifconfig <if> ether <mac>`.
/// Safety decisions are made by the coordinator, not here.
struct MACWriter: MACWriting {
  let runner: CommandRunning
  let wifi: WiFiControlling
  let reader: InterfaceReading
  var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  var commandTimeout: TimeInterval = 10

  func write(_ target: MACAddress, to interface: InterfaceSnapshot, disconnectWiFi: Bool) -> MACWriteOutcome {
    let name = interface.bsdName
    guard target.isAssignable else { return MACWriteOutcome(error: .invalidRequest("\(target) is not assignable.")) }
    var outcome = MACWriteOutcome()

    // Wi-Fi drivers reject a new address while associated.
    if interface.kind == .wifi && wifi.isAssociated(name) {
      guard disconnectWiFi else { return MACWriteOutcome(error: .confirmationRequired) }
      Log.daemon.info("Disconnecting Wi-Fi on \(name, privacy: .public) before the MAC change")
      wifi.leaveNetwork(name)
      outcome.disconnectedWiFi = true
      guard poll(timeout: 5, { !wifi.isAssociated(name) }) else {
        outcome.error = .wifiDisconnectFailed
        return outcome
      }
    }

    do {
      let result = try runner.run("/sbin/ifconfig", [name, "ether", target.stringValue], timeout: commandTimeout)
      let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
      guard result.exitCode == 0 else {
        outcome.error = .commandFailed(message.isEmpty ? "ifconfig exited with status \(result.exitCode)" : message)
        return outcome
      }
    } catch {
      outcome.error = MACDancerError.commandFailed(MACDancerError(error).message)
      return outcome
    }

    // Some drivers publish the new address a moment after ifconfig returns.
    _ = poll(timeout: 2) {
      outcome.observed = currentMAC(of: name)
      return outcome.observed == target
    }
    if outcome.observed != target {
      outcome.error = .readbackMismatch(expected: target, observed: outcome.observed)
    }
    return outcome
  }

  private func currentMAC(of name: String) -> MACAddress? {
    (try? reader.interfaces())?.first { $0.bsdName == name }?.currentMAC
  }

  private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let step = 0.2
    var waited = 0.0
    while true {
      if condition() { return true }
      if waited >= timeout { return false }
      sleep(step)
      waited += step
    }
  }
}
