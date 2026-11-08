import Foundation

enum SystemEvent: Equatable, Sendable {
  case willSleep
  case didWake
  case networkChanged
}

/// The daemon's state machine. All state lives on one serial queue that never
/// blocks on a MAC write: writes run on `workQueue`, so status requests and
/// heartbeats are answered immediately even while `ifconfig` is running.
final class DaemonCoordinator: @unchecked Sendable {
  struct Environment {
    var reader: InterfaceReading
    var writer: MACWriting
    var store: ConfigurationStoring
    /// Must be cheap; the daemon caches the real (forking) check.
    var legacyServiceDetected: @Sendable () -> Bool
    var now: @Sendable () -> Date = { Date() }
    var random: RandomBytes = secureRandomBytes
    var workQueue = DispatchQueue(label: "local.macdancer.MACDancer.daemon.work")
    /// After a Wi-Fi disconnect, when to check whether macOS rejoined with its own address.
    var wifiFollowUpDelay: TimeInterval = 30
    /// After wake, give the network time to settle before automatic work.
    var wakeSettleDelay: TimeInterval = 10
    /// Reported to the GUI for diagnostics.
    var version: String? = nil
  }

  typealias Reply = (Result<DaemonSnapshot, MACDancerError>) -> Void

  private let queue = DispatchQueue(label: "local.macdancer.MACDancer.daemon.state")
  private let env: Environment
  private let instanceID = UUID()

  private var document: ConfigurationDocument
  private var savedDocument: ConfigurationDocument
  /// Raw facts from the last read, keyed by BSD name.
  private var observed: [String: InterfaceSnapshot] = [:]
  // Keyed by device key, so they follow the adapter rather than the BSD name.
  private var lastOperations: [String: OperationRecord] = [:]
  private var notices: [String: InterfaceNotice] = [:]
  // Keyed by BSD name.
  private var busy: Set<String> = []
  private var lastWriteAt: [String: Date] = [:]
  private var warnings: [String: String] = [:]
  private var revision: UInt64 = 0
  private var lastPublishedContent: DaemonSnapshot?
  private var subscribers: [UUID: (DaemonSnapshot) -> Void] = [:]

  init(environment: Environment) {
    env = environment
    let loaded = environment.store.load()
    document = loaded.document
    savedDocument = loaded.document
    if let warning = loaded.warning {
      warnings["load"] = warning
      Log.daemon.error("\(warning, privacy: .public)")
    }
    queue.sync { readLocked() }
  }

  // MARK: - Entry points

  func handle(_ request: DaemonRequest, reply: @escaping Reply) {
    queue.async { self.handleLocked(request, reply: reply) }
  }

  func handle(_ event: SystemEvent) {
    queue.async { self.handleLocked(event) }
  }

  /// Periodic calibration: notices changes nobody announced, retries a failed
  /// save and runs pending rotations whose interface became safe.
  func tick() {
    queue.async {
      self.readLocked()
      self.runPendingLocked()
      self.persistLocked()
      self.publishLocked()
    }
  }

  func setWarning(_ key: String, _ message: String?) {
    queue.async {
      self.warnings[key] = message
      self.publishLocked()
    }
  }

  @discardableResult
  func addSubscriber(_ subscriber: @escaping (DaemonSnapshot) -> Void) -> UUID {
    let id = UUID()
    queue.async { self.subscribers[id] = subscriber }
    return id
  }

  func removeSubscriber(_ id: UUID) {
    queue.async { self.subscribers[id] = nil }
  }

  /// Runs `body` on the state queue only if no MAC write is in flight. While
  /// it runs no new write can start, so `body` may safely exit the process.
  func whenIdle(_ body: () -> Void) {
    queue.sync { if busy.isEmpty { body() } }
  }

  /// Runs `body` on the state queue after all previously queued work. Tests use this.
  func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

  // MARK: - Requests

