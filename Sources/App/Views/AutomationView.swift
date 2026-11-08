import SwiftUI

struct AutomationView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Page(
      title: L("automation.title", "Automation"),
      subtitle: L("automation.subtitle", "Rotate addresses of interfaces with the random policy, without ever interrupting a connection.")
    ) {
      GroupBox {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(L("automation.configured.title", "Interfaces with the random policy")).font(.headline)
            Text(randomInterfaces.isEmpty
              ? L("automation.configured.none", "None yet. “Randomize now” or the Policy menu on an interface turns it on.")
              : randomInterfaces.map(\.displayName).joined(separator: ", "))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(L("automation.configure", "Review interfaces")) { model.selection = .interfaces }
        }
        .padding(4)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          toggle(
            \.rotateAfterWake,
            title: L("automation.setting.wake.title", "Rotate after wake"),
            detail: L("automation.setting.wake.detail", "After the Mac wakes, rotate each random-policy interface as soon as it is not in use.")
          )
          Divider()
          toggle(
            \.rotateWhenInterfaceBecomesInactive,
            title: L("automation.setting.inactive.title", "Rotate when an interface stops being used"),
            detail: L("automation.setting.inactive.detail", "When an interface disconnects (for example Wi-Fi leaves a network), give it a new address before its next connection.")
          )
          Divider()
          toggle(
            \.prepareRotationBeforeSleep,
            title: L("automation.setting.sleep.title", "Prepare a rotation before sleep"),
            detail: L("automation.setting.sleep.detail", "Queue a rotation as the Mac goes to sleep. Nothing is written until it wakes and the interface is safe.")
          )
        }
        .padding(4)
      }
      .disabled(!model.isReady || model.isUpdatingAutomation)

      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          SettingRow(
            symbol: "wifi.slash", tint: .orange,
            title: L("automation.rule.wifi.title", "Connected Wi-Fi is never touched automatically"),
            detail: L("automation.rule.wifi.detail", "Automatic rotation never disconnects Wi-Fi. It waits until Wi-Fi is off a network.")
          )
          SettingRow(
            symbol: "arrow.triangle.branch", tint: .orange,
            title: L("automation.rule.route.title", "Interfaces in use are protected"),
            detail: L("automation.rule.route.detail", "An interface with an IP address or the default route keeps its address until it is idle.")
          )
          SettingRow(
            symbol: "bed.double.fill", tint: .purple,
            title: L("automation.rule.sleep.title", "Sleep is never delayed"),
            detail: L("automation.rule.sleep.detail", "Before sleep MACDancer only records the pending rotation and lets the Mac sleep at once.")
          )
        }
        .padding(4)
      }
    }
  }

  private var randomInterfaces: [InterfaceSnapshot] {
    model.interfaces.filter { $0.policy == .random }
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
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.switch)
  }
}
