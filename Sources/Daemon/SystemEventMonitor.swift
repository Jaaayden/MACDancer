import Foundation
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration

/// Reports sleep, wake and network-configuration changes. It never changes
/// network state; it only forwards small events to the coordinator.
///
/// The daemon keeps one monitor for its whole life, so there is no stop():
/// launchd tearing the process down releases every registration.
final class SystemEventMonitor {
  // `kIOMessage*` macros are not imported into Swift; values from <IOKit/IOMessage.h>.
  private static let canSystemSleep: UInt32 = 0xe000_0270
  private static let systemWillSleep: UInt32 = 0xe000_0280
  private static let systemHasPoweredOn: UInt32 = 0xe000_0300

  private let handler: (SystemEvent) -> Void
  private let queue = DispatchQueue(label: "local.macdancer.MACDancer.daemon.events")
  private var powerConnection: io_connect_t = 0
  private var notificationPort: IONotificationPortRef?
  private var notifier: io_object_t = 0
  private var dynamicStore: SCDynamicStore?
  private var pendingNetworkEvent: DispatchWorkItem?

  init(handler: @escaping (SystemEvent) -> Void) {
    self.handler = handler
  }

  func start() throws {
    // The monitor lives as long as the process, so an unretained pointer is safe.
    let context = Unmanaged.passUnretained(self).toOpaque()

    powerConnection = IORegisterForSystemPower(context, &notificationPort, { context, _, message, argument in
      guard let context else { return }
      Unmanaged<SystemEventMonitor>.fromOpaque(context).takeUnretainedValue().power(message, argument)
    }, &notifier)
    guard powerConnection != 0, let notificationPort else {
      throw MACDancerError.daemonUnavailable("Could not register for sleep and wake notifications.")
    }
    IONotificationPortSetDispatchQueue(notificationPort, queue)

    var storeContext = SCDynamicStoreContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
    guard let store = SCDynamicStoreCreate(nil, "MACDancer.SystemEventMonitor" as CFString, { _, _, info in
      guard let info else { return }
      Unmanaged<SystemEventMonitor>.fromOpaque(info).takeUnretainedValue().networkChanged()
    }, &storeContext) else {
      throw MACDancerError.daemonUnavailable("Could not observe network configuration.")
    }
    let state = kSCDynamicStoreDomainState
    let keys = [
      SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, state, kSCEntNetIPv4),
      SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, state, kSCEntNetIPv6),
    ] as CFArray
    let patterns = [
      SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, state, kSCCompAnyRegex, kSCEntNetLink),
      SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, state, kSCCompAnyRegex, kSCEntNetAirPort),
      SCDynamicStoreKeyCreateNetworkServiceEntity(nil, state, kSCCompAnyRegex, kSCEntNetIPv4),
      SCDynamicStoreKeyCreateNetworkServiceEntity(nil, state, kSCCompAnyRegex, kSCEntNetIPv6),
    ] as CFArray
    guard SCDynamicStoreSetNotificationKeys(store, keys, patterns),
          SCDynamicStoreSetDispatchQueue(store, queue) else {
      throw MACDancerError.daemonUnavailable("Could not observe network configuration.")
    }
    dynamicStore = store
  }

  private func power(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
    switch message {
    case Self.canSystemSleep:
      // Never veto sleep.
      IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
    case Self.systemWillSleep:
      handler(.willSleep)
      // Acknowledge at once; the coordinator only records intent here.
      IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
    case Self.systemHasPoweredOn:
      handler(.didWake)
    default:
      break
    }
  }

  /// A Wi-Fi rejoin or MAC change produces a burst of key changes; deliver one event.
  private func networkChanged() {
    pendingNetworkEvent?.cancel()
    let item = DispatchWorkItem { [handler] in handler(.networkChanged) }
    pendingNetworkEvent = item
    queue.asyncAfter(deadline: .now() + 1.5, execute: item)
  }
}
