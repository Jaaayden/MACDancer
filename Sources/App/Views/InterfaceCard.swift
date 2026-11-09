import SwiftUI

/// What a card asks the window to do. The window owns confirmations and sheets.
enum ChangeRequest: Identifiable {
  case randomize(InterfaceSnapshot)
  case restore(InterfaceSnapshot, RestoreTarget)

  var interface: InterfaceSnapshot {
    switch self {
    case let .randomize(interface), let .restore(interface, _): interface
    }
  }

  var id: String { interface.id }

  /// Changing an interface that is in use interrupts it, so it needs a yes first.
  var needsConfirmation: Bool {
    switch self {
    case let .randomize(interface):
      return interface.isInUse
    case let .restore(interface, target):
      let address: MACAddress?
      switch target {
      case .systemManaged: return false
      case .hardware: address = interface.hardwareMAC
      case let .history(entry), let .specified(entry, _): address = entry
      }
      return interface.isInUse && address != interface.currentMAC
    }
  }
}

struct InterfaceActions {
  var perform: (ChangeRequest) -> Void = { _ in }
  var enterAddress: (InterfaceSnapshot) -> Void = { _ in }
}

private struct InterfaceActionsKey: EnvironmentKey {
  static let defaultValue = InterfaceActions()
}

extension EnvironmentValues {
  var interfaceActions: InterfaceActions {
    get { self[InterfaceActionsKey.self] }
    set { self[InterfaceActionsKey.self] = newValue }
  }
}

