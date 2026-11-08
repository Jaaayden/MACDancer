import Foundation

/// Accepts XPC connections from the signed GUI only.
final class DaemonListener: NSObject, NSXPCListenerDelegate {
  private let listener = NSXPCListener(machServiceName: MACDancerConstants.daemonIdentifier)
  private let coordinator: DaemonCoordinator

  init(coordinator: DaemonCoordinator) throws {
    guard let requirement = CodeSigningIdentity.requirement(identifier: MACDancerConstants.appIdentifier) else {
      throw MACDancerError.daemonUnavailable("Could not build the GUI code-signing requirement.")
    }
    self.coordinator = coordinator
    super.init()
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = self
  }

  func resume() { listener.resume() }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    let session = ClientSession(coordinator: coordinator, connection: connection)
    connection.exportedInterface = XPCInterfaces.daemon()
    connection.exportedObject = session
    connection.remoteObjectInterface = XPCInterfaces.client()
    connection.invalidationHandler = { session.close() }
    connection.interruptionHandler = { session.close() }
    connection.resume()
    return true
  }
}

/// One connected GUI. Pushed snapshots go back over the same connection.
private final class ClientSession: NSObject, MACDancerDaemonProtocol, @unchecked Sendable {
  private let coordinator: DaemonCoordinator
  private weak var connection: NSXPCConnection?
  private let lock = NSLock()
  private var subscriptionID: UUID?

  init(coordinator: DaemonCoordinator, connection: NSXPCConnection) {
    self.coordinator = coordinator
    self.connection = connection
  }

  func perform(_ payload: MDSecurePayload, reply: @escaping PayloadReply) {
    let request: DaemonRequest
    do {
      request = try payload.decode(DaemonRequest.self)
    } catch {
      return reply(nil, MACDancerError(error).nsError)
    }
    if request == .subscribe { subscribe() }
    coordinator.handle(request) { result in
      switch result {
      case let .success(snapshot):
        do { reply(try MDSecurePayload(snapshot), nil) }
        catch { reply(nil, MACDancerError.invalidRequest("Could not encode the snapshot.").nsError) }
      case let .failure(error):
        reply(nil, error.nsError)
      }
    }
  }

  private func subscribe() {
    lock.lock()
    defer { lock.unlock() }
    guard subscriptionID == nil else { return }
    subscriptionID = coordinator.addSubscriber { [weak self] snapshot in
      guard let self, let payload = try? MDSecurePayload(snapshot) else { return }
      let proxy = self.connection?.remoteObjectProxyWithErrorHandler { _ in } as? MACDancerClientProtocol
      proxy?.daemonDidUpdate(payload)
    }
  }

  func close() {
    lock.lock()
    let id = subscriptionID
    subscriptionID = nil
    lock.unlock()
    if let id { coordinator.removeSubscriber(id) }
  }
}