  private func handleLocked(_ request: DaemonRequest, reply: @escaping Reply) {
    switch request {
    case .snapshot, .subscribe:
      reply(.success(snapshotLocked()))

    case let .setPolicy(id, choice):
      readLocked()
      guard let interface = supportedInterfaceLocked(id, reply: reply) else { return }
      if choice == .random && env.legacyServiceDetected() { return reply(.failure(.legacyServiceConflict)) }
      document.policies[interface.deviceKey] = choice == .random ? .random : .systemManaged
      if choice == .systemManaged { document.pendingRotations[interface.deviceKey] = nil }
      commitLocked(reply: reply)

    case let .randomize(id, confirmed):
      guard !env.legacyServiceDetected() else { return reply(.failure(.legacyServiceConflict)) }
      readLocked()
      guard let interface = supportedInterfaceLocked(id, reply: reply) else { return }
      if case let .denied(error) = SafetyPolicy.manual(interface, confirmedDisruption: confirmed) {
        return reply(.failure(error))
      }
      do {
        let (target, source) = try generateLocked(for: interface)
        startWriteLocked(
          interface, target: target, kind: .randomize, source: source,
          resultingPolicy: .random, disconnectWiFi: confirmed, reply: reply
        )
      } catch {
        reply(.failure(MACDancerError(error)))
      }

    case let .restore(id, target, confirmed):
      restoreLocked(id, target: target, confirmed: confirmed, reply: reply)

    case let .removeHistory(id, address):
      readLocked()
      guard let interface = observed[id].map(managedLocked) else { return reply(.failure(.interfaceNotFound(id))) }
      var ledger = document.histories[interface.deviceKey] ?? HistoryLedger()
      if let address { ledger.remove(address) } else { ledger.removeAll() }
      document.histories[interface.deviceKey] = ledger.entries.isEmpty ? nil : ledger
      commitLocked(reply: reply)

    case let .cancelPending(id):
      if let id {
        guard let interface = observed[id] else { return reply(.failure(.interfaceNotFound(id))) }
        document.pendingRotations[interface.deviceKey] = nil
      } else {
        document.pendingRotations.removeAll()
      }
      commitLocked(reply: reply)

    case let .updateAutomation(settings):
      if (settings.rotatesAutomatically || settings.vendorCompatibility) && env.legacyServiceDetected() {
        return reply(.failure(.legacyServiceConflict))
      }
      document.automation = settings
      if !settings.rotatesAutomatically { document.pendingRotations.removeAll() }
      commitLocked(reply: reply)
    }
  }

  private func restoreLocked(_ id: String, target: RestoreTarget, confirmed: Bool, reply: @escaping Reply) {
    readLocked()
    guard let interface = supportedInterfaceLocked(id, reply: reply) else { return }
    let key = interface.deviceKey

    let address: MACAddress
    let kind: OperationKind
    let source: HistorySource?
    let policy: InterfacePolicy
    switch target {
    case .systemManaged:
      // Handoff only stops MACDancer from writing; the address is left as is.
      guard !interface.isBusy else { return reply(.failure(.interfaceBusy(id))) }
      document.policies[key] = .systemManaged
      document.pendingRotations[key] = nil
      notices[key] = nil
      let now = env.now()
      lastOperations[key] = OperationRecord(
        kind: .handoff, state: .succeeded, requested: nil, observed: interface.currentMAC,
        startedAt: now, finishedAt: now
      )
      return commitLocked(reply: reply)
    case .hardware:
      guard let hardware = interface.hardwareMAC, hardware.isAssignable else {
        return reply(.failure(.hardwareAddressUnavailable))
      }
      (address, kind, source, policy) = (hardware, .restoreHardware, nil, .systemManaged)
    case let .history(entry):
      guard interface.history.contains(entry) else { return reply(.failure(.historyEntryMissing(entry))) }
      (address, kind, source, policy) = (entry, .restoreHistory, .historyRestore, .specified(entry))
    case let .specified(entry, confirmedGlobal):
      guard entry.isAssignable else { return reply(.failure(.invalidRequest("\(entry) is not assignable."))) }
      if !entry.isLocallyAdministered && !confirmedGlobal && entry != interface.hardwareMAC {
        return reply(.failure(.globalAddressNeedsConfirmation))
      }
      (address, kind, source, policy) = (entry, .restoreSpecified, .userSpecified, .specified(entry))
    }

    guard !env.legacyServiceDetected() else { return reply(.failure(.legacyServiceConflict)) }
    if address != interface.hardwareMAC,
       observed.values.contains(where: { $0.id != id && $0.kind.isSupported && $0.currentMAC == address }) {
      return reply(.failure(.addressInUse(address)))
    }

    if address == interface.currentMAC {
      // Already in place: record the choice without touching the link.
      guard !interface.isBusy else { return reply(.failure(.interfaceBusy(id))) }
      document.policies[key] = policy
      if let source { recordHistoryLocked(address, source: source, kind: kind, interface: interface) }
      let now = env.now()
      lastOperations[key] = OperationRecord(
        kind: kind, state: .succeeded, requested: address, observed: address, startedAt: now, finishedAt: now
      )
      return commitLocked(reply: reply)
    }

    if case let .denied(error) = SafetyPolicy.manual(interface, confirmedDisruption: confirmed) {
      return reply(.failure(error))
    }
    startWriteLocked(
      interface, target: address, kind: kind, source: source,
      resultingPolicy: policy, disconnectWiFi: confirmed, reply: reply
    )
  }

