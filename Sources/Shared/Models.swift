import Foundation

enum InterfaceKind: String, Codable, Sendable {
  case wifi, ethernet, other

  var isSupported: Bool { self != .other }
}

/// What MACDancer is responsible for on one interface.
enum InterfacePolicy: Codable, Equatable, Sendable {
  /// MACDancer never writes to the interface (the default).
  case systemManaged
  /// Automation may rotate the address when it is safe to do so.
  case random
  /// The user chose this exact address; automation leaves it alone.
  case specified(MACAddress)

  private enum CodingKeys: String, CodingKey { case kind, address }
  private enum Kind: String, Codable { case systemManaged, random, specified }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .systemManaged: self = .systemManaged
    case .random: self = .random
    case .specified: self = .specified(try container.decode(MACAddress.self, forKey: .address))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .systemManaged: try container.encode(Kind.systemManaged, forKey: .kind)
    case .random: try container.encode(Kind.random, forKey: .kind)
    case let .specified(address):
      try container.encode(Kind.specified, forKey: .kind)
      try container.encode(address, forKey: .address)
    }
  }
}

enum HistorySource: String, Codable, Sendable {
  case generatedLocal, vendorCompatible, userSpecified, historyRestore
}

/// Raw values are part of the stored configuration; do not rename them.
enum OperationKind: String, Codable, Sendable {
  case randomize, restoreHardware, restoreHistory, restoreSpecified, handoff, reconcile, automaticRotation
}

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
  var id: String { address.stringValue }
  let address: MACAddress
  var source: HistorySource
  var firstUsedAt: Date
  var lastUsedAt: Date
  var operation: OperationKind
}

/// The most recent verified addresses of one interface, newest first, capped at 20.
struct HistoryLedger: Codable, Equatable, Sendable {
  static let limit = 20
  private(set) var entries: [HistoryEntry] = []

  init(entries: [HistoryEntry] = []) {
    for entry in entries { record(entry) }
  }

