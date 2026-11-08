import XCTest

@MainActor
final class AppModelTests: XCTestCase {
  private func makeModel(
    registration: ServiceRegistration = .enabled,
    local: [InterfaceSnapshot] = [makeInterface("en5")],
    defaults: UserDefaults = UserDefaults(suiteName: "MACDancerTests-\(UUID().uuidString)")!
  ) -> (AppModel, FakeClient, FakeService) {
    let client = FakeClient()
    let service = FakeService(registration)
    let model = AppModel(
      client: client, service: service, reader: FakeLocalReader(local), defaults: defaults,
      appVersion: "2.0.0", autoRepairDelay: .milliseconds(50)
    )
    return (model, client, service)
  }

  func testOutdatedServiceIsRepairedOncePerVersion() async {
    let defaults = UserDefaults(suiteName: "MACDancerTests-\(UUID().uuidString)")!
    let (model, client, service) = makeModel(defaults: defaults)
    model.start()
    await waitUntil { client.started }
    client.onConnectionChange?(.unreachable("old daemon"))
    await waitUntil { service.repairs == 1 }

    // Still broken after the repair: no loop.
    client.onConnectionChange?(.unreachable("still old"))
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(service.repairs, 1)

    // A later launch of the same version does not repair again either.
    let (second, secondClient, secondService) = makeModel(defaults: defaults)
    second.start()
    await waitUntil { secondClient.started }
    secondClient.onConnectionChange?(.incompatible(daemonVersion: 1))
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(secondService.repairs, 0)
  }

  func testShortOutageDoesNotTriggerRepair() async {
    let (model, client, service) = makeModel()
    model.start()
    await waitUntil { client.started }
    client.onConnectionChange?(.unreachable("restarting"))
    client.connect()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(service.repairs, 0)
  }

  private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
  }

  func testStartsReadOnlyAndConnectsOnlyWhenRegistered() async {
    let (model, client, _) = makeModel(registration: .notInstalled)
    model.start()
    await waitUntil { model.registration == .notInstalled && !model.interfaces.isEmpty }
    XCTAssertEqual(model.status, .notInstalled)
    XCTAssertFalse(client.started)
    XCTAssertEqual(model.interfaces.map(\.id), ["en5"], "local reading works without the daemon")
  }

  func testReadyOnlyWhenRegisteredAndConnected() async {
    let (model, client, _) = makeModel()
    model.start()
    await waitUntil { client.started }
    XCTAssertEqual(model.status, .connecting)
    client.connect()
    XCTAssertEqual(model.status, .ready)
    client.onConnectionChange?(.incompatible(daemonVersion: 1))
    XCTAssertEqual(model.status, .incompatible(daemonVersion: 1))
  }

  func testActionsAreRefusedUntilTheServiceIsReady() async {
    let (model, client, _) = makeModel()
    model.start()
    await waitUntil { !model.interfaces.isEmpty }
    model.randomize(model.interfaces[0], confirmed: false)
    XCTAssertNotNil(model.alert)
    XCTAssertTrue(client.requests.isEmpty)
  }

  func testRandomizeSendsRequestAndShowsTheDaemonResult() async {
    let (model, client, _) = makeModel()
    model.start()
    await waitUntil { client.started && !model.interfaces.isEmpty }
    client.connect()

    var updated = makeInterface("en5", current: "02:00:00:00:00:01")
    updated.policy = .random
    client.reply = .success(client.snapshot([updated], revision: 2))
    model.randomize(model.interfaces[0], confirmed: true)
    XCTAssertTrue(model.isBusy(model.interfaces[0]), "busy as soon as the request leaves")

    await waitUntil { model.interfaces.first?.policy == .random }
    XCTAssertEqual(client.requests, [.randomize(interfaceID: "en5", confirmedDisruption: true)])
    XCTAssertNil(model.alert)
  }

  func testTimeoutRereadsInsteadOfClaimingFailure() async {
    let (model, client, _) = makeModel()
    model.start()
    await waitUntil { client.started && !model.interfaces.isEmpty }
    client.connect()
    client.reply = .failure(.timeout)
    client.replyAfterFailure = .success(client.snapshot([makeInterface("en5")], revision: 3))
    model.randomize(model.interfaces[0], confirmed: false)
    await waitUntil { client.requests.count == 2 }
    XCTAssertEqual(client.requests.last, .snapshot)
    await waitUntil { model.alert != nil }
  }

  func testLegacyConflictStillAllowsHandoff() async {
    let (model, client, service) = makeModel()
    service.legacy = true
    model.start()
    await waitUntil { model.legacyServiceDetected && client.started && !model.interfaces.isEmpty }
    client.connect()

    model.randomize(model.interfaces[0], confirmed: false)
    XCTAssertTrue(client.requests.isEmpty)
    model.alert = nil
    client.reply = .success(client.snapshot([makeInterface("en5")], revision: 1))
    model.restore(model.interfaces[0], to: .systemManaged, confirmed: false)
    await waitUntil { !client.requests.isEmpty }
    XCTAssertEqual(client.requests, [.restore(interfaceID: "en5", target: .systemManaged, confirmedDisruption: false)])
  }

  func testVirtualInterfacesAreHiddenUnlessManagedOrRequested() async {
    let thunderbolt = makeInterface("en1", hardware: "3a:00:00:00:00:01")
    let (model, _, _) = makeModel(local: [makeInterface("en5"), thunderbolt, makeInterface("bridge0", kind: .other, hardware: "3a:00:00:00:00:01")])
    model.start()
    await waitUntil { model.interfaces.count == 3 }
    XCTAssertEqual(model.visibleInterfaces.map(\.id), ["en5"])
    XCTAssertEqual(model.hiddenInterfaceCount, 2)
    model.showAllInterfaces = true
    XCTAssertEqual(model.visibleInterfaces.count, 3)
  }

  func testMergeTakesLiveFactsFromTheNewerReadAndManagementFromTheDaemon() {
    let old = Date(timeIntervalSince1970: 100)
    let new = Date(timeIntervalSince1970: 200)
    var daemonSide = makeInterface("en5", current: "02:00:00:00:00:01", observedAt: old)
    daemonSide.policy = .random
    let local = makeInterface("en5", current: "02:00:00:00:00:02", active: true, observedAt: new)
    let snapshot = FakeClient().snapshot([daemonSide], revision: 1)

    let merged = AppModel.merge(local: [local], daemon: snapshot)
    XCTAssertEqual(merged.first?.currentMAC, mac("02:00:00:00:00:02"), "newer local read wins for live facts")
    XCTAssertEqual(merged.first?.isActive, true)
    XCTAssertEqual(merged.first?.policy, .random, "policy always comes from the daemon")

    let newerDaemon = makeInterface("en5", current: "02:00:00:00:00:03", observedAt: new.addingTimeInterval(1))
    let merged2 = AppModel.merge(local: [local], daemon: FakeClient().snapshot([newerDaemon], revision: 2))
    XCTAssertEqual(merged2.first?.currentMAC, mac("02:00:00:00:00:03"))
  }

  func testOlderSnapshotFromTheSameDaemonIsIgnored() async {
    let (model, client, _) = makeModel()
    model.start()
    await waitUntil { client.started }
    var managed = makeInterface("en5")
    managed.policy = .random
    client.onSnapshot?(client.snapshot([managed], revision: 5))
    client.onSnapshot?(client.snapshot([makeInterface("en5")], revision: 4))
    XCTAssertEqual(model.daemonSnapshot?.revision, 5)
  }
}

