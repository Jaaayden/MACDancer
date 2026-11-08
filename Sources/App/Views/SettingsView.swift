import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage(menuBarIconPreferenceKey) private var showMenuBarIcon = true

  var body: some View {
    Page(
      title: L("settings.title", "Settings"),
      subtitle: L("settings.subtitle", "Choose how MACDancer looks and how it generates addresses.")
    ) {
      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          SettingRow(
            symbol: "globe",
            title: L("settings.language.title", "Language"),
            detail: L("settings.language.detail", "Choose a language for MACDancer without changing the macOS system language.")
          ) {
            Picker(L("settings.language.title", "Language"), selection: $model.language) {
              Text(L("settings.language.system", "System Default")).tag(AppLanguage.system)
              Text("English").tag(AppLanguage.english)
              Text("简体中文").tag(AppLanguage.simplifiedChinese)
            }
            .labelsHidden()
            .frame(width: 160)
          }
          Divider()
          SettingRow(
            symbol: "menubar.rectangle",
            title: L("settings.menu_bar.title", "Show menu bar icon"),
            detail: L("settings.menu_bar.detail", "A small menu with current addresses. The main window and Dock icon stay available when it is off.")
          ) {
            Toggle("", isOn: $showMenuBarIcon).labelsHidden().toggleStyle(.switch)
          }
          Divider()
          SettingRow(
            symbol: "rectangle.stack",
            title: L("settings.show_all.title", "Show all interfaces"),
            detail: L("settings.show_all.detail", "Also list Thunderbolt ports, bridges and virtual adapters. They are hidden because their addresses rarely matter.")
          ) {
            Toggle("", isOn: $model.showAllInterfaces).labelsHidden().toggleStyle(.switch)
          }
        }
        .padding(4)
      }

      GroupBox {
        UpdateSettings().padding(4)
      }

      GroupBox {
        SettingRow(
          symbol: "building.2.crop.circle", tint: .orange,
          title: L("settings.vendor.title", "Vendor-OUI compatibility mode"),
          detail: L(
            "settings.vendor.detail",
            "Keep the interface’s hardware vendor prefix and randomize the rest. Some strict networks need this, but it reveals the device vendor and is less private."
          )
        ) {
          Toggle("", isOn: Binding(
            get: { model.automation.vendorCompatibility },
            set: { value in
              var settings = model.automation
              settings.vendorCompatibility = value
              model.setAutomation(settings)
            }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!model.isReady || model.isUpdatingAutomation)
        }
        .padding(4)
      }

      GroupBox {
        SettingRow(
          symbol: "wifi", tint: .gray,
          title: L("settings.private_wifi.title", "Private Wi-Fi Address"),
          detail: L(
            "settings.private_wifi.detail",
            "macOS can use its own private address per Wi-Fi network. When it is on, macOS may replace MACDancer’s address whenever it rejoins that network. Turn it off for networks where you want your own address."
          )
        ) {
          Button(L("settings.private_wifi.open", "Open Network Settings")) { openNetworkSettings() }
        }
        .padding(4)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text(L("settings.diagnostics.title", "Diagnostics")).font(.headline)
          row(L("settings.diagnostics.status", "Background service"), statusText)
          row(L("settings.diagnostics.protocol", "Protocol"), "\(MACDancerConstants.protocolVersion)")
          row(L("settings.diagnostics.daemon_version", "Background service version"), model.daemonSnapshot?.daemonVersion ?? "—")
          row(L("settings.diagnostics.last_read", "Last read"), dateTimeText(model.lastRefreshAt))
          ForEach(model.warnings, id: \.self) { warning in
            Text(warning).font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
          }
          Text(L("settings.diagnostics.logs", "The service logs to Console under the subsystem local.macdancer.MACDancer."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(4)
      }
    }
  }

  private var statusText: String {
    switch model.status {
    case .checking: L("daemon.status.checking", "Checking")
    case .notInstalled: L("daemon.status.not_installed", "Not installed")
    case .awaitingApproval: L("daemon.status.awaiting_approval", "Approval required")
    case .connecting: L("daemon.status.connecting", "Connecting")
    case .ready: L("daemon.status.ready", "Ready")
    case let .unreachable(reason): "\(L("daemon.status.unavailable", "Unavailable")) — \(reason)"
    case let .incompatible(version): "\(L("daemon.status.incompatible", "Version mismatch")) (\(version))"
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
    .font(.subheadline)
  }
}
