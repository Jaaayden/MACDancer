import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system, english, simplifiedChinese

  var id: String { rawValue }
  static let preferenceKey = "preferredLanguage"
}

/// Looks strings up in the bundle for the chosen language. Views re-render on
/// a language change because `AppModel.language` is published.
enum Localizer {
  private static let lock = NSLock()
  /// `nil` means "use the English source text".
  nonisolated(unsafe) private static var bundle: Bundle? = makeBundle(for: storedLanguage)

  static var storedLanguage: AppLanguage {
    AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "") ?? .system
  }

  static func use(_ language: AppLanguage) {
    UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey)
    let next = makeBundle(for: language)
    lock.withLock { bundle = next }
  }

  static func string(_ key: String, _ fallback: String) -> String {
    lock.withLock { bundle }?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
  }

  private static func makeBundle(for language: AppLanguage) -> Bundle? {
    switch language {
    case .system:
      return .main
    case .english:
      // English is the development language; its text is the fallback itself.
      return nil
    case .simplifiedChinese:
      guard let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj") else { return .main }
      return Bundle(path: path) ?? .main
    }
  }
}

/// Localized string. `fallback` is the English text and the source of truth.
func L(_ key: String, _ fallback: String) -> String {
  Localizer.string(key, fallback)
}

/// Localized format string with arguments.
func L(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
  String(format: Localizer.string(key, fallback), arguments: arguments)
}

// MARK: - Model text

extension MACDancerError {
  var localizedMessage: String {
    switch self {
    case let .invalidRequest(detail): L("error.invalid_request", "Invalid request: %@", detail)
    case let .interfaceNotFound(name): L("error.interface_not_found", "Network interface %@ was not found.", name)
    case let .unsupportedInterface(name): L("error.unsupported", "%@ is not a Wi-Fi or Ethernet interface.", name)
    case let .interfaceBusy(name): L("error.busy", "Another MAC change on %@ is still running.", name)
    case .confirmationRequired:
      L("error.confirmation_required", "This interface is in use. Confirm the possible interruption first.")
    case .legacyServiceConflict:
      L("error.legacy", "LinkLiar's background service is installed. Remove it before MACDancer changes MAC addresses.")
    case .addressGenerationFailed: L("error.generation", "Could not generate an unused random MAC address.")
    case let .addressInUse(address): L("error.address_in_use", "%@ is already used by another interface.", address.stringValue)
    case .globalAddressNeedsConfirmation:
      L("error.global_address", "This is a globally administered (vendor) address and needs an extra confirmation.")
    case .hardwareAddressUnavailable:
      L("error.no_hardware", "macOS did not report a hardware MAC address for this interface.")
    case let .historyEntryMissing(address):
      L("error.history_missing", "%@ is not in this interface's history.", address.stringValue)
    case .wifiDisconnectFailed:
      L("error.wifi_disconnect", "Wi-Fi did not disconnect, so the MAC address was not changed.")
    case let .commandFailed(detail): L("error.command", "macOS rejected the MAC change: %@", detail)
    case let .readbackMismatch(expected, observed):
      L(
        "error.readback", "macOS still reports %1$@ instead of %2$@. The driver did not accept the new address.",
        observed?.stringValue ?? L("mac.unavailable", "Unavailable"), expected.stringValue
      )
    case let .daemonUnavailable(detail): L("error.daemon_unavailable", "The background service is unavailable: %@", detail)
    case .timeout: L("error.timeout", "The background service did not answer in time. The current state is being re-read.")
    case let .incompatibleProtocol(expected, actual):
      L(
        "error.protocol",
        "The app (protocol %1$d) and the background service (protocol %2$d) are from different builds. Use Repair connection.",
        expected, actual
      )
    case let .persistence(detail): L("error.persistence", "Could not save MACDancer settings: %@", detail)
    }
  }
}

func macText(_ address: MACAddress?) -> String {
  address?.stringValue ?? L("mac.unavailable", "Unavailable")
}

func policyText(_ policy: InterfacePolicy) -> String {
  switch policy {
  case .systemManaged: L("policy.system_managed", "Managed by macOS")
  case .random: L("policy.random", "Random MAC")
  case let .specified(address): L("policy.specified_format", "Specified: %@", address.stringValue)
  }
}

func historySourceText(_ source: HistorySource) -> String {
  switch source {
  case .generatedLocal: L("history.source.generated_local", "Generated locally")
  case .vendorCompatible: L("history.source.vendor_compatible", "Vendor-compatible")
  case .userSpecified: L("history.source.user_specified", "Specified by you")
  case .historyRestore: L("history.source.history_restore", "Restored from history")
  }
}

func operationText(_ kind: OperationKind) -> String {
  switch kind {
  case .randomize: L("operation.randomize", "Randomized")
  case .automaticRotation: L("operation.automatic", "Rotated automatically")
  case .restoreHardware: L("operation.restore_hardware", "Restored hardware MAC")
  case .restoreHistory: L("operation.restore_history", "Restored from history")
  case .restoreSpecified: L("operation.restore_specified", "Applied specified MAC")
  case .handoff: L("operation.handoff", "Handed off to macOS")
  case .reconcile: L("operation.reconcile", "Reconciled")
  }
}

func operationStateText(_ state: OperationState) -> String {
  switch state {
  case .running: L("operation_state.running", "Working…")
  case .succeeded: L("operation_state.succeeded", "Verified")
  case .failed: L("operation_state.failed", "Failed")
  }
}

func waitReasonText(_ reason: WaitReason) -> String {
  switch reason {
  case .busy: L("wait.busy", "waiting for another change to finish")
  case .defaultRoute: L("wait.default_route", "waiting until it no longer carries the default route")
  case .wifiConnected: L("wait.wifi_connected", "waiting until Wi-Fi is disconnected")
  case .inUse: L("wait.in_use", "waiting until the interface is no longer in use")
  case .interfaceMissing: L("wait.missing", "waiting for the adapter to be connected")
  }
}

func triggerText(_ trigger: RotationTrigger) -> String {
  switch trigger {
  case .beforeSleep: L("trigger.before_sleep", "Queued before sleep")
  case .afterWake: L("trigger.after_wake", "Queued after wake")
  case .becameInactive: L("trigger.became_inactive", "Queued when the interface became inactive")
  }
}

func noticeText(_ notice: InterfaceNotice) -> String {
  switch notice {
  case let .addressReplacedAfterReconnect(applied, current):
    L(
      "notice.address_replaced",
      "After Wi-Fi reconnected, macOS replaced %1$@ with %2$@. Turn off Private Wi-Fi Address for this network in System Settings to keep your own address.",
      applied.stringValue, current.stringValue
    )
  }
}

func dateTimeText(_ date: Date?) -> String {
  guard let date else { return L("time.never", "Never") }
  return date.formatted(date: .abbreviated, time: .shortened)
}
