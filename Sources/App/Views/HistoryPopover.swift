import SwiftUI

/// Earlier addresses of one adapter: reuse, copy or forget them.
struct HistoryPopover: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.interfaceActions) private var actions
  @Environment(\.dismiss) private var dismiss
  let interfaceID: String
  @State private var confirmsClear = false

  private var interface: InterfaceSnapshot? { model.interfaces.first { $0.id == interfaceID } }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(L("history.title", "Previous addresses")).font(.headline)
        Spacer()
        Text(L("history.count", "%1$d of %2$d", interface?.history.entries.count ?? 0, HistoryLedger.limit))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding([.horizontal, .top], 14)
      .padding(.bottom, 8)

      if let interface, !interface.history.entries.isEmpty {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(interface.history.entries) { entry in
              HistoryRow(entry: entry, isCurrent: entry.address == interface.currentMAC) {
                dismiss()
                actions.perform(.restore(interface, .history(entry.address)))
              } onDelete: {
                model.removeHistory(interface, address: entry.address)
              }
            }
          }
          .padding(.horizontal, 6)
        }
        .frame(maxHeight: 280)

        Divider()
        HStack {
          Spacer()
          Button(L("history.clear.action", "Clear History"), role: .destructive) { confirmsClear = true }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(!model.isReady)
        }
        .padding(10)
      } else {
        Text(L("history.empty", "No earlier addresses yet."))
          .foregroundStyle(.secondary)
          .padding(14)
      }
    }
    .frame(width: 360)
    .alert(L("history.clear.confirmation.title", "Clear this interface’s MAC history?"), isPresented: $confirmsClear) {
      Button(L("history.clear.action", "Clear History"), role: .destructive) {
        if let interface { model.removeHistory(interface, address: nil) }
      }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: {
      Text(L("history.clear.confirmation.message", "This removes saved MAC choices for this interface. It does not change the current MAC address or policy."))
    }
  }
}

private struct HistoryRow: View {
  @EnvironmentObject private var model: AppModel
  let entry: HistoryEntry
  let isCurrent: Bool
  let onUse: () -> Void
  let onDelete: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.address.stringValue)
          .font(.system(.body, design: .monospaced, weight: .medium))
        Text("\(historySourceText(entry.source)) · \(relativeText(entry.lastUsedAt))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if isCurrent {
        Tag(title: L("history.current", "Current"), tint: Brand.mintInk)
      } else {
        Button(L("history.use", "Use"), action: onUse)
          .buttonStyle(SoftButtonStyle())
          .disabled(!model.isReady)
      }
      Button { copyToPasteboard(entry.address.stringValue) } label: { Image(systemName: "doc.on.doc") }
        .buttonStyle(.borderless)
        .help(L("history.copy", "Copy this address"))
      Button(action: onDelete) { Image(systemName: "trash") }
        .buttonStyle(.borderless)
        .help(L("history.delete", "Delete this history entry"))
        .disabled(!model.isReady)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onHover { hovering = $0 }
  }
}

/// Type an exact address to apply.
struct CustomAddressSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.interfaceActions) private var actions
  @Environment(\.dismiss) private var dismiss
  let interface: InterfaceSnapshot

  @State private var text = ""
  @State private var confirmsGlobal = false
  @FocusState private var focused: Bool

  private var parsed: MACAddress? { MACAddress(text).flatMap { $0.isAssignable ? $0 : nil } }
  private var isGlobal: Bool { parsed.map { !$0.isLocallyAdministered && $0 != interface.hardwareMAC } ?? false }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        IconTile(systemImage: "keyboard")
        VStack(alignment: .leading, spacing: 2) {
          Text(L("custom.title", "Enter an address")).font(.title3.weight(.semibold))
          Text("\(interface.displayName) · \(interface.bsdName)").foregroundStyle(.secondary)
        }
      }

      TextField(L("restore.specified.placeholder", "aa:bb:cc:dd:ee:ff"), text: $text)
        .textFieldStyle(.roundedBorder)
        .font(.system(.title3, design: .monospaced))
        .focused($focused)
        .onSubmit(apply)

      ByteStrip(address: parsed ?? interface.currentMAC, reference: interface.currentMAC, size: 16, copyable: false)
        .opacity(parsed == nil ? 0.35 : 1)

      if !text.isEmpty && parsed == nil {
        Label(L("restore.specified.invalid", "Enter a unicast 48-bit MAC address, for example 02:1a:2b:3c:4d:5e."), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      } else {
        Text(L("restore.specified.detail", "Addresses starting with x2, x6, xA or xE are locally administered and the safest choice."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if isGlobal {
        Toggle(isOn: $confirmsGlobal) {
          VStack(alignment: .leading, spacing: 3) {
            Text(L("restore.specified.global_warning.title", "I understand this is not a locally administered address"))
            Text(L(
              "restore.specified.global_warning.detail",
              "This address can impersonate a globally assigned device identity. Use it only when you own the address and understand the collision risk."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.checkbox)
      }

      HStack {
        Spacer()
        Button(L("common.cancel", "Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L("custom.apply", "Apply"), action: apply)
          .keyboardShortcut(.defaultAction)
          .disabled(parsed == nil || (isGlobal && !confirmsGlobal))
      }
    }
    .padding(22)
    .frame(width: 430)
    .onAppear { focused = true }
  }

  private func apply() {
    guard let parsed, !isGlobal || confirmsGlobal else { return }
    dismiss()
    actions.perform(.restore(interface, .specified(parsed, confirmedGlobalAddress: confirmsGlobal)))
  }
}