  // MARK: - Writing

  private func startWriteLocked(
    _ interface: InterfaceSnapshot,
    target: MACAddress,
    kind: OperationKind,
    source: HistorySource?,
    resultingPolicy: InterfacePolicy,
    disconnectWiFi: Bool,
    reply: Reply?
  ) {
    let id = interface.id
    let key = interface.deviceKey
    busy.insert(id)
    notices[key] = nil
    lastOperations[key] = OperationRecord(
      kind: kind, state: .running, requested: target, observed: interface.currentMAC, startedAt: env.now()
    )
    Log.daemon.info("\(kind.rawValue, privacy: .public) on \(id, privacy: .public) started")
    publishLocked()

    let writer = env.writer
    env.workQueue.async {
      let outcome = writer.write(target, to: interface, disconnectWiFi: disconnectWiFi)
      self.queue.async {
        self.finishWriteLocked(
          interface, target: target, kind: kind, source: source,
          resultingPolicy: resultingPolicy, outcome: outcome, reply: reply
        )
      }
    }
  }

  private func finishWriteLocked(
    _ interface: InterfaceSnapshot,
    target: MACAddress,
    kind: OperationKind,
    source: HistorySource?,
    resultingPolicy: InterfacePolicy,
    outcome: MACWriteOutcome,
    reply: Reply?
  ) {
    let id = interface.id
    let key = interface.deviceKey
    busy.remove(id)
    lastWriteAt[id] = env.now()
    readLocked()

    var record = lastOperations[key] ?? OperationRecord(
      kind: kind, state: .running, requested: target, observed: nil, startedAt: env.now()
    )
    record.state = outcome.succeeded ? .succeeded : .failed
    record.observed = outcome.observed ?? observed[id]?.currentMAC
    record.finishedAt = env.now()
    record.error = outcome.error
    record.disconnectedWiFi = outcome.disconnectedWiFi
    lastOperations[key] = record

    if outcome.succeeded {
      document.policies[key] = resultingPolicy
      document.pendingRotations[key] = nil
      if let source { recordHistoryLocked(target, source: source, kind: kind, interface: interface) }
      if outcome.disconnectedWiFi { scheduleWiFiFollowUpLocked(id: id, key: key, applied: target) }
      Log.daemon.info("\(kind.rawValue, privacy: .public) on \(id, privacy: .public) verified")
    } else {
      // An automatic rotation is not retried in a loop; the next trigger queues it again.
      if kind == .automaticRotation { document.pendingRotations[key] = nil }
      Log.daemon.error(
        "\(kind.rawValue, privacy: .public) on \(id, privacy: .public) failed: \(outcome.error?.message ?? "", privacy: .public)"
      )
    }

    persistLocked()
    publishLocked()
    if let error = outcome.error {
      reply?(.failure(error))
    } else {
      reply?(.success(snapshotLocked()))
    }
  }

