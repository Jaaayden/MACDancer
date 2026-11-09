import SwiftUI

/// One page: the adapters and what you can do with them. Everything else
/// lives in Settings (⌘,).
struct MainWindowView: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirming: ChangeRequest?
  @State private var enteringAddress: InterfaceSnapshot?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Header()
        HelperSetupCard()
        ForEach(model.warnings, id: \.self) { warning in
          InlineMessage(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        adapters
      }
      .padding(.horizontal, 28)
      .padding(.top, 8)
      .padding(.bottom, 28)
      .frame(maxWidth: 780)
      .frame(maxWidth: .infinity)
      .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.visibleInterfaces.map(\.id))
      .animation(.spring(response: 0.45, dampingFraction: 0.85), value: HelperLook(model))
    }
    .scrollIndicators(.automatic)
    .background(BrandBackground())
    .frame(minWidth: 620, minHeight: 460)
    .environment(\.interfaceActions, InterfaceActions(perform: perform, enterAddress: { enteringAddress = $0 }))
    .confirmationDialog(
      confirmationTitle,
      isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      titleVisibility: .visible,
      presenting: confirming
    ) { request in
      Button(
        request.interface.isWiFiAssociated
          ? L("randomize.confirm.wifi_action", "Disconnect and change")
          : L("randomize.confirm.action", "Change MAC address")
      ) {
        execute(request, confirmed: true)
      }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: { request in
      Text(disruptionMessage(for: request.interface))
    }
    .sheet(item: $enteringAddress) { interface in
      CustomAddressSheet(interface: interface)
        .environmentObject(model)
        .environment(\.interfaceActions, InterfaceActions(perform: perform))
    }
    .alert(item: $model.alert) { alert in
      Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(L("common.ok", "OK"))))
    }
  }

  @ViewBuilder
  private var adapters: some View {
    if model.visibleInterfaces.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "network.slash").font(.system(size: 34)).foregroundStyle(.tertiary)
        Text(L("dashboard.interfaces.empty.title", "No Wi-Fi or Ethernet interfaces")).font(.headline)
        Text(L("dashboard.interfaces.empty.detail", "Connect an Ethernet adapter or turn on Wi-Fi, then refresh."))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 60)
    } else {
      ForEach(model.visibleInterfaces) { interface in
        InterfaceCard(interface: interface)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    if model.hiddenInterfaceCount > 0 || model.showAllInterfaces {
      Button {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { model.showAllInterfaces.toggle() }
      } label: {
        Label(
          model.showAllInterfaces
            ? L("interfaces.hide_extra", "Hide Thunderbolt, bridge and virtual adapters")
            : L("interfaces.show_extra", "Show %d more adapters (Thunderbolt, bridges, virtual)", model.hiddenInterfaceCount),
          systemImage: model.showAllInterfaces ? "chevron.up" : "chevron.down"
        )
        .font(.callout)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .padding(.top, 4)
    }
  }

  private var confirmationTitle: String {
    guard let request = confirming else { return "" }
    return L("randomize.confirm.title", "Change the MAC address of %@?", request.interface.displayName)
  }

  private func perform(_ request: ChangeRequest) {
    if request.needsConfirmation {
      confirming = request
    } else {
      execute(request, confirmed: false)
    }
  }

  private func execute(_ request: ChangeRequest, confirmed: Bool) {
    switch request {
    case let .randomize(interface):
      model.randomize(interface, confirmed: confirmed)
    case let .restore(interface, target):
      model.restore(interface, to: target, confirmed: confirmed)
    }
  }
}

private struct Header: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("MACDancer")
          .font(.system(size: 26, weight: .bold, design: .rounded))
          .foregroundStyle(Brand.gradient)
        Text(summary).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      UpdateChip()
      HelperChip()
      Button { model.refresh() } label: {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
          .animation(model.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
      }
      .buttonStyle(CircleIconButtonStyle())
      .help(L("toolbar.refresh_help", "Read current MAC addresses only. This never changes your network."))
      SettingsLink { Image(systemName: "gearshape") }
        .buttonStyle(CircleIconButtonStyle())
        .help(L("menu_bar.settings", "Settings…"))
    }
    .padding(.bottom, 4)
  }

  private var summary: String {
    let supported = model.visibleInterfaces.filter(\.kind.isSupported)
    guard !supported.isEmpty else { return L("summary.none", "No adapters found") }
    let hardware = supported.filter(\.usesHardwareMAC).count
    if supported.count == 1 {
      return hardware == 0
        ? L("summary.one_private", "1 adapter · not showing its factory address")
        : L("summary.one_hardware", "1 adapter · using its factory address")
    }
    if hardware == 0 {
      return L("summary.all_private", "%d adapters · none shows its factory address", supported.count)
    }
    return L("summary.some_hardware", "%1$d adapters · %2$d using the factory address", supported.count, hardware)
  }
}

/// Explains what confirming a change on an interface in use will do.
func disruptionMessage(for interface: InterfaceSnapshot) -> String {
  if interface.kind == .wifi && interface.isWiFiAssociated {
    return L(
      "disruption.wifi.v3",
      "Wi-Fi only accepts a new address while disconnected, so MACDancer disconnects %@ first. macOS does not rejoin by itself after that: when the change is done, choose your network in the Wi-Fi menu. If Private Wi-Fi Address is on for that network, macOS may swap in its own address when you rejoin.",
      interface.bsdName
    )
  }
  return L(
    "disruption.wired",
    "%@ is in use. Its connection may drop for a moment while macOS applies the new address.",
    interface.bsdName
  )
}
