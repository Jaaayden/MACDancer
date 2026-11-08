import XCTest

final class ConfigurationStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MACDancerStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var fileURL: URL { directory.appendingPathComponent("configuration.json") }

  func testMissingFileGivesDefaultsWithoutCreatingAnything() {
    let loaded = ConfigurationStore(fileURL: fileURL).load()
    XCTAssertEqual(loaded.document, ConfigurationDocument())
    XCTAssertNil(loaded.warning)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testRoundTripsWithPrivatePermissions() throws {
    var document = ConfigurationDocument()
    document.policies["en0|a0:b1:c2:00:00:01"] = .specified(mac("02:00:00:00:00:01"))
    document.pendingRotations["en0|a0:b1:c2:00:00:01"] = PendingRotation(trigger: .afterWake, queuedAt: Date(timeIntervalSince1970: 5))
    document.automation.rotateAfterWake = true
    try ConfigurationStore(fileURL: fileURL).save(document)

    XCTAssertEqual(ConfigurationStore(fileURL: fileURL).load().document, document)
    let fileMode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    XCTAssertEqual(fileMode, 0o600)
    XCTAssertEqual(directoryMode, 0o700)
  }

  func testLoadsFilesWrittenByThePreviousVersion() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = """
    {"schemaVersion":1,"configuration":{
      "policies":{"en0|a0:b1:c2:00:00:01":{"kind":"random"}},
      "histories":{"en0|a0:b1:c2:00:00:01":[{"address":"02:00:00:00:00:01","source":"generatedLocal",
        "firstUsedAt":700000000,"lastUsedAt":700000000,"operation":"randomize"}]},
      "pendingOperations":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","interfaceID":"en0","kind":"randomize",
        "state":"pending","startedAt":700000000}],
      "automation":{"rotateAfterWake":true}
    }}
    """
    try Data(legacy.utf8).write(to: fileURL)
    let loaded = ConfigurationStore(fileURL: fileURL).load()
    XCTAssertNil(loaded.warning)
    XCTAssertEqual(loaded.document.policies["en0|a0:b1:c2:00:00:01"], .random)
    XCTAssertEqual(loaded.document.histories["en0|a0:b1:c2:00:00:01"]?.entries.count, 1)
    XCTAssertTrue(loaded.document.automation.rotateAfterWake)
    XCTAssertFalse(loaded.document.automation.vendorCompatibility)
  }

  func testCorruptFileIsMovedAsideInsteadOfLockingTheDaemon() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: fileURL)
    let loaded = ConfigurationStore(fileURL: fileURL).load()
    XCTAssertEqual(loaded.document, ConfigurationDocument())
    XCTAssertNotNil(loaded.warning)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(leftovers.contains { $0.hasPrefix("configuration.json.invalid-") })
    XCTAssertNoThrow(try ConfigurationStore(fileURL: fileURL).save(ConfigurationDocument()))
  }

  func testSymlinkIsNeitherFollowedOnReadNorWrittenThrough() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let victim = directory.appendingPathComponent("victim.txt")
    try Data("keep".utf8).write(to: victim)
    try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: victim)

    let store = ConfigurationStore(fileURL: fileURL)
    XCTAssertNotNil(store.load().warning)
    try store.save(ConfigurationDocument())
    XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep")
    let type = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType
    XCTAssertEqual(type, .typeRegular)
  }
}

final class MACWriterTests: XCTestCase {
  private let target = mac("02:aa:bb:cc:dd:ee")

  private func writer(_ system: FakeReaderSystem, runner: RecordingRunner, wifi: FakeWiFi = FakeWiFi()) -> MACWriter {
    MACWriter(runner: runner, wifi: wifi, reader: system, sleep: { _ in })
  }

  func testSucceedsOnlyAfterReadback() {
    let system = FakeReaderSystem(makeInterface("en5"))
    let runner = RecordingRunner { arguments in system.current = MACAddress(arguments[2]) }
    let outcome = writer(system, runner: runner).write(target, to: system.interface, disconnectWiFi: false)
    XCTAssertTrue(outcome.succeeded)
    XCTAssertEqual(outcome.observed, target)
    XCTAssertEqual(runner.calls, [["en5", "ether", "02:aa:bb:cc:dd:ee"]])
  }

