import Combine
import Foundation

enum AppSection: String, CaseIterable, Hashable, Identifiable, Sendable {
  case dashboard, interfaces, automation, settings
  var id: String { rawValue }
}

/// One line the Dashboard shows about the background service.
enum ServiceStatus: Equatable, Sendable {
  case checking
  case notInstalled
  case awaitingApproval
  case connecting
  case ready
  case unreachable(String)
  case incompatible(daemonVersion: Int)
}

struct AppAlert: Identifiable, Equatable, Sendable {
  let id = UUID()
  let title: String
  let message: String
}

/// GUI state and the only place that talks to the daemon client.
@MainActor
final class AppModel: ObservableObject {
  static let showAllInterfacesKey = "showAllInterfaces"
  static let autoRepairedVersionKey = "autoRepairedServiceForVersion"

  @Published var selection: AppSection = .dashboard
  @Published var language: AppLanguage {
    didSet { Localizer.use(language) }
  }
  @Published var showAllInterfaces: Bool {
    didSet { defaults.set(showAllInterfaces, forKey: Self.showAllInterfacesKey) }
  }

  /// Every interface, merged from the local read and the daemon.
  @Published private(set) var interfaces: [InterfaceSnapshot] = []
  @Published private(set) var registration: ServiceRegistration = .unknown
  @Published private(set) var connection: ConnectionState = .idle
  @Published private(set) var daemonSnapshot: DaemonSnapshot?
  @Published private(set) var localLegacyServiceDetected = false
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastRefreshAt: Date?
  @Published private(set) var isChangingService = false
  @Published private(set) var isUpdatingAutomation = false
  /// Interfaces with a request on its way to the daemon.
  @Published private(set) var requestsInFlight: Set<String> = []
  @Published var alert: AppAlert?

  private let client: DaemonClientProviding
  private let service: ServiceControlling
  private let reader: LocalInterfaceReading
  private let defaults: UserDefaults
  private var localInterfaces: [InterfaceSnapshot] = []
  private var started = false
  private var refreshAgain = false
  private let appVersion: String
  private let autoRepairDelay: Duration
  private var autoRepairTask: Task<Void, Never>?

  init(
    client: DaemonClientProviding,
    service: ServiceControlling,
    reader: LocalInterfaceReading,
    defaults: UserDefaults = .standard,
    appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
    autoRepairDelay: Duration = .seconds(25)
  ) {
    self.client = client
    self.service = service
    self.reader = reader
    self.defaults = defaults
    self.appVersion = appVersion
    self.autoRepairDelay = autoRepairDelay
    language = Localizer.storedLanguage
    showAllInterfaces = defaults.bool(forKey: Self.showAllInterfacesKey)
    client.onSnapshot = { [weak self] in self?.apply($0) }
    client.onConnectionChange = { [weak self] in self?.connectionChanged($0) }
  }

  // MARK: - Derived state

  var status: ServiceStatus {
    switch registration {
    case .unknown: return .checking
    case .notInstalled: return .notInstalled
    case .requiresApproval: return .awaitingApproval
    case .enabled:
      switch connection {
      case .idle, .connecting: return .connecting
      case .connected: return .ready
      case let .unreachable(reason): return .unreachable(reason)
      case let .incompatible(version): return .incompatible(daemonVersion: version)
      }
    }
  }

  var isReady: Bool { status == .ready }
  var legacyServiceDetected: Bool { localLegacyServiceDetected || daemonSnapshot?.legacyServiceDetected == true }
  var automation: AutomationSettings { daemonSnapshot?.automation ?? AutomationSettings() }
  var warnings: [String] { isReady ? daemonSnapshot?.warnings ?? [] : [] }

  /// Wi-Fi and Ethernet adapters that are real hardware, unless the user
  /// asked to see everything. Anything MACDancer manages always stays visible.
  var visibleInterfaces: [InterfaceSnapshot] {
    guard !showAllInterfaces else { return interfaces }
    return interfaces.filter { interface in
      (interface.kind.isSupported && !interface.isLikelyVirtual) || interface.policy != .systemManaged
    }
  }

  var hiddenInterfaceCount: Int { interfaces.count - visibleInterfaces.count }

