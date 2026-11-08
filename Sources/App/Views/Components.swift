import AppKit
import SwiftUI

let mainWindowID = "main"
let menuBarIconPreferenceKey = "showMenuBarIcon"

func sectionTitle(_ section: AppSection) -> String {
  switch section {
  case .dashboard: L("section.dashboard", "Dashboard")
  case .interfaces: L("section.interfaces", "Interfaces")
  case .automation: L("section.automation", "Automation")
  case .settings: L("section.settings", "Settings")
  }
}

func sectionSymbol(_ section: AppSection) -> String {
  switch section {
  case .dashboard: "rectangle.3.group.fill"
  case .interfaces: "network"
  case .automation: "clock.arrow.circlepath"
  case .settings: "gearshape"
  }
}

func copyToPasteboard(_ value: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(value, forType: .string)
}

func openNetworkSettings() {
  if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension"),
     NSWorkspace.shared.open(url) {
    return
  }
  NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
}

/// What the interface cards ask the window to do. The window owns the
/// confirmation dialog and the restore sheet.
struct InterfaceActions {
  var randomize: (InterfaceSnapshot) -> Void = { _ in }
  var restore: (InterfaceSnapshot) -> Void = { _ in }
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

struct StatusPill: View {
  let title: String
  let systemImage: String
  let tint: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(tint.opacity(0.12), in: Capsule())
      .fixedSize()
  }
}

struct PageHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.largeTitle.weight(.semibold))
      Text(subtitle).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A scrolling page with the common header and width.
struct Page<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(title: title, subtitle: subtitle)
        content
      }
      .padding(24)
      .frame(maxWidth: 980, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(title)
  }
}

/// An icon, a title and an explanation, with an optional trailing control.
struct SettingRow<Accessory: View>: View {
  let symbol: String
  var tint: Color = .accentColor
  let title: String
  let detail: String
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 16)
      accessory
    }
  }
}

extension SettingRow where Accessory == EmptyView {
  init(symbol: String, tint: Color = .accentColor, title: String, detail: String) {
    self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
  }
}

struct WarningBanner: View {
  let messages: [String]

  var body: some View {
    if !messages.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(messages, id: \.self) { message in
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}
