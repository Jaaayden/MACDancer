import Foundation
import XCTest

// Fakes for every system boundary. Nothing here can touch a real interface.

func mac(_ text: String) -> MACAddress { MACAddress(text)! }

func makeInterface(
  _ name: String,
  kind: InterfaceKind = .ethernet,
  current: String? = nil,
  hardware: String? = "00:11:22:33:44:55",
  active: Bool = false,
  wifiAssociated: Bool = false,
  defaultRoute: Bool = false,
  observedAt: Date = Date()
) -> InterfaceSnapshot {
  InterfaceSnapshot(
    bsdName: name,
    displayName: name.uppercased(),
    kind: kind,
    currentMAC: (current ?? hardware).flatMap(MACAddress.init),
    hardwareMAC: hardware.flatMap(MACAddress.init),
    isActive: active,
    isWiFiAssociated: wifiAssociated,
    isDefaultRoute: defaultRoute,
    observedAt: observedAt
  )
}

/// A deterministic byte source: returns the queued buffers in order, then repeats the last.
final class ScriptedRandom: @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [[UInt8]]
  init(_ buffers: [[UInt8]]) { self.buffers = buffers }

  var source: RandomBytes {
    { [self] buffer in
      lock.withLock {
        let next = buffers.count > 1 ? buffers.removeFirst() : buffers[0]
        for index in buffer.indices { buffer[index] = next[index % next.count] }
      }
      return true
    }
  }
}

/// Holds the fake system: interface facts change when the fake writer applies an address.
final class FakeSystem: InterfaceReading, MACWriting, @unchecked Sendable {
  private let lock = NSLock()
  private var state: [String: InterfaceSnapshot]
  private(set) var writes: [(String, MACAddress, Bool)] = []
  var nextWriteError: MACDancerError?
  var readFails = false
  var rejoinFails = false
  var replaceOnRejoin: MACAddress?

  init(_ interfaces: [InterfaceSnapshot]) {
    state = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.id, $0) })
  }

  func interfaces() throws -> [InterfaceSnapshot] {
    try lock.withLock {
      if readFails { throw MACDancerError.commandFailed("read failed") }
      return state.values.sorted { $0.bsdName < $1.bsdName }
    }
  }

  func update(_ name: String, _ change: (inout InterfaceSnapshot) -> Void) {
    lock.withLock { change(&state[name]!) }
  }

  func write(_ target: MACAddress, to interface: InterfaceSnapshot, disconnectWiFi: Bool) -> MACWriteOutcome {
    lock.withLock {
      writes.append((interface.bsdName, target, disconnectWiFi))
      if let error = nextWriteError {
        nextWriteError = nil
        return MACWriteOutcome(observed: state[interface.bsdName]?.currentMAC, error: error)
      }
      let disconnected = state[interface.bsdName]?.isWiFiAssociated == true
      state[interface.bsdName]?.currentMAC = target
      guard disconnected else { return MACWriteOutcome(observed: target, error: nil) }
      // Like the real writer: leave, write, rejoin.
      state[interface.bsdName]?.isWiFiAssociated = !rejoinFails
      if let replacement = replaceOnRejoin, !rejoinFails { state[interface.bsdName]?.currentMAC = replacement }
      return MACWriteOutcome(
        observed: target, error: nil, disconnectedWiFi: true,
        rejoinedWiFi: !rejoinFails, replacedOnRejoin: rejoinFails ? nil : replaceOnRejoin
      )
    }
  }

  var writeCount: Int { lock.withLock { writes.count } }
}

final class MemoryStore: ConfigurationStoring {
  var document = ConfigurationDocument()
  var saves = 0
  var failSaves = false
  var loadWarning: String?

  func load() -> (document: ConfigurationDocument, warning: String?) { (document, loadWarning) }

  func save(_ document: ConfigurationDocument) throws {
    if failSaves { throw MACDancerError.persistence("disk full") }
    self.document = document
    saves += 1
  }

  private(set) var erased = false
  func erase() throws {
    document = ConfigurationDocument()
    erased = true
  }
}

final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool
  init(_ value: Bool = false) { stored = value }
  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

extension XCTestCase {
  /// Builds a coordinator whose MAC writes run synchronously on a private queue.
  func makeCoordinator(
    _ system: FakeSystem,
    store: MemoryStore = MemoryStore(),
    legacy: Flag = Flag(),
    random: @escaping RandomBytes = ScriptedRandom([[0x10, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]]).source
  ) -> DaemonCoordinator {
    DaemonCoordinator(environment: .init(
      reader: system,
      writer: system,
      store: store,
      legacyServiceDetected: { legacy.value },
      random: random,
      workQueue: DispatchQueue(label: "test.work"),
      wifiFollowUpDelay: 0.05,
      wakeSettleDelay: 0.05
    ))
  }

  func send(
    _ coordinator: DaemonCoordinator,
    _ request: DaemonRequest,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Result<DaemonSnapshot, MACDancerError> {
    let done = expectation(description: "reply")
    var result: Result<DaemonSnapshot, MACDancerError>!
    coordinator.handle(request) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return result
  }

  /// Waits until all queued coordinator work (including started writes) has run.
  func settle(_ coordinator: DaemonCoordinator, rounds: Int = 3) {
    for _ in 0..<rounds {
      coordinator.sync {}
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  func snapshot(_ coordinator: DaemonCoordinator) -> DaemonSnapshot {
    try! send(coordinator, .snapshot).get()
  }
}