struct InterfaceCard: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.interfaceActions) private var actions
  let interface: InterfaceSnapshot

  @State private var showsHistory = false
  @State private var shuffleTaps = 0

  private var busy: Bool { model.isBusy(interface) }
  private var blockedReason: String? { model.blockedReason(for: interface) }
  private var managed: Bool { interface.policy != .systemManaged }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      VStack(alignment: .leading, spacing: 10) {
        ByteStrip(address: interface.currentMAC, reference: interface.hardwareMAC, dancing: busy)
        caption
      }
      if hasMessages { messages }
      if interface.kind.isSupported {
        Divider().opacity(0.6)
        actionsRow
      }
    }
    .card(emphasized: busy)
    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: busy)
    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: interface.notice)
    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: interface.pendingRotation)
    .contextMenu {
      Button(L("interface.action.copy", "Copy current MAC")) { copy(interface.currentMAC) }
        .disabled(interface.currentMAC == nil)
      Button(L("interface.action.copy_hardware", "Copy hardware MAC")) { copy(interface.hardwareMAC) }
        .disabled(interface.hardwareMAC == nil)
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      IconTile(systemImage: interfaceSymbol(interface.kind), active: interface.isInUse)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(interface.displayName).font(.title3.weight(.semibold))
          Text(interface.bsdName)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        Text(connectionText).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      HStack(spacing: 6) {
        if interface.isDefaultRoute {
          Tag(title: L("interface.default_route", "Default route"), systemImage: "arrow.triangle.branch", tint: .secondary)
        }
        if case .specified = interface.policy {
          Tag(title: L("interface.tag.fixed", "Fixed address"), systemImage: "pin.fill", tint: Brand.indigo)
        }
      }
    }
  }

  private var connectionText: String {
    if interface.isWiFiAssociated { return L("interface.state.wifi_connected", "Connected to Wi-Fi") }
    if interface.isActive { return L("interface.state.in_use", "Connected") }
    if interface.kind == .wifi { return L("interface.state.wifi_idle", "Not on a network") }
    return L("interface.state.idle", "Not connected")
  }

  // MARK: Caption under the address

  @ViewBuilder
  private var caption: some View {
    HStack(spacing: 10) {
      if interface.usesHardwareMAC {
        Label(L("interface.caption.factory_in_use", "Factory address — networks can recognize this Mac"), systemImage: "eye")
          .foregroundStyle(.orange)
      } else if let hardware = interface.hardwareMAC {
        Label(L("interface.caption.factory", "Factory %@", hardware.stringValue), systemImage: "cpu")
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let operation = interface.lastOperation, operation.state == .succeeded, !busy, let finished = operation.finishedAt {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
          Label("\(operationText(operation.kind)) \(relativeText(finished))", systemImage: "checkmark.circle.fill")
            .foregroundStyle(Brand.mintInk)
        }
        .transition(.opacity)
      }
    }
    .font(.caption)
    .labelStyle(CompactLabelStyle())
  }

  // MARK: Messages

  private var hasMessages: Bool {
    busy || interface.notice != nil || interface.pendingRotation != nil
      || (interface.lastOperation?.state == .failed && interface.lastOperation?.error != nil)
  }

  @ViewBuilder
  private var messages: some View {
    VStack(alignment: .leading, spacing: 8) {
      if busy {
        InlineMessage(
          text: interface.kind == .wifi && (interface.isWiFiAssociated || interface.lastOperation?.disconnectedWiFi == true)
            ? L("interface.working_wifi.v2", "Disconnecting Wi-Fi and changing the address…")
            : L("interface.working", "Changing the address…"),
          systemImage: "waveform",
          tint: Brand.indigo
        ) {
          ProgressView().controlSize(.small)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let notice = interface.notice {
        InlineMessage(text: noticeText(notice), systemImage: "exclamationmark.triangle.fill", tint: .orange) {
          Button(L("notice.open_wifi", "Wi-Fi Settings")) { openNetworkSettings() }
            .buttonStyle(.link)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let operation = interface.lastOperation, operation.state == .failed, let error = operation.error, !busy {
        InlineMessage(
          text: "\(operationText(operation.kind)): \(error.localizedMessage)",
          systemImage: "xmark.octagon.fill",
          tint: .red
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let pending = interface.pendingRotation {
        InlineMessage(
          text: pending.waitingReason.map { "\(triggerText(pending.trigger)) — \(waitReasonText($0))" } ?? triggerText(pending.trigger),
          systemImage: "clock.arrow.circlepath",
          tint: Brand.indigo
        ) {
          Button(L("pending.cancel", "Cancel")) { model.cancelPending(interface) }
            .buttonStyle(.link)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
  }

  // MARK: Actions

  private var actionsRow: some View {
    HStack(spacing: 8) {
      Button {
        shuffleTaps += 1
        actions.perform(.randomize(interface))
      } label: {
        Label(L("interface.action.shuffle", "Shuffle"), systemImage: "shuffle")
          .symbolEffect(.bounce, value: shuffleTaps)
      }
      .buttonStyle(GradientButtonStyle())
      .disabled(blockedReason != nil)
      .help(blockedReason ?? L("interface.action.shuffle_help", "Give this adapter a new random address"))

      restoreMenu

      Button { showsHistory.toggle() } label: {
        Label(L("history.button", "History"), systemImage: "clock")
      }
      .buttonStyle(SoftButtonStyle())
      .disabled(interface.history.entries.isEmpty)
      .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
        HistoryPopover(interfaceID: interface.id)
          .environmentObject(model)
      }

      Spacer(minLength: 12)

      Toggle(isOn: Binding(
        get: { interface.policy == .random },
        set: { model.setPolicy(interface, $0 ? .random : .systemManaged) }
      )) {
        Text(L("interface.auto_rotate", "Auto-rotate")).font(.callout)
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .disabled(!model.isReady || busy || (model.legacyServiceDetected && interface.policy != .random))
      .help(L("interface.auto_rotate_help", "Give this adapter a new address automatically, when it is safe, on the occasions chosen in Settings › Rotation."))
    }
  }

  private var restoreMenu: some View {
    Menu {
      Button {
        actions.perform(.restore(interface, .hardware))
      } label: {
        Label(L("restore.menu.hardware", "Factory Address"), systemImage: "cpu")
      }
      .disabled(interface.hardwareMAC == nil || interface.usesHardwareMAC)

      Button {
        actions.enterAddress(interface)
      } label: {
        Label(L("restore.menu.enter", "Enter an Address…"), systemImage: "keyboard")
      }

      Divider()

      Button {
        actions.perform(.restore(interface, .systemManaged))
      } label: {
        Label(L("restore.menu.handoff", "Stop Managing This Adapter"), systemImage: "hand.raised")
      }
      .disabled(!managed && interface.pendingRotation == nil)
    } label: {
      Label(L("restore.menu.title", "Restore"), systemImage: "arrow.uturn.backward")
    }
    .menuStyle(.button)
    .buttonStyle(SoftButtonStyle())
    .menuIndicator(.visible)
    .fixedSize()
    .disabled(!model.isReady || busy)
  }

  private func copy(_ address: MACAddress?) {
    if let address { copyToPasteboard(address.stringValue) }
  }
}

/// Icon and title close together, for captions.
struct CompactLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon
      configuration.title
    }
  }
}
