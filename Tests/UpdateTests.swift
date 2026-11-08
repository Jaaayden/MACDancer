import XCTest

final class UpdateTests: XCTestCase {
  private func release(
    tag: String, draft: Bool = false, prerelease: Bool = false, assets: [(String, String)]
  ) throws -> GitHubRelease {
    let assetJSON = assets.map { name, url in
      #"{"name":"\#(name)","browser_download_url":"\#(url)","size":1234}"#
    }.joined(separator: ",")
    let json = """
    {"tag_name":"\(tag)","name":"MACDancer \(tag)","body":"Notes","html_url":"https://github.com/Jaaayden/MACDancer/releases/tag/\(tag)",
     "draft":\(draft),"prerelease":\(prerelease),"assets":[\(assetJSON)]}
    """
    return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
  }

  func testVersionsCompareNumerically() {
    XCTAssertLessThan(AppVersion("1.9.0")!, AppVersion("1.10.0")!)
    XCTAssertLessThan(AppVersion("v2.0")!, AppVersion("2.0.1")!)
    XCTAssertEqual(AppVersion("2.0")!, AppVersion("v2.0.0")!)
    XCTAssertEqual(AppVersion("v2.1.3")?.description, "2.1.3")
    for bad in ["", "2.x", "1..2", "-1.0", "1.2.3.4.5"] { XCTAssertNil(AppVersion(bad), bad) }
  }

  func testOffersOnlyNewerFinalReleasesWithAnArchive() throws {
    let url = "https://github.com/Jaaayden/MACDancer/releases/download/v2.1.0/MACDancer-2.1.0.zip"
    let newer = try release(tag: "v2.1.0", assets: [("MACDancer-2.1.0.zip", url), ("notes.txt", "https://example.com/n")])
    let update = try XCTUnwrap(UpdatePlanner.update(from: newer, current: "2.0.0"))
    XCTAssertEqual(update.version, "2.1.0")
    XCTAssertEqual(update.downloadURL.absoluteString, url)
    XCTAssertEqual(update.notes, "Notes")

    XCTAssertNil(UpdatePlanner.update(from: newer, current: "2.1.0"), "same version")
    XCTAssertNil(UpdatePlanner.update(from: newer, current: "3.0.0"), "older release")
    XCTAssertNil(UpdatePlanner.update(from: try release(tag: "v2.1.0", draft: true, assets: [("MACDancer-2.1.0.zip", url)]), current: "2.0.0"))
    XCTAssertNil(UpdatePlanner.update(from: try release(tag: "v2.1.0", prerelease: true, assets: [("MACDancer-2.1.0.zip", url)]), current: "2.0.0"))
    XCTAssertNil(UpdatePlanner.update(from: try release(tag: "v2.1.0", assets: []), current: "2.0.0"), "no archive")
    XCTAssertNil(
      UpdatePlanner.update(from: try release(tag: "v2.1.0", assets: [("MACDancer-2.1.0.zip", "http://example.com/a.zip")]), current: "2.0.0"),
      "plain HTTP is refused"
    )
  }

  func testDailyCheckSchedule() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertTrue(UpdatePlanner.isCheckDue(lastCheck: nil, now: now))
    XCTAssertFalse(UpdatePlanner.isCheckDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
    XCTAssertTrue(UpdatePlanner.isCheckDue(lastCheck: now.addingTimeInterval(-90_000), now: now))
    XCTAssertTrue(UpdatePlanner.isCheckDue(lastCheck: now.addingTimeInterval(3_600), now: now), "clock moved backwards")
  }

  func testUpdatesMustComeFromTheSameTeam() {
    let requirement = UpdatePlanner.codeRequirement(teamIdentifier: "ABCDE12345")
    XCTAssertTrue(requirement.contains(#"identifier "local.macdancer.MACDancer""#))
    XCTAssertTrue(requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
  }

  func testDaemonRestartWaitsForRunningWrites() {
    let system = FakeSystem([makeInterface("en5")])
    let gate = DispatchSemaphore(value: 0)
    let coordinator = DaemonCoordinator(environment: .init(
      reader: system, writer: GatedWriter(system: system, gate: gate), store: MemoryStore(),
      legacyServiceDetected: { false }
    ))
    var ranWhileIdle = false
    coordinator.whenIdle { ranWhileIdle = true }
    XCTAssertTrue(ranWhileIdle)

    let done = expectation(description: "write")
    coordinator.handle(.randomize(interfaceID: "en5", confirmedDisruption: false)) { _ in done.fulfill() }
    coordinator.sync {}
    var ranWhileBusy = false
    coordinator.whenIdle { ranWhileBusy = true }
    XCTAssertFalse(ranWhileBusy)
    gate.signal()
    wait(for: [done], timeout: 5)
  }
}

private struct GatedWriter: MACWriting {
  let system: FakeSystem
  let gate: DispatchSemaphore
  func write(_ target: MACAddress, to interface: InterfaceSnapshot, disconnectWiFi: Bool) -> MACWriteOutcome {
    gate.wait()
    return system.write(target, to: interface, disconnectWiFi: disconnectWiFi)
  }
}