@MainActor
private final class FakeClient: DaemonClientProviding {
  var onSnapshot: ((DaemonSnapshot) -> Void)?
  var onConnectionChange: ((ConnectionState) -> Void)?
  private(set) var started = false
  private(set) var requests: [DaemonRequest] = []
  var reply: Result<DaemonSnapshot, MACDancerError> = .failure(.timeout)
  var replyAfterFailure: Result<DaemonSnapshot, MACDancerError>?
  let instanceID = UUID()

  func start() { started = true }
  func stop() { started = false }

  func connect() { onConnectionChange?(.connected) }

  func send(_ request: DaemonRequest) async throws -> DaemonSnapshot {
    requests.append(request)
    let result: Result<DaemonSnapshot, MACDancerError>
    if requests.count > 1, let replyAfterFailure { result = replyAfterFailure } else { result = reply }
    return try result.get()
  }

  func snapshot(_ interfaces: [InterfaceSnapshot], revision: UInt64) -> DaemonSnapshot {
    DaemonSnapshot(
      instanceID: instanceID, revision: revision, generatedAt: Date(), interfaces: interfaces,
      automation: AutomationSettings(), legacyServiceDetected: false, warnings: []
    )
  }
}

@MainActor
private final class FakeService: ServiceControlling {
  var state: ServiceRegistration
  var legacy = false
  init(_ state: ServiceRegistration) { self.state = state }

  func registration() async -> ServiceRegistration { state }
  func legacyServiceInstalled() async -> Bool { legacy }
  func install() async throws { state = .enabled }
  func uninstall() async throws { state = .notInstalled }
  private(set) var repairs = 0
  func repair() async throws { repairs += 1 }
  func openApprovalSettings() {}
}

private struct FakeLocalReader: LocalInterfaceReading {
  let result: [InterfaceSnapshot]
  init(_ result: [InterfaceSnapshot]) { self.result = result }
  func interfaces() async throws -> [InterfaceSnapshot] { result }
}
