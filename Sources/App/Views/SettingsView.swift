import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    TabView {
      GeneralSettings()
        .tabItem { Label(L("settings.tab.general", "General"), systemImage: "gearshape") }
      RotationSettings()
        .tabItem { Label(L("settings.tab.rotation", "Rotation"), systemImage: "arrow.triangle.2.circlepath") }
      HelperSettings()
        .tabItem { Label(L("settings.tab.helper", "Helper"), systemImage: "lock.shield") }
    }
    .frame(width: 560)
    .frame(minHeight: 420)
    .alert(item: $model.alert) { alert in
      Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(L("common.ok", "OK"))))
    }
  }
}

struct GeneralSettings: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage(menuBarIconPreferenceKey) private var showMenuBarIcon = true

  var body: some View {
    Form {
      Section {
        Picker(L("settings.language.title", "Language"), selection: $model.language) {
          Text(L("settings.language.system", "System Default")).tag(AppLanguage.system)
          Text("English").tag(AppLanguage.english)
          Text("简体中文").tag(AppLanguage.simplifiedChinese)
        }
        Toggle(isOn: $showMenuBarIcon) {
          Text(L("settings.menu_bar.title", "Show menu bar icon"))
          Text(L("settings.menu_bar.detail.v2", "Change addresses right from the menu bar."))
        }
        Toggle(isOn: $model.showAllInterfaces) {
          Text(L("settings.show_all.title", "Show all interfaces"))
          Text(L("settings.show_all.detail", "Also list Thunderbolt ports, bridges and virtual adapters. They are hidden because their addresses rarely matter."))
        }
      }
      UpdateSettingsSection()
    }
    .formStyle(.grouped)
  }
}

struct RotationSettings: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section {
        toggle(
          \.rotateAfterWake,
          title: L("automation.setting.wake.title", "Rotate after wake"),
          detail: L("automation.setting.wake.detail", "After the Mac wakes, rotate each random-policy interface as soon as it is not in use.")
        )
        toggle(
          \.rotateWhenInterfaceBecomesInactive,
          title: L("automation.setting.inactive.title", "Rotate when an interface stops being used"),
          detail: L("automation.setting.inactive.detail", "When an interface disconnects (for example Wi-Fi leaves a network), give it a new address before its next connection.")
        )
        toggle(
          \.prepareRotationBeforeSleep,
          title: L("automation.setting.sleep.title", "Prepare a rotation before sleep"),
          detail: L("automation.setting.sleep.detail", "Queue a rotation as the Mac goes to sleep. Nothing is written until it wakes and the interface is safe.")
        )
      } header: {
        Text(L("rotation.when", "When adapters with Auto-rotate get a new address"))
      } footer: {
        Text(autoRotateSummary).font(.caption).foregroundStyle(.secondary)
      }

      Section(L("rotation.addresses", "Addresses")) {
        toggle(
          \.vendorCompatibility,
          title: L("settings.vendor.title", "Vendor-OUI compatibility mode"),
          detail: L(
            "settings.vendor.detail",
            "Keep the interface’s hardware vendor prefix and randomize the rest. Some strict networks need this, but it reveals the device vendor and is less private."
          )
        )
        LabeledContent {
          Button(L("settings.private_wifi.open", "Open Network Settings")) { openNetworkSettings() }
        } label: {
          Text(L("settings.private_wifi.title", "Private Wi-Fi Address"))
          Text(L(
            "settings.private_wifi.detail",
            "macOS can use its own private address per Wi-Fi network. When it is on, macOS may replace MACDancer’s address whenever it rejoins that network. Turn it off for networks where you want your own address."
          ))
        }
      }

      Section(L("rotation.rules", "Always")) {
        rule("wifi.slash", L("automation.rule.wifi.detail", "Automatic rotation never disconnects Wi-Fi. It waits until Wi-Fi is off a network."))
        rule("arrow.triangle.branch", L("automation.rule.route.detail", "An interface with an IP address or the default route keeps its address until it is idle."))
        rule("bed.double", L("automation.rule.sleep.detail", "Before sleep MACDancer only records the pending rotation and lets the Mac sleep at once."))
      }
    }
    .formStyle(.grouped)
    .disabled(!model.isReady || model.isUpdatingAutomation)
  }

  private var autoRotateSummary: String {
    let names = model.interfaces.filter { $0.policy == .random }.map(\.displayName)
    return names.isEmpty
      ? L("rotation.none", "No adapter has Auto-rotate on. Turn it on in an adapter’s card.")
      : L("rotation.some", "Auto-rotate is on for: %@", names.joined(separator: ", "))
  }

  private func toggle(_ keyPath: WritableKeyPath<AutomationSettings, Bool>, title: String, detail: String) -> some View {
    Toggle(isOn: Binding(
      get: { model.automation[keyPath: keyPath] },
      set: { value in
        var settings = model.automation
        settings[keyPath: keyPath] = value
        model.setAutomation(settings)
      }
    )) {
      Text(title)
      Text(detail)
    }
  }

  private func rule(_ symbol: String, _ text: String) -> some View {
    Label {
      Text(text).font(.callout).foregroundStyle(.secondary)
    } icon: {
      Image(systemName: symbol).foregroundStyle(Brand.indigo)
    }
  }
}

