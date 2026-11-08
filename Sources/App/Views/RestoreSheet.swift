import SwiftUI

struct RestoreSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let interfaceID: String

  @State private var destination: Destination = .systemManaged
  @State private var historySelection: MACAddress?
  @State private var specifiedText = ""
  @State private var confirmsDisruption = false
  @State private var confirmsGlobalAddress = false

  private enum Destination: Hashable { case systemManaged, hardware, history, specified }

  var body: some View {
    if let interface = model.interfaces.first(where: { $0.id == interfaceID }) {
      content(interface)
    } else {
      VStack(spacing: 16) {
        Text(L("restore.gone", "This interface is no longer available."))
        Button(L("common.ok", "OK")) { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(32)
    }
  }

  private func content(_ interface: InterfaceSnapshot) -> some View {
    let target = target(for: interface)
    let needsDisruptionConfirmation = target.map { requiresDisruption($0, interface) } ?? false
    let needsGlobalConfirmation = destination == .specified && parsedSpecified.map { !$0.isLocallyAdministered && $0 != interface.hardwareMAC } == true
    let canApply = target != nil
      && (!needsDisruptionConfirmation || confirmsDisruption)
      && (!needsGlobalConfirmation || confirmsGlobalAddress)

    return VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "arrow.uturn.backward.circle.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 3) {
          Text(L("restore.title", "Restore MAC address")).font(.title2.weight(.semibold))
          Text("\(interface.displayName) · \(interface.bsdName)").foregroundStyle(.secondary)
          Text(L("restore.current_format", "Current: %@", macText(interface.currentMAC)))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding()

      Form {
        Section {
          Picker(L("restore.destination.title", "Choose what to use"), selection: $destination) {
            Text(L("restore.destination.system_managed", "Hand off to macOS")).tag(Destination.systemManaged)
            Text(L("restore.destination.hardware", "Use hardware MAC")).tag(Destination.hardware)
              .disabled(interface.hardwareMAC == nil)
            Text(L("restore.destination.history", "Use this interface’s history")).tag(Destination.history)
              .disabled(interface.history.entries.isEmpty)
            Text(L("restore.destination.specified", "Use a specified MAC")).tag(Destination.specified)
          }
          .pickerStyle(.radioGroup)
        }

        detail(interface)

        if needsDisruptionConfirmation {
          Section {
            Toggle(isOn: $confirmsDisruption) {
              VStack(alignment: .leading, spacing: 4) {
                Text(interface.isWiFiAssociated
                  ? L("restore.disruption.wifi_title", "Disconnect Wi-Fi to apply this address")
                  : L("restore.disruption.title", "I understand this can interrupt my connection"))
                Text(disruptionMessage(for: interface)).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }

        if needsGlobalConfirmation {
          Section {
            Toggle(isOn: $confirmsGlobalAddress) {
              VStack(alignment: .leading, spacing: 4) {
                Text(L("restore.specified.global_warning.title", "I understand this is not a locally administered address"))
                Text(L(
                  "restore.specified.global_warning.detail",
                  "This address can impersonate a globally assigned device identity. Use it only when you own the address and understand the collision risk."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Button(L("common.cancel", "Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(applyTitle) {
          guard let target else { return }
          model.restore(interface, to: target, confirmed: needsDisruptionConfirmation && confirmsDisruption)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canApply || model.isBusy(interface))
      }
      .padding()
    }
    .frame(width: 580, height: 600)
    .onAppear {
      historySelection = interface.history.entries.first?.address
    }
  }

  @ViewBuilder
  private func detail(_ interface: InterfaceSnapshot) -> some View {
    switch destination {
    case .systemManaged:
      Section {
        Text(L(
          "restore.system_managed.detail",
          "MACDancer stops writing to this interface and cancels its pending rotations. The current address is left as it is."
        ))
        .foregroundStyle(.secondary)
        if !interface.usesHardwareMAC, interface.hardwareMAC != nil {
          Label(
            L("restore.system_managed.different_mac", "The current MAC is not the hardware address. Choose “Use hardware MAC” to write it back."),
            systemImage: "info.circle"
          )
          .font(.caption)
        }
        if interface.kind == .wifi {
          Text(L(
            "restore.private_wifi.detail",
            "Private Wi-Fi Address (Off, Fixed or Rotating) is a per-network macOS setting. MACDancer cannot change it; open Network Settings to choose."
          ))
          .font(.caption)
          .foregroundStyle(.secondary)
          Button(L("restore.private_wifi.open", "Open Network Settings")) { openNetworkSettings() }
        }
      }

    case .hardware:
      Section {
        Text(macText(interface.hardwareMAC)).font(.system(.body, design: .monospaced, weight: .medium))
        Text(L("restore.hardware.detail", "Write back the factory address macOS reports for this interface."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

    case .history:
      Section {
        Picker(L("restore.history.picker", "Previous MAC address"), selection: $historySelection) {
          ForEach(interface.history.entries) { entry in
            Text("\(entry.address.stringValue) — \(dateTimeText(entry.lastUsedAt))")
              .tag(Optional(entry.address))
          }
        }
      }

    case .specified:
      Section {
        TextField(L("restore.specified.placeholder", "aa:bb:cc:dd:ee:ff"), text: $specifiedText)
          .font(.system(.body, design: .monospaced))
        if !specifiedText.isEmpty && parsedSpecified == nil {
          Label(L("restore.specified.invalid", "Enter a unicast 48-bit MAC address, for example 02:1a:2b:3c:4d:5e."), systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        } else {
          Text(L("restore.specified.detail", "Addresses starting with x2, x6, xA or xE are locally administered and the safest choice."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var parsedSpecified: MACAddress? {
    MACAddress(specifiedText).flatMap { $0.isAssignable ? $0 : nil }
  }

  private func target(for interface: InterfaceSnapshot) -> RestoreTarget? {
    switch destination {
    case .systemManaged: return .systemManaged
    case .hardware: return interface.hardwareMAC == nil ? nil : .hardware
    case .history: return historySelection.map { .history($0) }
    case .specified: return parsedSpecified.map { .specified($0, confirmedGlobalAddress: confirmsGlobalAddress) }
    }
  }

  private func requiresDisruption(_ target: RestoreTarget, _ interface: InterfaceSnapshot) -> Bool {
    let address: MACAddress?
    switch target {
    case .systemManaged: return false
    case .hardware: address = interface.hardwareMAC
    case let .history(entry): address = entry
    case let .specified(entry, _): address = entry
    }
    return interface.isInUse && address != interface.currentMAC
  }

  private var applyTitle: String {
    switch destination {
    case .systemManaged: L("restore.action.handoff", "Hand off to macOS")
    case .hardware: L("restore.action.hardware", "Restore hardware MAC")
    case .history: L("restore.action.history", "Restore selected MAC")
    case .specified: L("restore.action.specified", "Apply specified MAC")
    }
  }
}
