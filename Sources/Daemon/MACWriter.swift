import Foundation

/// A Wi-Fi network to rejoin after the MAC change. `ssid` is nil when macOS
/// does not reveal the network name to the daemon.
struct WiFiNetwork: Equatable, Sendable {
  var ssid: Data?
}

protocol WiFiControlling: Sendable {
  func isAssociated(_ interfaceName: String) -> Bool
  /// The network the interface is on now, read before leaving it.
  func currentNetwork(_ interfaceName: String) -> WiFiNetwork
  /// Leaves the current network. macOS treats this like the user choosing
  /// "Disconnect" and does not rejoin by itself, so `rejoin` must follow.
  func leaveNetwork(_ interfaceName: String)
  /// Joins `network` again, or the first preferred network in range when its
  /// name is unknown. Blocking; returns false when no join could be started.
  func rejoin(_ interfaceName: String, network: WiFiNetwork) -> Bool
}

protocol MACWriting: Sendable {
  /// Blocking. Writes `target` and reports success only after macOS reads it back.
  func write(_ target: MACAddress, to interface: InterfaceSnapshot, disconnectWiFi: Bool) -> MACWriteOutcome
}

struct MACWriteOutcome: Equatable, Sendable {
  var observed: MACAddress?
  var error: MACDancerError?
  var disconnectedWiFi = false
  /// Set only when Wi-Fi was disconnected: whether it came back afterwards.
  var rejoinedWiFi: Bool?
  /// The address after rejoining, when macOS replaced ours while joining.
  var replacedOnRejoin: MACAddress?

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
  var rejoinTimeout: TimeInterval = 20

  func write(_ target: MACAddress, to interface: InterfaceSnapshot, disconnectWiFi: Bool) -> MACWriteOutcome {
    let name = interface.bsdName
    guard target.isAssignable else { return MACWriteOutcome(error: .invalidRequest("\(target) is not assignable.")) }
    var outcome = MACWriteOutcome()

    // Wi-Fi drivers reject a new address while associated.
    var previousNetwork: WiFiNetwork?
    if interface.kind == .wifi && wifi.isAssociated(name) {
      guard disconnectWiFi else { return MACWriteOutcome(error: .confirmationRequired) }
      let network = wifi.currentNetwork(name)
      previousNetwork = network
      Log.daemon.notice(
        "Disconnecting Wi-Fi on \(name, privacy: .public) before the MAC change (network name known: \(network.ssid != nil))"
      )
      wifi.leaveNetwork(name)
      outcome.disconnectedWiFi = true
      guard poll(timeout: 5, { !wifi.isAssociated(name) }) else {
        outcome.error = .wifiDisconnectFailed
        return outcome
      }
    }

    apply(target, to: name, &outcome)

    // Rejoin whether or not the write worked: the user never asked to stay offline.
    if let previousNetwork {
      rejoin(name, previousNetwork, target: target, &outcome)
    }
    return outcome
  }

  private func apply(_ target: MACAddress, to name: String, _ outcome: inout MACWriteOutcome) {
    do {
      let result = try runner.run("/sbin/ifconfig", [name, "ether", target.stringValue], timeout: commandTimeout)
      let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
      guard result.exitCode == 0 else {
        outcome.error = .commandFailed(message.isEmpty ? "ifconfig exited with status \(result.exitCode)" : message)
        return
      }
    } catch {
      outcome.error = MACDancerError.commandFailed(MACDancerError(error).message)
      return
    }

    // Some drivers publish the new address a moment after ifconfig returns.
    var observed: MACAddress?
    _ = poll(timeout: 2) {
      observed = currentMAC(of: name)
      return observed == target
    }
    outcome.observed = observed
    if observed != target {
      outcome.error = .readbackMismatch(expected: target, observed: observed)
    }
  }

  private func rejoin(_ name: String, _ network: WiFiNetwork, target: MACAddress, _ outcome: inout MACWriteOutcome) {
    let started = wifi.rejoin(name, network: network)
    let joined = started && poll(timeout: rejoinTimeout) { wifi.isAssociated(name) }
    outcome.rejoinedWiFi = joined
    Log.daemon.notice("Rejoining Wi-Fi on \(name, privacy: .public): \(joined ? "connected" : "failed", privacy: .public)")
    // Private Wi-Fi Address can swap our address while joining.
    if joined, outcome.succeeded, let after = currentMAC(of: name), after != target {
      outcome.replacedOnRejoin = after
    }
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