struct HelperSettings: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmsRemoveHelper = false
  @State private var confirmsUninstall = false

  var body: some View {
    Form {
      Section {
        LabeledContent(L("settings.diagnostics.status", "Background service"), value: HelperLook(model).title)
        LabeledContent(L("settings.diagnostics.daemon_version", "Background service version"), value: model.daemonSnapshot?.daemonVersion ?? "—")
        LabeledContent(L("settings.diagnostics.protocol", "Protocol"), value: "\(MACDancerConstants.protocolVersion)")
        LabeledContent(L("settings.diagnostics.last_read", "Last read"), value: dateTimeText(model.lastRefreshAt))
        ForEach(model.warnings, id: \.self) { warning in
          Text(warning).font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
        }
        HStack {
          Text(helperMessage(model)).font(.caption).foregroundStyle(.secondary)
          Spacer()
          HelperPrimaryButton()
        }
      } header: {
        Text(L("settings.diagnostics.title", "Diagnostics"))
      } footer: {
        Text(L("settings.diagnostics.logs", "The service logs to Console under the subsystem local.macdancer.MACDancer."))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Section(L("settings.remove.title", "Remove")) {
        LabeledContent {
          Button(L("settings.remove_helper.button", "Remove Helper…")) { confirmsRemoveHelper = true }
            .disabled(model.registration == .notInstalled || model.isChangingService)
        } label: {
          Text(L("settings.remove_helper.title", "Remove the helper only"))
          Text(L("settings.remove_helper.detail", "Stops automatic rotation. The app keeps working read-only."))
        }
        LabeledContent {
          Button(role: .destructive) { confirmsUninstall = true } label: {
            if model.isUninstalling {
              ProgressView().controlSize(.small)
            } else {
              Text(L("settings.uninstall.button", "Uninstall…")).foregroundStyle(.red)
            }
          }
          .disabled(model.isUninstalling)
        } label: {
          Text(L("settings.uninstall.title", "Uninstall MACDancer"))
          Text(L("settings.uninstall.detail", "Removes the helper, its settings and history, this app’s preferences and caches, and moves the app to the Trash."))
        }
      }
    }
    .formStyle(.grouped)
    .alert(L("daemon.uninstall.title", "Uninstall the background service?"), isPresented: $confirmsRemoveHelper) {
      Button(L("daemon.action.uninstall_confirm", "Uninstall"), role: .destructive) { model.uninstallService() }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: {
      Text(L(
        "daemon.uninstall.message",
        "Automatic rotation stops. Current MAC addresses, policies and history are kept, and no address is restored."
      ))
    }
    .alert(L("settings.uninstall.confirm.title", "Uninstall MACDancer completely?"), isPresented: $confirmsUninstall) {
      Button(L("settings.uninstall.confirm.action", "Uninstall and Quit"), role: .destructive) { model.uninstallApp() }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: {
      Text(L(
        "settings.uninstall.confirm.message",
        "Everything MACDancer stored is deleted and the app moves to the Trash. Changed addresses stay until the next restart, when macOS uses the hardware addresses again."
      ))
    }
  }
}