  func testDriverThatIgnoresTheChangeIsAFailure() {
    let system = FakeReaderSystem(makeInterface("en5"))
    let outcome = writer(system, runner: RecordingRunner()).write(target, to: system.interface, disconnectWiFi: false)
    XCTAssertEqual(outcome.error, .readbackMismatch(expected: target, observed: mac("00:11:22:33:44:55")))
  }

  func testCommandFailureIsReported() {
    let system = FakeReaderSystem(makeInterface("en5"))
    let runner = RecordingRunner(exitCode: 1, error: "ioctl (SIOCAIFADDR): Operation not permitted")
    let outcome = writer(system, runner: runner).write(target, to: system.interface, disconnectWiFi: false)
    XCTAssertEqual(outcome.error, .commandFailed("ioctl (SIOCAIFADDR): Operation not permitted"))
  }

  func testConnectedWiFiIsLeftAloneWithoutPermission() {
    let system = FakeReaderSystem(makeInterface("en0", kind: .wifi, wifiAssociated: true))
    let wifi = FakeWiFi(associated: true)
    let runner = RecordingRunner()
    let outcome = writer(system, runner: runner, wifi: wifi).write(target, to: system.interface, disconnectWiFi: false)
    XCTAssertEqual(outcome.error, .confirmationRequired)
    XCTAssertTrue(runner.calls.isEmpty)
    XCTAssertEqual(wifi.leaveCount, 0)
  }

  func testConnectedWiFiIsDisconnectedBeforeTheWrite() {
    let system = FakeReaderSystem(makeInterface("en0", kind: .wifi, wifiAssociated: true))
    let wifi = FakeWiFi(associated: true)
    let runner = RecordingRunner { arguments in
      XCTAssertFalse(wifi.associated, "written only after leaving the network")
      system.current = MACAddress(arguments[2])
    }
    let outcome = writer(system, runner: runner, wifi: wifi).write(target, to: system.interface, disconnectWiFi: true)
    XCTAssertTrue(outcome.succeeded)
    XCTAssertTrue(outcome.disconnectedWiFi)
    XCTAssertEqual(wifi.leaveCount, 1)
  }

  func testWiFiThatWillNotDisconnectIsNotWritten() {
    let system = FakeReaderSystem(makeInterface("en0", kind: .wifi, wifiAssociated: true))
    let wifi = FakeWiFi(associated: true, staysAssociated: true)
    let runner = RecordingRunner()
    let outcome = writer(system, runner: runner, wifi: wifi).write(target, to: system.interface, disconnectWiFi: true)
    XCTAssertEqual(outcome.error, .wifiDisconnectFailed)
    XCTAssertTrue(runner.calls.isEmpty)
  }
}

private final class FakeReaderSystem: InterfaceReading, @unchecked Sendable {
  let interface: InterfaceSnapshot
  var current: MACAddress?
  init(_ interface: InterfaceSnapshot) {
    self.interface = interface
    current = interface.currentMAC
  }
  func interfaces() throws -> [InterfaceSnapshot] {
    var copy = interface
    copy.currentMAC = current
    return [copy]
  }
}

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
  private(set) var calls: [[String]] = []
  let exitCode: Int32
  let error: String
  let effect: ([String]) -> Void

  init(exitCode: Int32 = 0, error: String = "", effect: @escaping ([String]) -> Void = { _ in }) {
    self.exitCode = exitCode
    self.error = error
    self.effect = effect
  }

  func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
    calls.append(arguments)
    if exitCode == 0 { effect(arguments) }
    return CommandResult(exitCode: exitCode, output: "", error: error)
  }
}

private final class FakeWiFi: WiFiControlling, @unchecked Sendable {
  var associated: Bool
  let staysAssociated: Bool
  private(set) var leaveCount = 0

  init(associated: Bool = false, staysAssociated: Bool = false) {
    self.associated = associated
    self.staysAssociated = staysAssociated
  }

  func isAssociated(_ interfaceName: String) -> Bool { associated }

  func leaveNetwork(_ interfaceName: String) {
    leaveCount += 1
    if !staysAssociated { associated = false }
  }
}