  /// Hardware addresses are never stored; they are always available anyway.
  private func recordHistoryLocked(
    _ address: MACAddress, source: HistorySource, kind: OperationKind, interface: InterfaceSnapshot
  ) {
    guard address != interface.hardwareMAC else { return }
    var ledger = document.histories[interface.deviceKey] ?? HistoryLedger()
    let now = env.now()
    ledger.record(HistoryEntry(address: address, source: source, firstUsedAt: now, lastUsedAt: now, operation: kind))
    document.histories[interface.deviceKey] = ledger
  }

  /// macOS rejoins Wi-Fi by itself after the disconnect. If Private Wi-Fi
  /// Address is on for that network it swaps our address for its own; tell
  /// the user instead of leaving them guessing.
  private func scheduleWiFiFollowUpLocked(id: String, key: String, applied: MACAddress) {
    queue.asyncAfter(deadline: .now() + env.wifiFollowUpDelay) {
      self.readLocked()
      guard !self.busy.contains(id),
            let current = self.observed[id], current.deviceKey == key,
            self.lastOperations[key]?.requested == applied,
            let address = current.currentMAC, address != applied else { return }
      self.notices[key] = .addressReplacedAfterReconnect(applied: applied, current: address)
      Log.daemon.notice("macOS replaced the MAC on \(id, privacy: .public) after reconnecting")
      self.publishLocked()
    }
  }

  private func generateLocked(for interface: InterfaceSnapshot) throws -> (MACAddress, HistorySource) {
    let inUse = observed.values.flatMap { [$0.currentMAC, $0.hardwareMAC] }.compactMap { $0 }
    let excluded = Set(inUse).union(interface.history.addresses)
    if document.automation.vendorCompatibility {
      guard let oui = interface.hardwareMAC?.vendorOUI else { throw MACDancerError.hardwareAddressUnavailable }
      return (try MACAddress.randomWithVendor(oui, excluding: excluded, random: env.random), .vendorCompatible)
    }
    return (try MACAddress.randomLocal(excluding: excluded, random: env.random), .generatedLocal)
  }

  // MARK: - Automation

  private func handleLocked(_ event: SystemEvent) {
    let previous = observed.mapValues(managedLocked)
    readLocked()
    let current = observed.mapValues(managedLocked)

    switch event {
    case .willSleep:
      // Only record intent. Nothing is written while the Mac goes to sleep.
      queueRotationsLocked(
        AutomationPlanner.interfacesToQueue(for: .beforeSleep, settings: document.automation, current: current),
        trigger: .beforeSleep
      )
    case .didWake:
      queueRotationsLocked(
        AutomationPlanner.interfacesToQueue(for: .afterWake, settings: document.automation, current: current),
        trigger: .afterWake
      )
      queue.asyncAfter(deadline: .now() + env.wakeSettleDelay) { self.tick() }
    case .networkChanged:
      // Our own writes bounce the link; those transitions are not "the user
      // stopped using this interface".
      let now = env.now()
      let candidates = AutomationPlanner.interfacesToQueue(
        for: .becameInactive, settings: document.automation, previous: previous, current: current
      ).filter { id in lastWriteAt[id].map { now.timeIntervalSince($0) > 30 } ?? true }
      queueRotationsLocked(candidates, trigger: .becameInactive)
      runPendingLocked()
    }
    persistLocked()
    publishLocked()
  }

  private func queueRotationsLocked(_ ids: Set<String>, trigger: RotationTrigger) {
    for id in ids.sorted() {
      guard let key = observed[id]?.deviceKey, document.pendingRotations[key] == nil else { continue }
      document.pendingRotations[key] = PendingRotation(trigger: trigger, queuedAt: env.now())
      Log.daemon.info("Queued \(trigger.rawValue, privacy: .public) rotation for \(id, privacy: .public)")
    }
  }

