import Foundation

enum SafetyDecision: Equatable, Sendable {
  case allowed
  /// Automatic work waits; the reason is shown to the user.
  case wait(WaitReason)
  case denied(MACDancerError)
}

/// The one place that decides whether a MAC write may happen now.
enum SafetyPolicy {
  /// Manual requests are allowed on an interface that is in use only after
  /// the user confirmed the interruption (for connected Wi-Fi: a disconnect).
  static func manual(_ interface: InterfaceSnapshot, confirmedDisruption: Bool) -> SafetyDecision {
    guard interface.kind.isSupported else { return .denied(.unsupportedInterface(interface.id)) }
    guard !interface.isBusy else { return .denied(.interfaceBusy(interface.id)) }
    if interface.isInUse && !confirmedDisruption { return .denied(.confirmationRequired) }
    return .allowed
  }

  /// Automation never touches an interface that carries traffic, a connected
  /// Wi-Fi network, or the default route. It waits instead.
  static func automatic(_ interface: InterfaceSnapshot) -> SafetyDecision {
    guard interface.kind.isSupported else { return .denied(.unsupportedInterface(interface.id)) }
    if interface.isBusy { return .wait(.busy) }
    if interface.isDefaultRoute { return .wait(.defaultRoute) }
    if interface.isWiFiAssociated { return .wait(.wifiConnected) }
    if interface.isActive { return .wait(.inUse) }
    return .allowed
  }
}

/// Decides which interfaces get a pending rotation for a trigger. Whether the
/// rotation may run right now is `SafetyPolicy.automatic`'s job.
enum AutomationPlanner {
  static func interfacesToQueue(
    for trigger: RotationTrigger,
    settings: AutomationSettings,
    previous: [String: InterfaceSnapshot] = [:],
    current: [String: InterfaceSnapshot]
  ) -> Set<String> {
    let random = current.values.filter { $0.policy == .random && $0.kind.isSupported && !$0.isBusy }
    switch trigger {
    case .beforeSleep:
      return settings.prepareRotationBeforeSleep ? Set(random.map(\.id)) : []
    case .afterWake:
      return settings.rotateAfterWake ? Set(random.map(\.id)) : []
    case .becameInactive:
      guard settings.rotateWhenInterfaceBecomesInactive else { return [] }
      return Set(random.compactMap { interface in
        guard let old = previous[interface.id], old.isInUse, !interface.isInUse else { return nil }
        return interface.id
      })
    }
  }
}