  init(from decoder: Decoder) throws {
    self.init(entries: try decoder.singleValueContainer().decode([HistoryEntry].self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(entries)
  }

  var addresses: Set<MACAddress> { Set(entries.map(\.address)) }

  func contains(_ address: MACAddress) -> Bool { entries.contains { $0.address == address } }

  mutating func record(_ entry: HistoryEntry) {
    var entry = entry
    if let index = entries.firstIndex(where: { $0.address == entry.address }) {
      entry.firstUsedAt = min(entries[index].firstUsedAt, entry.firstUsedAt)
      entries.remove(at: index)
    }
    entries.append(entry)
    entries.sort { $0.lastUsedAt > $1.lastUsedAt }
    if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
  }

  mutating func remove(_ address: MACAddress) { entries.removeAll { $0.address == address } }
  mutating func removeAll() { entries.removeAll() }
}

enum OperationState: String, Codable, Sendable { case running, succeeded, failed }

/// The latest MAC operation on an interface, as verified by the daemon.
struct OperationRecord: Codable, Equatable, Sendable {
  let kind: OperationKind
  var state: OperationState
  let requested: MACAddress?
  var observed: MACAddress?
  let startedAt: Date
  var finishedAt: Date?
  var error: MACDancerError?
  /// Set when Wi-Fi had to be disconnected for this change.
  var disconnectedWiFi = false
}

enum RotationTrigger: String, Codable, Sendable { case beforeSleep, afterWake, becameInactive }

/// Why an automatic rotation has not run yet.
enum WaitReason: String, Codable, Sendable {
  case busy, defaultRoute, wifiConnected, inUse, interfaceMissing
}

/// An automatic rotation that waits until the interface is safe to change.
struct PendingRotation: Codable, Equatable, Sendable {
  let trigger: RotationTrigger
  let queuedAt: Date
  var waitingReason: WaitReason?
}

/// Something the user should know about an interface after an operation.
enum InterfaceNotice: Codable, Equatable, Sendable {
  /// macOS rejoined Wi-Fi with its own (Private Wi-Fi) address.
  case addressReplacedAfterReconnect(applied: MACAddress, current: MACAddress)
}

struct AutomationSettings: Codable, Equatable, Sendable {
  var rotateAfterWake = false
  var rotateWhenInterfaceBecomesInactive = false
  var prepareRotationBeforeSleep = false
  /// Keep the hardware vendor prefix when generating random addresses.
  var vendorCompatibility = false

  init(
    rotateAfterWake: Bool = false,
    rotateWhenInterfaceBecomesInactive: Bool = false,
    prepareRotationBeforeSleep: Bool = false,
    vendorCompatibility: Bool = false
  ) {
    self.rotateAfterWake = rotateAfterWake
    self.rotateWhenInterfaceBecomesInactive = rotateWhenInterfaceBecomesInactive
    self.prepareRotationBeforeSleep = prepareRotationBeforeSleep
    self.vendorCompatibility = vendorCompatibility
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rotateAfterWake = try container.decodeIfPresent(Bool.self, forKey: .rotateAfterWake) ?? false
    rotateWhenInterfaceBecomesInactive =
      try container.decodeIfPresent(Bool.self, forKey: .rotateWhenInterfaceBecomesInactive) ?? false
    prepareRotationBeforeSleep = try container.decodeIfPresent(Bool.self, forKey: .prepareRotationBeforeSleep) ?? false
    vendorCompatibility = try container.decodeIfPresent(Bool.self, forKey: .vendorCompatibility) ?? false
  }

  var rotatesAutomatically: Bool {
    rotateAfterWake || rotateWhenInterfaceBecomesInactive || prepareRotationBeforeSleep
  }
}

/// Facts read from macOS for one interface, plus what MACDancer manages for it.
struct InterfaceSnapshot: Codable, Identifiable, Equatable, Sendable {
  var id: String { bsdName }
  let bsdName: String
  var displayName: String
  var kind: InterfaceKind
  var currentMAC: MACAddress?
  var hardwareMAC: MACAddress?
  /// Has a routable IP address, i.e. is carrying traffic right now.
  var isActive: Bool
  var isWiFiAssociated: Bool
  var isDefaultRoute: Bool
  var observedAt: Date

  // Managed by the daemon. A local read leaves these at their defaults.
  var policy: InterfacePolicy = .systemManaged
  var history = HistoryLedger()
  var lastOperation: OperationRecord?
  var pendingRotation: PendingRotation?
  var isBusy = false
  var notice: InterfaceNotice?

  /// Changing the address may interrupt a connection.
  var isInUse: Bool { isActive || isWiFiAssociated || isDefaultRoute }

  /// Thunderbolt ports, bridges and virtual adapters report a locally
  /// administered "hardware" address. They are hidden unless asked for.
  var isLikelyVirtual: Bool {
    guard kind != .wifi else { return false }
    guard let hardwareMAC else { return true }
    return hardwareMAC.isLocallyAdministered
  }

  var usesHardwareMAC: Bool {
    guard let currentMAC, let hardwareMAC else { return false }
    return currentMAC == hardwareMAC
  }

  /// Stable across reboots, and different when an adapter with the same BSD
  /// name (a USB dongle, say) is replaced. Policies and history use this key.
  var deviceKey: String { "\(bsdName)|\(hardwareMAC?.stringValue ?? "unverified-hardware")" }
}

struct DaemonSnapshot: Codable, Equatable, Sendable {
  var protocolVersion = MACDancerConstants.protocolVersion
  let instanceID: UUID
  var revision: UInt64
  var generatedAt: Date
  var interfaces: [InterfaceSnapshot]
  var automation: AutomationSettings
  var legacyServiceDetected: Bool
  /// Non-fatal problems such as a failed save. They never block actions.
  var warnings: [String]
  /// Version of the app bundle the daemon was launched from.
  var daemonVersion: String? = nil
}

/// Where a restore request should leave the interface.
enum RestoreTarget: Codable, Equatable, Sendable {
  case systemManaged
  case hardware
  case history(MACAddress)
  case specified(MACAddress, confirmedGlobalAddress: Bool)
}

enum PolicyChoice: String, Codable, Sendable { case systemManaged, random }

/// Everything the GUI can ask of the daemon. Each request is answered with a
/// fresh `DaemonSnapshot` or a `MACDancerError`.
enum DaemonRequest: Codable, Equatable, Sendable {
  case snapshot
  case subscribe
  case setPolicy(interfaceID: String, policy: PolicyChoice)
  case randomize(interfaceID: String, confirmedDisruption: Bool)
  case restore(interfaceID: String, target: RestoreTarget, confirmedDisruption: Bool)
  /// `nil` clears the whole history.
  case removeHistory(interfaceID: String, address: MACAddress?)
  /// `nil` cancels pending rotations on every interface.
  case cancelPending(interfaceID: String?)
  case updateAutomation(AutomationSettings)

  /// Requests that may write a MAC address and therefore take a while.
  var mayWriteAddress: Bool {
    switch self {
    case .randomize, .restore: true
    default: false
    }
  }
}