  /// Starts at most one automatic write at a time; the rest wait for the next pass.
  private func runPendingLocked() {
    guard !document.pendingRotations.isEmpty, !env.legacyServiceDetected() else { return }
    let byKey = Dictionary(observed.values.map { ($0.deviceKey, $0) }, uniquingKeysWith: { first, _ in first })
    for key in document.pendingRotations.keys.sorted() {
      guard document.policies[key] == .random else {
        document.pendingRotations[key] = nil
        continue
      }
      guard let raw = byKey[key] else {
        document.pendingRotations[key]?.waitingReason = .interfaceMissing
        continue
      }
      let interface = managedLocked(raw)
      switch SafetyPolicy.automatic(interface) {
      case let .wait(reason):
        document.pendingRotations[key]?.waitingReason = reason
      case .denied:
        document.pendingRotations[key] = nil
      case .allowed:
        guard busy.isEmpty else {
          document.pendingRotations[key]?.waitingReason = .busy
          continue
        }
        do {
          let (target, source) = try generateLocked(for: interface)
          startWriteLocked(
            interface, target: target, kind: .automaticRotation, source: source,
            resultingPolicy: .random, disconnectWiFi: false, reply: nil
          )
        } catch {
          document.pendingRotations[key] = nil
          Log.daemon.error("Automatic rotation on \(interface.id, privacy: .public) could not start: \(MACDancerError(error).message, privacy: .public)")
        }
      }
    }
  }

  // MARK: - State

  private func readLocked() {
    do {
      let interfaces = try env.reader.interfaces()
      observed = Dictionary(interfaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      warnings["read"] = nil
    } catch {
      warnings["read"] = "Reading interfaces failed: \(MACDancerError(error).message)"
    }
  }

  /// Adds what MACDancer manages to the raw facts read from macOS.
  private func managedLocked(_ raw: InterfaceSnapshot) -> InterfaceSnapshot {
    var interface = raw
    let key = raw.deviceKey
    interface.policy = document.policies[key] ?? .systemManaged
    interface.history = document.histories[key] ?? HistoryLedger()
    interface.lastOperation = lastOperations[key]
    interface.pendingRotation = document.pendingRotations[key]
    interface.isBusy = busy.contains(raw.id)
    interface.notice = notices[key]
    return interface
  }

  private func supportedInterfaceLocked(_ id: String, reply: Reply) -> InterfaceSnapshot? {
    guard let raw = observed[id] else {
      reply(.failure(.interfaceNotFound(id)))
      return nil
    }
    guard raw.kind.isSupported else {
      reply(.failure(.unsupportedInterface(id)))
      return nil
    }
    return managedLocked(raw)
  }

  private func commitLocked(reply: Reply) {
    persistLocked()
    publishLocked()
    reply(.success(snapshotLocked()))
  }

  /// Writes only when something changed. A failed save is reported but never
  /// blocks the next action; it is retried on the next change or tick.
  private func persistLocked() {
    guard document != savedDocument else { return }
    do {
      try env.store.save(document)
      savedDocument = document
      warnings["save"] = nil
    } catch {
      let message = MACDancerError(error).message
      if warnings["save"] != message { Log.daemon.error("\(message, privacy: .public)") }
      warnings["save"] = message
    }
  }

  private func snapshotLocked() -> DaemonSnapshot {
    DaemonSnapshot(
      instanceID: instanceID,
      revision: revision,
      generatedAt: env.now(),
      interfaces: observed.values.map(managedLocked).sorted { $0.bsdName < $1.bsdName },
      automation: document.automation,
      legacyServiceDetected: env.legacyServiceDetected(),
      warnings: warnings.keys.sorted().compactMap { warnings[$0] },
      daemonVersion: env.version
    )
  }

  /// Pushes a snapshot to subscribers only when its content changed, so the
  /// periodic tick does not wake the GUI for nothing.
  private func publishLocked() {
    var content = snapshotLocked()
    content.revision = 0
    content.generatedAt = .distantPast
    content.interfaces = content.interfaces.map { interface in
      var interface = interface
      interface.observedAt = .distantPast
      return interface
    }
    guard content != lastPublishedContent else { return }
    lastPublishedContent = content
    revision &+= 1
    let snapshot = snapshotLocked()
    for subscriber in subscribers.values { subscriber(snapshot) }
  }
}
