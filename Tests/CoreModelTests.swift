import XCTest

final class MACAddressTests: XCTestCase {
  func testParsesCommonFormatsAndNormalizes() {
    XCTAssertEqual(MACAddress("AA:BB:CC:DD:EE:FF")?.stringValue, "aa:bb:cc:dd:ee:ff")
    XCTAssertEqual(MACAddress("aa-bb-cc-dd-ee-ff")?.stringValue, "aa:bb:cc:dd:ee:ff")
    XCTAssertEqual(MACAddress("aabbccddeeff")?.stringValue, "aa:bb:cc:dd:ee:ff")
    XCTAssertEqual(MACAddress(" 02:00:00:00:00:01 ")?.stringValue, "02:00:00:00:00:01")
  }

  func testRejectsMalformedInput() {
    for text in ["", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "aa:bb-cc:dd:ee:ff", "gg:bb:cc:dd:ee:ff", "a:bb:cc:dd:ee:fff", "aabbccddeef"] {
      XCTAssertNil(MACAddress(text), text)
    }
  }

  func testDecodingIsStrict() {
    XCTAssertThrowsError(try JSONDecoder().decode(MACAddress.self, from: Data(#""aa:bb""#.utf8)))
    XCTAssertEqual(try JSONDecoder().decode(MACAddress.self, from: Data(#""AA-BB-CC-DD-EE-FF""#.utf8)), mac("aa:bb:cc:dd:ee:ff"))
  }

  func testAddressClasses() {
    XCTAssertTrue(mac("02:00:00:00:00:01").isLocallyAdministered)
    XCTAssertFalse(mac("00:11:22:33:44:55").isLocallyAdministered)
    XCTAssertFalse(mac("01:00:5e:00:00:01").isAssignable, "multicast")
    XCTAssertFalse(mac("ff:ff:ff:ff:ff:ff").isAssignable, "broadcast")
    XCTAssertFalse(mac("00:00:00:00:00:00").isAssignable, "zero")
    XCTAssertEqual(mac("a0:b1:c2:01:02:03").vendorOUI, [0xa0, 0xb1, 0xc2])
    XCTAssertNil(mac("06:d4:88:01:02:03").vendorOUI)
  }

  func testRandomLocalIsAlwaysUnicastLAA() throws {
    for _ in 0..<5_000 {
      let address = try MACAddress.randomLocal()
      XCTAssertTrue(address.isUnicast && address.isLocallyAdministered && address.isAssignable)
    }
  }

  func testRandomLocalSkipsExcludedAddresses() throws {
    let random = ScriptedRandom([[0x00, 1, 2, 3, 4, 5], [0x00, 9, 9, 9, 9, 9]]).source
    let address = try MACAddress.randomLocal(excluding: [mac("02:01:02:03:04:05")], random: random)
    XCTAssertEqual(address, mac("02:09:09:09:09:09"))
  }

  func testRandomLocalFailsInsteadOfReusing() {
    let random = ScriptedRandom([[0x00, 1, 2, 3, 4, 5]]).source
    XCTAssertThrowsError(try MACAddress.randomLocal(excluding: [mac("02:01:02:03:04:05")], random: random)) {
      XCTAssertEqual($0 as? MACDancerError, .addressGenerationFailed)
    }
  }

  func testFailingRandomSourceIsReported() {
    XCTAssertThrowsError(try MACAddress.randomLocal(random: { _ in false }))
  }

  func testVendorModeKeepsOUI() throws {
    let address = try MACAddress.randomWithVendor([0xa0, 0xb1, 0xc2], random: ScriptedRandom([[7, 8, 9]]).source)
    XCTAssertEqual(address, mac("a0:b1:c2:07:08:09"))
    XCTAssertThrowsError(try MACAddress.randomWithVendor([0x02, 0, 0]))
    XCTAssertThrowsError(try MACAddress.randomWithVendor([0x01, 0, 0]))
    XCTAssertThrowsError(try MACAddress.randomWithVendor([0xf4, 0xd4]))
  }
}

final class HistoryTests: XCTestCase {
  private func entry(_ index: Int, at date: Date) -> HistoryEntry {
    HistoryEntry(
      address: MACAddress(bytes: [0x02, 0, 0, 0, 0, UInt8(index)])!,
      source: .generatedLocal, firstUsedAt: date, lastUsedAt: date, operation: .randomize
    )
  }

  func testIsCappedNewestFirstAndDeduplicated() {
    var ledger = HistoryLedger()
    let start = Date(timeIntervalSince1970: 1_000)
    for index in 0..<25 { ledger.record(entry(index, at: start.addingTimeInterval(Double(index)))) }
    XCTAssertEqual(ledger.entries.count, HistoryLedger.limit)
    XCTAssertEqual(ledger.entries.first?.address.bytes.last, 24)

    ledger.record(entry(10, at: start.addingTimeInterval(100)))
    XCTAssertEqual(ledger.entries.count, HistoryLedger.limit)
    XCTAssertEqual(ledger.entries.first?.address.bytes.last, 10)
    XCTAssertEqual(ledger.entries.first?.firstUsedAt, start.addingTimeInterval(10), "keeps the first use")
  }

  func testDecodingNormalizesOversizedInput() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let raw = (0..<30).map { entry($0 % 25, at: start.addingTimeInterval(Double($0))) }
    let ledger = try JSONDecoder().decode(HistoryLedger.self, from: JSONEncoder().encode(raw))
    XCTAssertEqual(ledger.entries.count, HistoryLedger.limit)
    XCTAssertEqual(Set(ledger.entries.map(\.address)).count, HistoryLedger.limit)
  }
}

final class SafetyTests: XCTestCase {
  func testManualRequiresConfirmationOnlyWhenInUse() {
    let idle = makeInterface("en5")
    XCTAssertEqual(SafetyPolicy.manual(idle, confirmedDisruption: false), .allowed)
    for busy in [
      makeInterface("en5", active: true),
      makeInterface("en5", defaultRoute: true),
      makeInterface("en0", kind: .wifi, wifiAssociated: true),
    ] {
      XCTAssertEqual(SafetyPolicy.manual(busy, confirmedDisruption: false), .denied(.confirmationRequired))
      XCTAssertEqual(SafetyPolicy.manual(busy, confirmedDisruption: true), .allowed)
    }
    XCTAssertEqual(SafetyPolicy.manual(makeInterface("bridge0", kind: .other), confirmedDisruption: true), .denied(.unsupportedInterface("bridge0")))
  }

  func testAutomaticWaitsForAnyInterfaceInUse() {
    XCTAssertEqual(SafetyPolicy.automatic(makeInterface("en5")), .allowed)
    XCTAssertEqual(SafetyPolicy.automatic(makeInterface("en5", defaultRoute: true)), .wait(.defaultRoute))
    XCTAssertEqual(SafetyPolicy.automatic(makeInterface("en0", kind: .wifi, wifiAssociated: true)), .wait(.wifiConnected))
    // An active Ethernet that is not the default route is still in use.
    XCTAssertEqual(SafetyPolicy.automatic(makeInterface("en5", active: true)), .wait(.inUse))
    var busy = makeInterface("en5")
    busy.isBusy = true
    XCTAssertEqual(SafetyPolicy.automatic(busy), .wait(.busy))
  }

  func testPlannerQueuesOnlyConfiguredTriggersForRandomPolicy() {
    var random = makeInterface("en5")
    random.policy = .random
    let manual = makeInterface("en6")
    let current = ["en5": random, "en6": manual]

    XCTAssertEqual(AutomationPlanner.interfacesToQueue(for: .afterWake, settings: .init(), current: current), [])
    XCTAssertEqual(AutomationPlanner.interfacesToQueue(for: .afterWake, settings: .init(rotateAfterWake: true), current: current), ["en5"])
    XCTAssertEqual(
      AutomationPlanner.interfacesToQueue(for: .beforeSleep, settings: .init(prepareRotationBeforeSleep: true), current: current),
      ["en5"]
    )

    var wasActive = random
    wasActive.isActive = true
    let settings = AutomationSettings(rotateWhenInterfaceBecomesInactive: true)
    XCTAssertEqual(
      AutomationPlanner.interfacesToQueue(for: .becameInactive, settings: settings, previous: ["en5": wasActive], current: current),
      ["en5"]
    )
    XCTAssertEqual(
      AutomationPlanner.interfacesToQueue(for: .becameInactive, settings: settings, previous: ["en5": random], current: current),
      [], "no transition"
    )
  }

  func testVirtualInterfacesAreRecognized() {
    XCTAssertTrue(makeInterface("en1", hardware: "3a:00:00:00:00:01").isLikelyVirtual, "Thunderbolt port")
    XCTAssertTrue(makeInterface("en9", hardware: nil).isLikelyVirtual)
    XCTAssertFalse(makeInterface("en7", hardware: "00:11:22:33:44:55").isLikelyVirtual)
    XCTAssertFalse(makeInterface("en0", kind: .wifi, hardware: "06:00:00:00:00:01").isLikelyVirtual)
  }
}

final class XPCPayloadTests: XCTestCase {
  func testRequestsRoundTrip() throws {
    let requests: [DaemonRequest] = [
      .snapshot, .subscribe,
      .setPolicy(interfaceID: "en0", policy: .random),
      .randomize(interfaceID: "en0", confirmedDisruption: true),
      .restore(interfaceID: "en0", target: .specified(mac("00:11:22:33:44:55"), confirmedGlobalAddress: true), confirmedDisruption: false),
      .restore(interfaceID: "en0", target: .history(mac("02:00:00:00:00:01")), confirmedDisruption: true),
      .removeHistory(interfaceID: "en0", address: nil),
      .cancelPending(interfaceID: nil),
      .updateAutomation(.init(rotateAfterWake: true, vendorCompatibility: true)),
    ]
    for request in requests {
      XCTAssertEqual(try MDSecurePayload(request).decode(DaemonRequest.self), request)
    }
  }

  func testPayloadSurvivesSecureCodingAndRejectsOtherVersions() throws {
    let payload = try MDSecurePayload(DaemonRequest.snapshot)
    let archived = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: true)
    let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: MDSecurePayload.self, from: archived))
    XCTAssertEqual(try decoded.decode(DaemonRequest.self), .snapshot)

    let old = MDSecurePayload(data: payload.data, protocolVersion: 1)
    XCTAssertThrowsError(try old.decode(DaemonRequest.self)) {
      XCTAssertEqual($0 as? MACDancerError, .incompatibleProtocol(expected: MACDancerConstants.protocolVersion, actual: 1))
    }
  }

  func testErrorsSurviveNSErrorBridging() {
    let errors: [MACDancerError] = [
      .confirmationRequired,
      .readbackMismatch(expected: mac("02:00:00:00:00:01"), observed: nil),
      .commandFailed("Operation not permitted"),
    ]
    for error in errors {
      let bridged = error.nsError
      XCTAssertEqual(bridged.domain, MACDancerConstants.errorDomain)
      XCTAssertEqual(MACDancerError(bridged), error)
    }
    XCTAssertEqual(MACDancerError(NSError(domain: "other", code: 1)), .daemonUnavailable(NSError(domain: "other", code: 1).localizedDescription))
  }

  func testRuntimeNamesAreStableAcrossModules() {
    XCTAssertEqual(NSStringFromClass(MDSecurePayload.self), "MACDancerSecurePayload")
    XCTAssertEqual(NSStringFromProtocol(MACDancerDaemonProtocol.self), "MACDancerDaemonXPCProtocolV2")
    XCTAssertEqual(NSStringFromProtocol(MACDancerClientProtocol.self), "MACDancerClientXPCProtocolV2")
  }
}
