import SwiftUI

struct InterfacesView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Page(
      title: L("interfaces.title", "Interfaces"),
      subtitle: L("interfaces.subtitle", "Current values are read directly from macOS. Changing a MAC is always an explicit action.")
    ) {
      HStack {
        Toggle(L("interfaces.show_all", "Show Thunderbolt, bridge and virtual interfaces"), isOn: $model.showAllInterfaces)
          .toggleStyle(.checkbox)
        Spacer()
        if !model.showAllInterfaces && model.hiddenInterfaceCount > 0 {
          Text(L("interfaces.hidden_count", "%d hidden", model.hiddenInterfaceCount))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if model.visibleInterfaces.isEmpty {
        ContentUnavailableView(
          L("interfaces.empty.title", "No interfaces to show"),
          systemImage: "network.slash",
          description: Text(L("interfaces.empty.detail", "MACDancer lists the Wi-Fi and Ethernet adapters macOS reports."))
        )
      } else {
        ForEach(model.visibleInterfaces) { interface in
          InterfaceCard(interface: interface, compact: false)
        }
      }
    }
  }
}

struct InterfaceCard: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.interfaceActions) private var actions
  let interface: InterfaceSnapshot
  let compact: Bool
  @State private var confirmsClearHistory = false

  private var blockedReason: String? { model.blockedReason(for: interface) }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        header
        addresses
        status
        if !compact { history }
        Divider()
        buttons
      }
      .padding(4)
    }
    .contextMenu {
      Button(L("interface.action.copy", "Copy current MAC")) { copy(interface.currentMAC) }
        .disabled(interface.currentMAC == nil)
      Button(L("interface.action.copy_hardware", "Copy hardware MAC")) { copy(interface.hardwareMAC) }
        .disabled(interface.hardwareMAC == nil)
    }
    .alert(L("history.clear.confirmation.title", "Clear this interface’s MAC history?"), isPresented: $confirmsClearHistory) {
      Button(L("history.clear.action", "Clear History"), role: .destructive) { model.removeHistory(interface, address: nil) }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: {
      Text(L("history.clear.confirmation.message", "This removes saved MAC choices for this interface. It does not change the current MAC address or policy."))
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(interface.kind.isSupported ? Color.accentColor : .secondary)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(interface.displayName).font(.headline)
          Text(interface.bsdName)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        Text(policyText(interface.policy)).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 6) {
        if interface.isDefaultRoute {
          StatusPill(title: L("interface.default_route", "Default route"), systemImage: "arrow.triangle.branch", tint: .orange)
        }
        if interface.isWiFiAssociated {
          StatusPill(title: L("interface.wifi_connected", "Connected"), systemImage: "wifi", tint: .green)
        } else if interface.isActive {
          StatusPill(title: L("interface.active", "In use"), systemImage: "bolt.fill", tint: .green)
        }
        if interface.usesHardwareMAC {
          StatusPill(title: L("interface.using_hardware", "Hardware MAC"), systemImage: "exclamationmark.shield", tint: .orange)
        }
      }
    }
  }

  private var addresses: some View {
    HStack(alignment: .top, spacing: 28) {
      AddressValue(label: L("interface.current_mac", "Current MAC"), address: interface.currentMAC, prominent: true)
      if !compact {
        AddressValue(label: L("interface.hardware_mac", "Hardware MAC"), address: interface.hardwareMAC, prominent: false)
      }
      Spacer()
    }
  }

  @ViewBuilder
  private var status: some View {
    if model.isBusy(interface) {
      Label(
        interface.isWiFiAssociated || interface.lastOperation?.disconnectedWiFi == true
          ? L("interface.working_wifi", "Changing the address; Wi-Fi reconnects afterwards…")
          : L("interface.working", "Changing the address…"),
        systemImage: "hourglass"
      )
      .font(.callout)
      .foregroundStyle(.blue)
    } else if let operation = interface.lastOperation {
      OperationLine(operation: operation)
    }
    if let pending = interface.pendingRotation {
      HStack(spacing: 6) {
        Label(
          pending.waitingReason.map { "\(triggerText(pending.trigger)) — \(waitReasonText($0))" } ?? triggerText(pending.trigger),
          systemImage: "clock.badge"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        Button(L("pending.cancel", "Cancel")) { model.cancelPending(interface) }
          .buttonStyle(.link)
          .font(.callout)
      }
    }
    if let notice = interface.notice {
      Label(noticeText(notice), systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var history: some View {
    if !interface.history.entries.isEmpty {
      DisclosureGroup(L("history.disclosure", "History (%1$d of %2$d)", interface.history.entries.count, HistoryLedger.limit)) {
        VStack(spacing: 0) {
          ForEach(interface.history.entries) { entry in
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.address.stringValue)
                  .font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
                Text("\(historySourceText(entry.source)) · \(dateTimeText(entry.lastUsedAt))")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button { copyToPasteboard(entry.address.stringValue) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(L("history.copy", "Copy this address"))
              Button(role: .destructive) { model.removeHistory(interface, address: entry.address) } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              .help(L("history.delete", "Delete this history entry"))
              .disabled(!model.isReady)
            }
            .padding(.vertical, 6)
            Divider()
          }
          HStack {
            Spacer()
            Button(L("history.clear.action", "Clear History"), role: .destructive) { confirmsClearHistory = true }
              .buttonStyle(.borderless)
              .disabled(!model.isReady)
          }
          .padding(.top, 6)
        }
        .padding(.top, 4)
      }
      .font(.subheadline)
    }
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      Button(L("interface.action.copy", "Copy current MAC")) { copy(interface.currentMAC) }
        .disabled(interface.currentMAC == nil)
      if interface.kind.isSupported {
        Button(L("interface.action.randomize", "Randomize now")) { actions.randomize(interface) }
          .buttonStyle(.borderedProminent)
          .disabled(blockedReason != nil)
        Button(L("interface.action.restore", "Restore…")) { actions.restore(interface) }
          .disabled(!model.isReady || model.isBusy(interface))
        if !compact {
          Menu {
            Button(L("policy.action.random", "Rotate automatically (random policy)")) { model.setPolicy(interface, .random) }
              .disabled(interface.policy == .random)
            Button(L("policy.action.system_managed", "Stop managing (hand off to macOS)")) { model.setPolicy(interface, .systemManaged) }
              .disabled(interface.policy == .systemManaged)
          } label: {
            Label(L("policy.action.menu", "Policy"), systemImage: "slider.horizontal.3")
          }
          .fixedSize()
          .disabled(!model.isReady || model.isBusy(interface))
        }
      }
      Spacer()
      if let blockedReason, interface.kind.isSupported {
        Text(blockedReason).font(.caption).foregroundStyle(.secondary)
      } else if interface.isWiFiAssociated {
        Label(L("interface.wifi_notice", "Changing it disconnects Wi-Fi briefly"), systemImage: "wifi.exclamationmark")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if interface.isInUse {
        Label(L("interface.disruption_notice", "Changes require confirmation"), systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  private var symbol: String {
    switch interface.kind {
    case .wifi: "wifi"
    case .ethernet: "cable.connector.horizontal"
    case .other: "network"
    }
  }

  private func copy(_ address: MACAddress?) {
    if let address { copyToPasteboard(address.stringValue) }
  }
}

private struct AddressValue: View {
  let label: String
  let address: MACAddress?
  let prominent: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(macText(address))
        .font(.system(prominent ? .title3 : .body, design: .monospaced, weight: prominent ? .semibold : .regular))
        .textSelection(.enabled)
    }
  }
}

private struct OperationLine: View {
  let operation: OperationRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        StatusPill(title: operationStateText(operation.state), systemImage: symbol, tint: tint)
        Text(operationText(operation.kind)).font(.caption)
        Text(dateTimeText(operation.finishedAt ?? operation.startedAt)).font(.caption2).foregroundStyle(.secondary)
      }
      if let error = operation.error {
        Text(error.localizedMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var symbol: String {
    switch operation.state {
    case .running: "hourglass"
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  private var tint: Color {
    switch operation.state {
    case .running: .blue
    case .succeeded: .green
    case .failed: .red
    }
  }
}
