import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmingRandomize: InterfaceSnapshot?
  @State private var restoring: InterfaceSnapshot?

  var body: some View {
    NavigationSplitView {
      List(AppSection.allCases, selection: selection) { section in
        Label(sectionTitle(section), systemImage: sectionSymbol(section)).tag(section)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    } detail: {
      detail
        .environment(\.interfaceActions, InterfaceActions(
          randomize: requestRandomize,
          restore: { restoring = $0 }
        ))
    }
    .frame(minWidth: 820, minHeight: 540)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.refresh()
        } label: {
          Label(L("toolbar.refresh", "Refresh"), systemImage: "arrow.clockwise")
        }
        .help(L("toolbar.refresh_help", "Read current MAC addresses only. This never changes your network."))
        .disabled(model.isRefreshing)
      }
    }
    .confirmationDialog(
      confirmationTitle,
      isPresented: Binding(get: { confirmingRandomize != nil }, set: { if !$0 { confirmingRandomize = nil } }),
      titleVisibility: .visible,
      presenting: confirmingRandomize
    ) { interface in
      Button(
        interface.isWiFiAssociated
          ? L("randomize.confirm.wifi_action", "Disconnect and change")
          : L("randomize.confirm.action", "Change MAC address"),
        role: .destructive
      ) {
        model.randomize(interface, confirmed: true)
      }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: { interface in
      Text(disruptionMessage(for: interface))
    }
    .sheet(item: $restoring) { interface in
      RestoreSheet(interfaceID: interface.id)
        .environmentObject(model)
    }
    .alert(item: $model.alert) { alert in
      Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(L("common.ok", "OK"))))
    }
  }

  private var selection: Binding<AppSection?> {
    Binding(get: { model.selection }, set: { if let section = $0 { model.selection = section } })
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selection {
    case .dashboard: DashboardView()
    case .interfaces: InterfacesView()
    case .automation: AutomationView()
    case .settings: SettingsView()
    }
  }

  private var confirmationTitle: String {
    guard let interface = confirmingRandomize else { return "" }
    return L("randomize.confirm.title", "Change the MAC address of %@?", interface.displayName)
  }

  private func requestRandomize(_ interface: InterfaceSnapshot) {
    if model.needsConfirmation(interface) {
      confirmingRandomize = interface
    } else {
      model.randomize(interface, confirmed: false)
    }
  }
}

/// Explains what confirming a change on an interface in use will do.
func disruptionMessage(for interface: InterfaceSnapshot) -> String {
  if interface.kind == .wifi && interface.isWiFiAssociated {
    return L(
      "disruption.wifi",
      "Wi-Fi drivers only accept a new address while disconnected. MACDancer will disconnect %@, change the address, and macOS will rejoin the network by itself. If Private Wi-Fi Address is on for that network, macOS may replace the new address when it rejoins.",
      interface.bsdName
    )
  }
  return L(
    "disruption.wired",
    "%@ is in use. Its connection may drop for a moment while macOS applies the new address.",
    interface.bsdName
  )
}