  /// Why `interface` cannot be changed right now, or nil when it can.
  /// Requests that only stop MACDancer from writing stay possible while
  /// LinkLiar is installed.
  func blockedReason(for interface: InterfaceSnapshot, allowingLegacyConflict: Bool = false) -> String? {
    if !interface.kind.isSupported { return L("blocked.unsupported", "Only Wi-Fi and Ethernet are supported.") }
    if !isReady { return L("blocked.service", "The background service is not ready.") }
    if isBusy(interface) { return L("blocked.busy", "A change is in progress.") }
    if legacyServiceDetected && !allowingLegacyConflict { return MACDancerError.legacyServiceConflict.localizedMessage }
    return nil
  }

  func isBusy(_ interface: InterfaceSnapshot) -> Bool {
    interface.isBusy || requestsInFlight.contains(interface.id)
  }

  // MARK: - Lifecycle

  func start() {
    guard !started else { return }
    started = true
    refresh()
    Task {
      async let registration = service.registration()
      async let legacy = service.legacyServiceInstalled()
      localLegacyServiceDetected = await legacy
      updateRegistration(await registration)
    }
  }

  /// Re-checks registration, e.g. after the user approved the service in System Settings.
  func recheckService() {
    guard started, !isChangingService else { return }
    Task { updateRegistration(await service.registration()) }
  }

  /// Reads current addresses from macOS. Never contacts the daemon and never
  /// changes anything.
  func refresh() {
    guard !isRefreshing else {
      refreshAgain = true
      return
    }
    isRefreshing = true
    Task {
      defer {
        isRefreshing = false
        if refreshAgain {
          refreshAgain = false
          refresh()
        }
      }
      do {
        localInterfaces = try await reader.interfaces()
        lastRefreshAt = Date()
        rebuildInterfaces()
      } catch {
        present(L("alert.read_failed", "Could not read network interfaces"), error)
      }
    }
  }

  private func connectionChanged(_ state: ConnectionState) {
    connection = state
    switch state {
    case .unreachable, .incompatible:
      scheduleAutoRepair()
    case .connected:
      autoRepairTask?.cancel()
      autoRepairTask = nil
    case .idle, .connecting:
      break
    }
  }

  /// After an update the old daemon may still be running. A new daemon
  /// restarts itself within seconds; one from before self-restart existed
  /// cannot, so the service is re-registered once per app version if it is
  /// still unreachable after a grace period.
  private func scheduleAutoRepair() {
    guard autoRepairTask == nil, defaults.string(forKey: Self.autoRepairedVersionKey) != appVersion else { return }
    autoRepairTask = Task { [weak self, autoRepairDelay] in
      try? await Task.sleep(for: autoRepairDelay)
      guard let self, !Task.isCancelled else { return }
      self.autoRepairTask = nil
      guard self.registration == .enabled, !self.isReady, !self.isChangingService,
            self.defaults.string(forKey: Self.autoRepairedVersionKey) != self.appVersion else { return }
      self.defaults.set(self.appVersion, forKey: Self.autoRepairedVersionKey)
      Log.app.notice("Background service still unreachable; re-registering it once for this version")
      self.repairService()
    }
  }

  private func updateRegistration(_ state: ServiceRegistration) {
    registration = state
    if state == .enabled { client.start() } else { client.stop() }
  }

  private func apply(_ snapshot: DaemonSnapshot) {
    if let current = daemonSnapshot, current.instanceID == snapshot.instanceID, snapshot.revision < current.revision {
      return // An older reply arrived after a newer push.
    }
    daemonSnapshot = snapshot
    rebuildInterfaces()
  }

  private func rebuildInterfaces() {
    interfaces = Self.merge(local: localInterfaces, daemon: daemonSnapshot)
  }

