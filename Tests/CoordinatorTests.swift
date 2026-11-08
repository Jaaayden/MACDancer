import XCTest

final class CoordinatorTests: XCTestCase {
  private let generated = mac("12:aa:bb:cc:dd:ee")

  private func interface(_ snapshot: DaemonSnapshot, _ name: String) -> InterfaceSnapshot {
    snapshot.interfaces.first { $0.bsdName == name }!
  }

  // MARK: Manual changes

  func testRandomizeWritesVerifiedLocalAddressAndRemembersIt() throws {
    let system = FakeSystem([makeInterface("en5")])
    let store = MemoryStore()
    let coordinator = makeCoordinator(system, store: store)

    let result = try send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)).get()
    let en5 = interface(result, "en5")
    XCTAssertEqual(en5.currentMAC, generated)
    XCTAssertEqual(en5.policy, .random)
    XCTAssertEqual(en5.history.entries.map(\.address), [generated])
    XCTAssertEqual(en5.lastOperation?.state, .succeeded)
    XCTAssertFalse(en5.isBusy)
    XCTAssertEqual(store.document.policies[en5.deviceKey], .random)
  }

  func testInterfaceInUseNeedsConfirmation() {
    let system = FakeSystem([makeInterface("en5", active: true)])
    let coordinator = makeCoordinator(system)
    XCTAssertEqual(send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)), .failure(.confirmationRequired))
    XCTAssertEqual(system.writeCount, 0)
    XCTAssertNoThrow(try send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: true)).get())
    XCTAssertEqual(system.writeCount, 1)
  }

  func testConnectedWiFiIsDisconnectedOnlyWithConfirmation() throws {
    let system = FakeSystem([makeInterface("en0", kind: .wifi, hardware: "a0:b1:c2:00:00:01", active: true, wifiAssociated: true)])
    let coordinator = makeCoordinator(system)
    XCTAssertEqual(send(coordinator, .randomize(interfaceID: "en0", confirmedDisruption: false)), .failure(.confirmationRequired))

    let result = try send(coordinator, .randomize(interfaceID: "en0", confirmedDisruption: true)).get()
    XCTAssertEqual(system.writes.last?.2, true, "the writer was allowed to disconnect")
    XCTAssertEqual(interface(result, "en0").lastOperation?.disconnectedWiFi, true)
  }

  func testUserIsToldWhenMacOSReplacesTheAddressAfterRejoining() throws {
    let system = FakeSystem([makeInterface("en0", kind: .wifi, hardware: "a0:b1:c2:00:00:01", wifiAssociated: true)])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .randomize(interfaceID: "en0", confirmedDisruption: true)).get()

    // macOS rejoins with its own private address.
    system.update("en0") {
      $0.isWiFiAssociated = true
      $0.currentMAC = mac("fe:00:00:00:00:99")
    }
    Thread.sleep(forTimeInterval: 0.2)
    let notice = interface(snapshot(coordinator), "en0").notice
    XCTAssertEqual(notice, .addressReplacedAfterReconnect(applied: generated, current: mac("fe:00:00:00:00:99")))
  }

  func testStatusIsAnsweredWhileAWriteIsRunning() throws {
    let system = FakeSystem([makeInterface("en5")])
    let gate = DispatchSemaphore(value: 0)
    let blocking = BlockingWriter(system: system, gate: gate)
    let coordinator = DaemonCoordinator(environment: .init(
      reader: system, writer: blocking, store: MemoryStore(), legacyServiceDetected: { false },
      random: ScriptedRandom([[0x10, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]]).source
    ))

    let finished = expectation(description: "write finished")
    coordinator.handle(.randomize(interfaceID: "en5", confirmedDisruption: false)) { _ in finished.fulfill() }

    // While the address write is running, a heartbeat still gets an answer at once.
    let status = try send(coordinator, .snapshot).get()
    XCTAssertTrue(interface(status, "en5").isBusy)
    XCTAssertEqual(interface(status, "en5").lastOperation?.state, .running)
    XCTAssertEqual(
      send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)),
      .failure(.interfaceBusy("en5"))
    )

    gate.signal()
    wait(for: [finished], timeout: 5)
    XCTAssertFalse(interface(snapshot(coordinator), "en5").isBusy)
  }

  func testFailedWriteIsReportedAndChangesNothingElse() {
    let system = FakeSystem([makeInterface("en5")])
    system.nextWriteError = .readbackMismatch(expected: generated, observed: mac("00:11:22:33:44:55"))
    let coordinator = makeCoordinator(system)

    XCTAssertEqual(
      send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)),
      .failure(.readbackMismatch(expected: generated, observed: mac("00:11:22:33:44:55")))
    )
    let en5 = interface(snapshot(coordinator), "en5")
    XCTAssertEqual(en5.policy, .systemManaged)
    XCTAssertTrue(en5.history.entries.isEmpty)
    XCTAssertEqual(en5.lastOperation?.state, .failed)
  }

  func testSaveFailureIsAWarningNotALockout() throws {
    let system = FakeSystem([makeInterface("en5")])
    let store = MemoryStore()
    store.failSaves = true
    let coordinator = makeCoordinator(system, store: store)

    let first = try send(coordinator, .setPolicy(interfaceID: "en5", policy: .random)).get()
    XCTAssertFalse(first.warnings.isEmpty)
    XCTAssertNoThrow(try send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)).get())

    store.failSaves = false
    coordinator.tick()
    settle(coordinator)
    XCTAssertTrue(snapshot(coordinator).warnings.isEmpty, "the next tick retries the save")
    XCTAssertEqual(store.document.policies.values.first, .random)
  }

  func testLegacyServiceBlocksWritesButNotHandoff() {
    let system = FakeSystem([makeInterface("en5")])
    let coordinator = makeCoordinator(system, legacy: Flag(true))
    XCTAssertEqual(send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)), .failure(.legacyServiceConflict))
    XCTAssertEqual(send(coordinator, .setPolicy(interfaceID: "en5", policy: .random)), .failure(.legacyServiceConflict))
    XCTAssertNoThrow(try send(coordinator, .restore(interfaceID: "en5", target: .systemManaged, confirmedDisruption: false)).get())
    XCTAssertEqual(system.writeCount, 0)
  }

  func testUnsupportedAndMissingInterfacesAreRefused() {
    let system = FakeSystem([makeInterface("bridge0", kind: .other)])
    let coordinator = makeCoordinator(system)
    XCTAssertEqual(send(coordinator, .randomize(interfaceID: "bridge0", confirmedDisruption: true)), .failure(.unsupportedInterface("bridge0")))
    XCTAssertEqual(send(coordinator, .randomize(interfaceID: "en9", confirmedDisruption: true)), .failure(.interfaceNotFound("en9")))
  }

  // MARK: Restore

  func testRestoreHardwareHandsBackWithoutStoringHistory() throws {
    let system = FakeSystem([makeInterface("en5", current: "02:00:00:00:00:07")])
    let coordinator = makeCoordinator(system)
    let en5 = interface(try send(coordinator, .restore(interfaceID: "en5", target: .hardware, confirmedDisruption: false)).get(), "en5")
    XCTAssertEqual(en5.currentMAC, mac("00:11:22:33:44:55"))
    XCTAssertEqual(en5.policy, .systemManaged)
    XCTAssertTrue(en5.history.entries.isEmpty)
  }

  func testSpecifiedGlobalAddressNeedsSecondConfirmation() throws {
    let system = FakeSystem([makeInterface("en5")])
    let coordinator = makeCoordinator(system)
    let vendor = mac("a4:83:e7:00:00:01")
    XCTAssertEqual(
      send(coordinator, .restore(interfaceID: "en5", target: .specified(vendor, confirmedGlobalAddress: false), confirmedDisruption: false)),
      .failure(.globalAddressNeedsConfirmation)
    )
    let en5 = interface(
      try send(coordinator, .restore(interfaceID: "en5", target: .specified(vendor, confirmedGlobalAddress: true), confirmedDisruption: false)).get(),
      "en5"
    )
    XCTAssertEqual(en5.policy, .specified(vendor))
    XCTAssertEqual(en5.history.entries.first?.source, .userSpecified)
  }

  func testRestoreToTheCurrentAddressDoesNotTouchTheLink() throws {
    let system = FakeSystem([makeInterface("en5", current: "02:00:00:00:00:07", active: true)])
    let coordinator = makeCoordinator(system)
    let target = RestoreTarget.specified(mac("02:00:00:00:00:07"), confirmedGlobalAddress: false)
    let en5 = interface(try send(coordinator, .restore(interfaceID: "en5", target: target, confirmedDisruption: false)).get(), "en5")
    XCTAssertEqual(system.writeCount, 0)
    XCTAssertEqual(en5.policy, .specified(mac("02:00:00:00:00:07")))
  }

  func testRestoreRefusesAnAddressUsedElsewhere() {
    let system = FakeSystem([makeInterface("en5"), makeInterface("en6", current: "02:00:00:00:00:07", hardware: "00:11:22:33:44:66")])
    let coordinator = makeCoordinator(system)
    let target = RestoreTarget.specified(mac("02:00:00:00:00:07"), confirmedGlobalAddress: false)
    XCTAssertEqual(
      send(coordinator, .restore(interfaceID: "en5", target: target, confirmedDisruption: false)),
      .failure(.addressInUse(mac("02:00:00:00:00:07")))
    )
  }

  func testHistoryRestoreOnlyAcceptsKnownAddresses() throws {
    let system = FakeSystem([makeInterface("en5")])
    let coordinator = makeCoordinator(system, random: ScriptedRandom([[0x10, 1, 1, 1, 1, 1], [0x10, 2, 2, 2, 2, 2]]).source)
    _ = try send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)).get()
    _ = try send(coordinator, .randomize(interfaceID: "en5", confirmedDisruption: false)).get()

    let first = mac("12:01:01:01:01:01")
    let en5 = interface(try send(coordinator, .restore(interfaceID: "en5", target: .history(first), confirmedDisruption: false)).get(), "en5")
    XCTAssertEqual(en5.currentMAC, first)
    XCTAssertEqual(en5.policy, .specified(first))
    XCTAssertEqual(
      send(coordinator, .restore(interfaceID: "en5", target: .history(mac("02:99:99:99:99:99")), confirmedDisruption: false)),
      .failure(.historyEntryMissing(mac("02:99:99:99:99:99")))
    )
  }

  func testPoliciesFollowTheAdapterNotTheName() throws {
    let system = FakeSystem([makeInterface("en7", hardware: "00:11:22:33:44:55")])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .setPolicy(interfaceID: "en7", policy: .random)).get()

    // A different USB adapter shows up under the same BSD name.
    system.update("en7") { $0 = makeInterface("en7", hardware: "00:aa:aa:aa:aa:aa") }
    coordinator.tick()
    settle(coordinator)
    XCTAssertEqual(interface(snapshot(coordinator), "en7").policy, .systemManaged)
  }

  // MARK: Automation

  func testRotatesWhenARandomInterfaceStopsBeingUsed() throws {
    let system = FakeSystem([makeInterface("en5", active: true)])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .setPolicy(interfaceID: "en5", policy: .random)).get()
    _ = try send(coordinator, .updateAutomation(.init(rotateWhenInterfaceBecomesInactive: true))).get()

    system.update("en5") { $0.isActive = false }
    coordinator.handle(.networkChanged)
    settle(coordinator)

    XCTAssertEqual(system.writeCount, 1)
    let en5 = interface(snapshot(coordinator), "en5")
    XCTAssertEqual(en5.lastOperation?.kind, .automaticRotation)
    XCTAssertEqual(en5.currentMAC, generated)
    XCTAssertNil(en5.pendingRotation)
  }

  func testAutomaticRotationWaitsWhileInUseThenRuns() throws {
    let system = FakeSystem([makeInterface("en5", active: true)])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .setPolicy(interfaceID: "en5", policy: .random)).get()
    _ = try send(coordinator, .updateAutomation(.init(rotateAfterWake: true))).get()

    coordinator.handle(.didWake)
    settle(coordinator)
    Thread.sleep(forTimeInterval: 0.15) // wake settle delay
    settle(coordinator)
    XCTAssertEqual(system.writeCount, 0)
    XCTAssertEqual(interface(snapshot(coordinator), "en5").pendingRotation?.waitingReason, .inUse)

    system.update("en5") { $0.isActive = false }
    coordinator.tick()
    settle(coordinator)
    XCTAssertEqual(system.writeCount, 1)
    XCTAssertNil(interface(snapshot(coordinator), "en5").pendingRotation)
  }

  func testSleepOnlyQueuesWork() throws {
    let system = FakeSystem([makeInterface("en5")])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .setPolicy(interfaceID: "en5", policy: .random)).get()
    _ = try send(coordinator, .updateAutomation(.init(prepareRotationBeforeSleep: true))).get()

    coordinator.handle(.willSleep)
    settle(coordinator)
    XCTAssertEqual(system.writeCount, 0)
    XCTAssertEqual(interface(snapshot(coordinator), "en5").pendingRotation?.trigger, .beforeSleep)
  }

  func testFailedAutomaticRotationIsNotRetriedInALoop() throws {
    let system = FakeSystem([makeInterface("en5", active: true)])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .setPolicy(interfaceID: "en5", policy: .random)).get()
    _ = try send(coordinator, .updateAutomation(.init(rotateWhenInterfaceBecomesInactive: true))).get()

    system.nextWriteError = .commandFailed("rejected")
    system.update("en5") { $0.isActive = false }
    coordinator.handle(.networkChanged)
    settle(coordinator)
    coordinator.tick()
    coordinator.tick()
    settle(coordinator)
    XCTAssertEqual(system.writeCount, 1)
    XCTAssertEqual(interface(snapshot(coordinator), "en5").lastOperation?.state, .failed)
  }

  func testOwnWriteDoesNotTriggerAnotherRotation() throws {
    let system = FakeSystem([makeInterface("en0", kind: .wifi, hardware: "a0:b1:c2:00:00:01", wifiAssociated: true)])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .updateAutomation(.init(rotateWhenInterfaceBecomesInactive: true))).get()
    // The manual change disconnects Wi-Fi, which looks like "stopped being used".
    _ = try send(coordinator, .randomize(interfaceID: "en0", confirmedDisruption: true)).get()
    coordinator.handle(.networkChanged)
    settle(coordinator)
    XCTAssertEqual(system.writeCount, 1)
  }

  func testTurningAutomationOffDropsPendingWork() throws {
    let system = FakeSystem([makeInterface("en5", active: true)])
    let coordinator = makeCoordinator(system)
    _ = try send(coordinator, .setPolicy(interfaceID: "en5", policy: .random)).get()
    _ = try send(coordinator, .updateAutomation(.init(rotateAfterWake: true))).get()
    coordinator.handle(.didWake)
    settle(coordinator)
    XCTAssertNotNil(interface(snapshot(coordinator), "en5").pendingRotation)

    _ = try send(coordinator, .updateAutomation(.init())).get()
    XCTAssertNil(interface(snapshot(coordinator), "en5").pendingRotation)
  }

  // MARK: Publishing

  func testUnchangedStateIsNotRepublished() {
    let system = FakeSystem([makeInterface("en5")])
    let coordinator = makeCoordinator(system)
    var pushes = 0
    coordinator.addSubscriber { _ in pushes += 1 }
    coordinator.tick()
    coordinator.tick()
    settle(coordinator)
    let afterIdleTicks = pushes
    system.update("en5") { $0.isActive = true }
    coordinator.tick()
    settle(coordinator)
    XCTAssertEqual(pushes, afterIdleTicks + 1)
  }

  func testReadFailureIsReportedAndClears() {
    let system = FakeSystem([makeInterface("en5")])
    let coordinator = makeCoordinator(system)
    system.readFails = true
    coordinator.tick()
    settle(coordinator)
    XCTAssertFalse(snapshot(coordinator).warnings.isEmpty)
    system.readFails = false
    coordinator.tick()
    settle(coordinator)
    XCTAssertTrue(snapshot(coordinator).warnings.isEmpty)
  }
}

/// Holds every write until the test releases it.
private struct BlockingWriter: MACWriting {
  let system: FakeSystem
  let gate: DispatchSemaphore

  func write(_ target: MACAddress, to interface: InterfaceSnapshot, disconnectWiFi: Bool) -> MACWriteOutcome {
    gate.wait()
    return system.write(target, to: interface, disconnectWiFi: disconnectWiFi)
  }
}
