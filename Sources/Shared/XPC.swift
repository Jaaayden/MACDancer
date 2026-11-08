import Foundation

/// A versioned JSON payload. App and daemon compile Shared into different
/// Swift modules, so every type in an XPC signature needs a fixed
/// Objective-C name; otherwise each side would see a different class.
@objc(MACDancerSecurePayload)
final class MDSecurePayload: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  let protocolVersion: Int
  let data: Data

  init(data: Data, protocolVersion: Int = MACDancerConstants.protocolVersion) {
    self.protocolVersion = protocolVersion
    self.data = data
  }

  convenience init<T: Encodable>(_ value: T) throws {
    try self.init(data: Self.encoder.encode(value))
  }

  required init?(coder: NSCoder) {
    let version = coder.decodeInteger(forKey: "protocolVersion")
    guard let data = coder.decodeObject(of: NSData.self, forKey: "data") as Data?,
          data.count <= MACDancerConstants.maximumPayloadSize else { return nil }
    protocolVersion = version
    self.data = data
  }

  func encode(with coder: NSCoder) {
    coder.encode(protocolVersion, forKey: "protocolVersion")
    coder.encode(data as NSData, forKey: "data")
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    guard protocolVersion == MACDancerConstants.protocolVersion else {
      throw MACDancerError.incompatibleProtocol(expected: MACDancerConstants.protocolVersion, actual: protocolVersion)
    }
    guard data.count <= MACDancerConstants.maximumPayloadSize else {
      throw MACDancerError.invalidRequest("Payload is too large.")
    }
    do {
      return try Self.decoder.decode(type, from: data)
    } catch {
      throw MACDancerError.invalidRequest("Malformed payload.")
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }()
}

typealias PayloadReply = (MDSecurePayload?, NSError?) -> Void

/// Exported by the daemon. A single entry point keeps both sides' interface
/// definitions trivially in sync.
@objc(MACDancerDaemonXPCProtocolV2)
protocol MACDancerDaemonProtocol {
  /// `request` decodes to `DaemonRequest`; the reply is a `DaemonSnapshot`.
  func perform(_ request: MDSecurePayload, reply: @escaping PayloadReply)
}

/// Exported by the app on the same connection, for pushed snapshots.
@objc(MACDancerClientXPCProtocolV2)
protocol MACDancerClientProtocol {
  func daemonDidUpdate(_ snapshot: MDSecurePayload)
}

enum XPCInterfaces {
  static func daemon() -> NSXPCInterface {
    let interface = NSXPCInterface(with: MACDancerDaemonProtocol.self)
    let classes = payloadClasses
    let selector = #selector(MACDancerDaemonProtocol.perform(_:reply:))
    interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: false)
    interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: true)
    return interface
  }

  static func client() -> NSXPCInterface {
    let interface = NSXPCInterface(with: MACDancerClientProtocol.self)
    interface.setClasses(
      payloadClasses,
      for: #selector(MACDancerClientProtocol.daemonDidUpdate(_:)),
      argumentIndex: 0,
      ofReply: false
    )
    return interface
  }

  // NSXPCInterface imports NSSet<Class> as Set<AnyHashable>; going through
  // NSSet keeps the Objective-C class object intact.
  private static var payloadClasses: Set<AnyHashable> {
    NSSet(object: MDSecurePayload.self) as! Set<AnyHashable>
  }
}