  /// Live facts come from whichever read is newer; what MACDancer manages
  /// (policy, history, operations) always comes from the daemon.
  static func merge(local: [InterfaceSnapshot], daemon: DaemonSnapshot?) -> [InterfaceSnapshot] {
    guard let daemon else { return local }
    let localAt = local.map(\.observedAt).max() ?? .distantPast
    let daemonAt = daemon.interfaces.map(\.observedAt).max() ?? .distantPast
    let managed = Dictionary(daemon.interfaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let base = daemonAt >= localAt ? daemon.interfaces : local
    return base.map { interface in
      guard let source = managed[interface.id], source.deviceKey == interface.deviceKey else { return interface }
      var merged = interface
      merged.policy = source.policy
      merged.history = source.history
      merged.lastOperation = source.lastOperation
      merged.pendingRotation = source.pendingRotation
      merged.isBusy = source.isBusy
      merged.notice = source.notice
      return merged
    }
    .sorted { $0.bsdName < $1.bsdName }
  }

  // MARK: - Background service

  func installService() { changeService(L("alert.install_failed", "Could not install the background service"), service.install) }
  func uninstallService() { changeService(L("alert.uninstall_failed", "Could not uninstall the background service"), service.uninstall) }
  func repairService() { changeService(L("alert.repair_failed", "Could not repair the background service"), service.repair) }
  func openApprovalSettings() { service.openApprovalSettings() }

  private func changeService(_ failureTitle: String, _ action: @escaping () async throws -> Void) {
    guard !isChangingService else { return }
    isChangingService = true
    Task {
      defer { isChangingService = false }
      if await service.legacyServiceInstalled() {
        localLegacyServiceDetected = true
      }
      client.stop()
      do {
        try await action()
      } catch {
        present(failureTitle, error)
      }
      updateRegistration(await service.registration())
    }
  }

  // MARK: - Interface actions

  /// Changing an interface that is in use needs the user's confirmation
  /// first; for connected Wi-Fi that means a disconnect.
  func needsConfirmation(_ interface: InterfaceSnapshot) -> Bool { interface.isInUse }

  func randomize(_ interface: InterfaceSnapshot, confirmed: Bool) {
    send(
      .randomize(interfaceID: interface.id, confirmedDisruption: confirmed),
      for: interface, failureTitle: L("alert.randomize_failed", "Could not randomize the MAC address")
    )
  }

  func restore(_ interface: InterfaceSnapshot, to target: RestoreTarget, confirmed: Bool) {
    send(
      .restore(interfaceID: interface.id, target: target, confirmedDisruption: confirmed),
      for: interface, failureTitle: L("alert.restore_failed", "Could not restore the MAC address")
    )
  }

  func setPolicy(_ interface: InterfaceSnapshot, _ choice: PolicyChoice) {
    send(
      .setPolicy(interfaceID: interface.id, policy: choice),
      for: interface, failureTitle: L("alert.policy_failed", "Could not change the policy")
    )
  }

  func removeHistory(_ interface: InterfaceSnapshot, address: MACAddress?) {
    send(
      .removeHistory(interfaceID: interface.id, address: address),
      for: interface, failureTitle: L("alert.history_failed", "Could not change the history")
    )
  }

  func cancelPending(_ interface: InterfaceSnapshot) {
    send(
      .cancelPending(interfaceID: interface.id),
      for: interface, failureTitle: L("alert.cancel_failed", "Could not cancel the pending rotation")
    )
  }

  func setAutomation(_ settings: AutomationSettings) {
    guard isReady, !isUpdatingAutomation else { return }
    isUpdatingAutomation = true
    Task {
      defer { isUpdatingAutomation = false }
      do {
        apply(try await client.send(.updateAutomation(settings)))
      } catch {
        present(L("alert.automation_failed", "Could not update automation"), error)
      }
    }
  }

  private func send(_ request: DaemonRequest, for interface: InterfaceSnapshot, failureTitle: String) {
    if let reason = blockedReason(for: interface, allowingLegacyConflict: request.onlyReducesManagement) {
      alert = AppAlert(title: failureTitle, message: reason)
      return
    }
    requestsInFlight.insert(interface.id)
    Task {
      defer { requestsInFlight.remove(interface.id) }
      do {
        apply(try await client.send(request))
      } catch {
        let error = MACDancerError(error)
        if error == .timeout {
          // The write may still finish; show whatever the daemon reports next.
          if let snapshot = try? await client.send(.snapshot) { apply(snapshot) }
        }
        present(failureTitle, error)
      }
      if request.mayWriteAddress { refresh() }
    }
  }

  private func present(_ title: String, _ error: Error) {
    let nsError = error as NSError
    let message = error is MACDancerError || nsError.domain == MACDancerConstants.errorDomain
      ? MACDancerError(error).localizedMessage
      : nsError.localizedDescription
    alert = AppAlert(title: title, message: message)
  }
}

private extension DaemonRequest {
  /// True for requests that never write an address or enable automation.
  var onlyReducesManagement: Bool {
    switch self {
    case .restore(_, .systemManaged, _), .setPolicy(_, .systemManaged), .removeHistory, .cancelPending: true
    default: false
    }
  }
}
