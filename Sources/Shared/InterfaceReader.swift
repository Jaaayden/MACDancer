import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

protocol InterfaceReading: Sendable {
  /// Reads every network interface macOS knows about. Never changes anything.
  func interfaces() throws -> [InterfaceSnapshot]
}

/// Read-only system adapter built on getifaddrs, SystemConfiguration and CoreWLAN.
struct SystemInterfaceReader: InterfaceReading {
  func interfaces() throws -> [InterfaceSnapshot] {
    let now = Date()
    let links = try Self.readLinks()
    let defaultRoute = Self.defaultRouteInterfaces()
    let wifiClient = CWWiFiClient.shared()
    let wifiNames = Set(wifiClient.interfaceNames() ?? [])
    let systemInterfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []

    var result: [String: InterfaceSnapshot] = [:]
    for systemInterface in systemInterfaces {
      guard let name = SCNetworkInterfaceGetBSDName(systemInterface) as String?,
            result[name] == nil else { continue }
      let type = SCNetworkInterfaceGetInterfaceType(systemInterface) as String?
      let kind: InterfaceKind
      if wifiNames.contains(name) || type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
        kind = .wifi
      } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
        kind = .ethernet
      } else {
        kind = .other
      }
      let wifi = kind == .wifi ? wifiClient.interface(withName: name) : nil
      let hardwareMAC = (SCNetworkInterfaceGetHardwareAddressString(systemInterface) as String?)
        .flatMap(MACAddress.init)
        ?? wifi?.hardwareAddress().flatMap(MACAddress.init)
      let link = links[name]
      result[name] = InterfaceSnapshot(
        bsdName: name,
        displayName: (SCNetworkInterfaceGetLocalizedDisplayName(systemInterface) as String?) ?? name,
        kind: kind,
        currentMAC: link?.mac,
        hardwareMAC: hardwareMAC,
        isActive: link?.hasRoutableAddress ?? false,
        // SSID needs Location Services; the interface mode does not.
        isWiFiAssociated: wifi.map { $0.interfaceMode() != .none } ?? false,
        isDefaultRoute: defaultRoute.contains(name),
        observedAt: now
      )
    }
    return result.values.sorted { $0.bsdName < $1.bsdName }
  }

  private struct Link {
    var mac: MACAddress?
    var hasRoutableAddress = false
  }

  /// Link-layer addresses plus whether each interface has a usable IP.
  /// `IFF_RUNNING` is not used: idle Thunderbolt ports report it too.
  private static func readLinks() throws -> [String: Link] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else {
      throw MACDancerError.commandFailed("getifaddrs: \(String(cString: strerror(errno)))")
    }
    defer { freeifaddrs(head) }

    var links: [String: Link] = [:]
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let entry = pointer.pointee
      guard let address = entry.ifa_addr else { continue }
      let name = String(cString: entry.ifa_name)
      var link = links[name] ?? Link()
      switch Int32(address.pointee.sa_family) {
      case AF_LINK:
        address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
          guard dl.pointee.sdl_alen == 6 else { return }
          let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(dl.pointee.sdl_nlen)
          let base = UnsafeRawPointer(dl).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
          link.mac = MACAddress(bytes: Array(UnsafeBufferPointer(start: base, count: 6)))
        }
      case AF_INET:
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
          let host = UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
          // Skip 169.254.0.0/16 (self-assigned) and 0.0.0.0.
          if host != 0 && host >> 16 != 0xa9fe { link.hasRoutableAddress = true }
        }
      case AF_INET6:
        address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
          let bytes = withUnsafeBytes(of: sin6.pointee.sin6_addr) { Array($0) }
          // Skip fe80::/10 (link-local); every Ethernet port has one.
          let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
          if !isLinkLocal && !bytes.allSatisfy({ $0 == 0 }) { link.hasRoutableAddress = true }
        }
      default:
        break
      }
      links[name] = link
    }
    return links
  }

  private static func defaultRouteInterfaces() -> Set<String> {
    guard let store = SCDynamicStoreCreate(nil, "MACDancer.InterfaceReader" as CFString, nil, nil) else { return [] }
    let keys = [
      SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4),
      SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6),
    ]
    return Set(keys.compactMap { key in
      (SCDynamicStoreCopyValue(store, key) as? [String: Any])?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    })
  }
}
