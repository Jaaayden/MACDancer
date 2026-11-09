import AppKit
import SwiftUI

/// The menu bar window: every adapter with a one-click shuffle. Changes that
/// interrupt a connection ask inline first.
struct MenuBarPanel: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("MACDancer").font(.system(.headline, design: .rounded)).foregroundStyle(Brand.gradient)
        Spacer()
        let look = HelperLook(model)
        HStack(spacing: 5) {
          Circle().fill(look.tint).frame(width: 6, height: 6)
          Text(look.title).font(.caption).foregroundStyle(.secondary)
        }
      }

      let adapters = model.visibleInterfaces.filter(\.kind.isSupported)
      if adapters.isEmpty {
        Text(L("summary.none", "No adapters found")).foregroundStyle(.secondary).font(.callout)
      }
      ForEach(adapters) { interface in
        MenuBarRow(interface: interface)
      }

      Divider()
      HStack(spacing: 8) {
        Button(L("menu_bar.open_short", "Open")) {
          model.start()
          openWindow(id: mainWindowID)
          NSApplication.shared.activate()
        }
        .fixedSize()
        SettingsLink { Text(L("menu_bar.settings", "Settings…")) }
          .fixedSize()
        Spacer()
        Button(L("menu_bar.quit_short", "Quit")) { NSApplication.shared.terminate(nil) }
          .fixedSize()
      }
      .buttonStyle(SoftButtonStyle())
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: 340)
    .onAppear {
      model.start()
      model.refresh()
    }
  }
}

private func shortNotice(_ notice: InterfaceNotice) -> String {
  switch notice {
  case .addressReplacedAfterReconnect: L("notice.short.replaced", "macOS swapped in its own address")
  case .wifiNotRejoined: L("notice.short.reconnect", "Choose your network in the Wi-Fi menu")
  }
}

private struct MenuBarRow: View {
  @EnvironmentObject private var model: AppModel
  let interface: InterfaceSnapshot
  @State private var confirming = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        IconTile(systemImage: interfaceSymbol(interface.kind), active: interface.isInUse, size: 30)
        VStack(alignment: .leading, spacing: 3) {
          Text(interface.displayName).font(.callout.weight(.semibold)).lineLimit(1)
          ByteStrip(address: interface.currentMAC, reference: interface.hardwareMAC, dancing: model.isBusy(interface), size: 11)
        }
        Spacer(minLength: 4)
        Button {
          if interface.isInUse {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { confirming.toggle() }
          } else {
            model.randomize(interface, confirmed: false)
          }
        } label: {
          Image(systemName: "shuffle")
        }
        .buttonStyle(GradientButtonStyle())
        .disabled(model.blockedReason(for: interface) != nil)
        .help(model.blockedReason(for: interface) ?? L("interface.action.shuffle_help", "Give this adapter a new random address"))
      }
      if confirming {
        VStack(alignment: .leading, spacing: 8) {
          Text(interface.isWiFiAssociated
            ? L("menu_bar.confirm.wifi.v2", "Wi-Fi disconnects. Afterwards choose your network in the Wi-Fi menu.")
            : L("menu_bar.confirm.wired", "The connection may drop for a moment."))
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Spacer()
            Button(L("common.cancel", "Cancel")) { withAnimation { confirming = false } }
              .buttonStyle(SoftButtonStyle())
            Button(L("randomize.confirm.action", "Change MAC address")) {
              withAnimation { confirming = false }
              model.randomize(interface, confirmed: true)
            }
            .buttonStyle(GradientButtonStyle())
          }
          .controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let notice = interface.notice {
        Label(shortNotice(notice), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .help(noticeText(notice))
      }
    }
  }
}
