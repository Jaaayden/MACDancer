import Foundation

/// XPC client for the privileged daemon.
///
/// Requests are never retried: replaying a MAC change could apply it twice.
/// Only the connection itself is re-established, with backoff.
@MainActor
final class DaemonClient: NSObject, DaemonClientProviding {
  var onSnapshot: ((DaemonSnapshot) -> Void)?
  var onConnectionChange: ((ConnectionState) -> Void)?

  /// Status requests are answered at once by the daemon.
  private let quickTimeout: TimeInterval = 8
  /// Writes may disconnect Wi-Fi, run ifconfig and wait for the read-back.
  private let writeTimeout: TimeInterval = 60
  private let heartbeatInterval: Duration = .seconds(20)

  private var connection: NSXPCConnection?
  private var wanted = false
  private var supervisor: Task<Void, Never>?
  private var retryDelay: TimeInterval = 1
  /// True between a successful subscribe and the next failure.
  private var subscribed = false
  private var state: ConnectionState = .idle {
    didSet { if state != oldValue { onConnectionChange?(state) } }
  }
  private lazy var receiver = SnapshotReceiver { [weak self] payload in
    Task { @MainActor in self?.receive(payload) }
  }

  func start() {
    guard !wanted else { return }
    wanted = true
    supervisor = Task { [weak self] in await self?.supervise() }
  }

  func stop() {
    wanted = false
    subscribed = false
    supervisor?.cancel()
    supervisor = nil
    connection?.invalidate()
    connection = nil
    state = .idle
  }

  func send(_ request: DaemonRequest) async throws -> DaemonSnapshot {
    let connection = try currentConnection()
    let payload = try MDSecurePayload(request)
    let timeout = request.mayWriteAddress ? writeTimeout : quickTimeout
    do {
      let snapshot = try await call(connection, payload, timeout: timeout)
      state = .connected
      return snapshot
    } catch let error as MACDancerError {
      if case let .incompatibleProtocol(_, actual) = error { state = .incompatible(daemonVersion: actual) }
      throw error
    }
  }

  // MARK: - Connection

  /// Keeps one subscribed connection alive while `wanted`.
  private func supervise() async {
    while wanted, !Task.isCancelled {
      do {
        let snapshot = try await send(.subscribe)
        retryDelay = 1
        subscribed = true
        onSnapshot?(snapshot)
        // Heartbeat. The daemon answers status requests even mid-write.
        while wanted, !Task.isCancelled {
          try await Task.sleep(for: heartbeatInterval)
          onSnapshot?(try await send(.snapshot))
        }
      } catch is CancellationError {
        return
      } catch {
        subscribed = false
        guard wanted else { return }
        let error = MACDancerError(error)
        if case .incompatibleProtocol = error {} else { state = .unreachable(error.localizedMessage) }
        drop()
        try? await Task.sleep(for: .seconds(retryDelay))
        retryDelay = min(retryDelay * 2, 30)
      }
    }
  }

  private func currentConnection() throws -> NSXPCConnection {
    if let connection { return connection }
    guard let requirement = CodeSigningIdentity.requirement(identifier: MACDancerConstants.daemonIdentifier) else {
      throw MACDancerError.daemonUnavailable("This build has no code signature to verify the background service with.")
    }
    state = .connecting
    let connection = NSXPCConnection(machServiceName: MACDancerConstants.daemonIdentifier, options: .privileged)
    connection.remoteObjectInterface = XPCInterfaces.daemon()
    connection.exportedInterface = XPCInterfaces.client()
    connection.exportedObject = receiver
    connection.setCodeSigningRequirement(requirement)
    // Either handler means the daemon went away (crash, restart, unregister).
    // The supervisor notices on its next request and reconnects.
    connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.connectionLost(connection) } }
    connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.connectionLost(connection) } }
    connection.resume()
    self.connection = connection
    return connection
  }

  private func connectionLost(_ lost: NSXPCConnection) {
    guard connection === lost else { return }
    drop()
    guard wanted else { return }
    state = .unreachable(L("daemon.connection_lost", "The connection to the background service was lost."))
    // A subscribed supervisor sleeps between heartbeats; wake it to
    // resubscribe now. A failing one is already backing off.
    guard subscribed else { return }
    subscribed = false
    supervisor?.cancel()
    supervisor = Task { [weak self] in await self?.supervise() }
  }

  private func drop() {
    connection?.invalidate()
    connection = nil
  }

  private func receive(_ payload: MDSecurePayload) {
    do {
      onSnapshot?(try payload.decode(DaemonSnapshot.self))
    } catch {
      if case let .incompatibleProtocol(_, actual) = MACDancerError(error) { state = .incompatible(daemonVersion: actual) }
    }
  }

  private nonisolated func call(
    _ connection: NSXPCConnection,
    _ payload: MDSecurePayload,
    timeout: TimeInterval
  ) async throws -> DaemonSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      let once = ResumeOnce(continuation)
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.failure(MACDancerError.timeout)) }
      let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        once.resume(.failure(MACDancerError.daemonUnavailable(error.localizedDescription)))
      } as? MACDancerDaemonProtocol
      guard let proxy else {
        return once.resume(.failure(MACDancerError.daemonUnavailable("No XPC proxy.")))
      }
      proxy.perform(payload) { reply, error in
        if let error { return once.resume(.failure(MACDancerError(error))) }
        guard let reply else { return once.resume(.failure(MACDancerError.daemonUnavailable("Empty reply."))) }
        once.resume(Result { try reply.decode(DaemonSnapshot.self) })
      }
    }
  }
}

/// Receives pushed snapshots on the XPC connection's queue.
private final class SnapshotReceiver: NSObject, MACDancerClientProtocol, @unchecked Sendable {
  private let handler: (MDSecurePayload) -> Void
  init(_ handler: @escaping (MDSecurePayload) -> Void) { self.handler = handler }
  func daemonDidUpdate(_ snapshot: MDSecurePayload) { handler(snapshot) }
}

/// A reply, a transport error and the timeout race; the first one wins.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<DaemonSnapshot, Error>?

  init(_ continuation: CheckedContinuation<DaemonSnapshot, Error>) { self.continuation = continuation }

  func resume(_ result: Result<DaemonSnapshot, Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<DaemonSnapshot, Error>? in
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(with: result)
  }
}
