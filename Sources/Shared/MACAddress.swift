import Foundation
import Security

/// Fills a buffer with random bytes. Returns `false` when the source failed.
typealias RandomBytes = @Sendable (inout [UInt8]) -> Bool

let secureRandomBytes: RandomBytes = { buffer in
  let count = buffer.count
  return buffer.withUnsafeMutableBytes { raw in
    SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!) == errSecSuccess
  }
}

/// A strict 48-bit MAC address, always printed as lowercase `aa:bb:cc:dd:ee:ff`.
struct MACAddress: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
  let bytes: [UInt8]

  init?(bytes: [UInt8]) {
    guard bytes.count == 6 else { return nil }
    self.bytes = bytes
  }

  /// Accepts `aa:bb:cc:dd:ee:ff`, `aa-bb-cc-dd-ee-ff` or `aabbccddeeff`.
  init?(_ text: String) {
    let value = text.trimmingCharacters(in: .whitespaces).lowercased()
    let hex: String
    if value.count == 12 {
      hex = value
    } else if value.count == 17 {
      let separator = value[value.index(value.startIndex, offsetBy: 2)]
      guard separator == ":" || separator == "-" else { return nil }
      let groups = value.split(separator: separator, omittingEmptySubsequences: false)
      guard groups.count == 6, groups.allSatisfy({ $0.count == 2 }) else { return nil }
      hex = groups.joined()
    } else {
      return nil
    }
    guard hex.allSatisfy(\.isHexDigit) else { return nil }
    var parsed: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      parsed.append(byte)
      index = next
    }
    self.bytes = parsed
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let parsed = MACAddress(try container.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a 48-bit MAC address.")
    }
    self = parsed
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(stringValue)
  }

  var stringValue: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }
  var description: String { stringValue }

  var isUnicast: Bool { bytes[0] & 0x01 == 0 }
  /// Bit 1 of the first octet: set for addresses that were not assigned by a vendor.
  var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }
  var isAllZero: Bool { bytes.allSatisfy { $0 == 0 } }
  /// Unicast and non-zero. (Broadcast is multicast, so it is excluded too.)
  var isAssignable: Bool { isUnicast && !isAllZero }

  /// The vendor prefix, available only for a globally administered unicast address.
  var vendorOUI: [UInt8]? {
    guard isUnicast, !isLocallyAdministered else { return nil }
    return Array(bytes.prefix(3))
  }

  static func < (lhs: MACAddress, rhs: MACAddress) -> Bool {
    lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
  }

  /// A random locally administered unicast address (the default, private choice).
  static func randomLocal(
    excluding excluded: Set<MACAddress> = [],
    random: RandomBytes = secureRandomBytes
  ) throws -> MACAddress {
    try generate(excluding: excluded, random: random, count: 6) { bytes in
      var bytes = bytes
      bytes[0] = (bytes[0] & 0xfc) | 0x02
      return bytes
    }
  }

  /// Keeps a vendor OUI and randomizes the last three bytes. Less private, but
  /// some networks only accept addresses that look like real hardware.
  static func randomWithVendor(
    _ oui: [UInt8],
    excluding excluded: Set<MACAddress> = [],
    random: RandomBytes = secureRandomBytes
  ) throws -> MACAddress {
    guard oui.count == 3, oui[0] & 0x03 == 0 else {
      throw MACDancerError.invalidRequest("Vendor OUI must be a globally administered unicast prefix.")
    }
    return try generate(excluding: excluded, random: random, count: 3) { oui + $0 }
  }

  private static func generate(
    excluding excluded: Set<MACAddress>,
    random: RandomBytes,
    count: Int,
    shape: ([UInt8]) -> [UInt8]
  ) throws -> MACAddress {
    for _ in 0..<128 {
      var buffer = [UInt8](repeating: 0, count: count)
      guard random(&buffer) else { throw MACDancerError.addressGenerationFailed }
      guard let candidate = MACAddress(bytes: shape(buffer)),
            candidate.isAssignable,
            !excluded.contains(candidate) else { continue }
      return candidate
    }
    throw MACDancerError.addressGenerationFailed
  }
}
