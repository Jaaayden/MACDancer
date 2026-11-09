import AppKit
import SwiftUI

let mainWindowID = "main"
let menuBarIconPreferenceKey = "showMenuBarIcon"

// MARK: - Brand

/// The icon's palette: a blue-violet gradient with a mint accent.
enum Brand {
  static let blue = Color(hex: 0x3D8BFF)
  static let indigo = Color(hex: 0x5B5BF6)
  static let violet = Color(hex: 0x8B3FE8)
  static let mint = Color(hex: 0x5FF5C8)
  /// Mint dark enough to read as text on a light background.
  static let mintInk = Color(light: 0x0B9D74, dark: 0x5FF5C8)
  static let gradient = LinearGradient(colors: [blue, indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255,
      opacity: opacity
    )
  }

  init(light: UInt32, dark: UInt32) {
    self.init(nsColor: NSColor(name: nil) { appearance in
      let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: 1
      )
    })
  }
}

/// The window background: plain, with a faint brand glow at the top.
struct BrandBackground: View {
  var body: some View {
    ZStack(alignment: .top) {
      Color(nsColor: .windowBackgroundColor)
      RadialGradient(
        colors: [Brand.indigo.opacity(0.13), Brand.violet.opacity(0.04), .clear],
        center: .init(x: 0.3, y: 0), startRadius: 0, endRadius: 520
      )
      .frame(height: 420)
    }
    .ignoresSafeArea()
  }
}

// MARK: - Surfaces

struct Card: ViewModifier {
  var emphasized = false
  var padding: CGFloat = 18

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    content
      .padding(padding)
      .background {
        shape
          .fill(Color(nsColor: .controlBackgroundColor))
          .shadow(color: .black.opacity(0.06), radius: 14, y: 5)
      }
      .overlay {
        if emphasized {
          shape.strokeBorder(Brand.gradient, lineWidth: 1.5).opacity(0.75)
        } else {
          shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
      }
  }
}

extension View {
  func card(emphasized: Bool = false, padding: CGFloat = 18) -> some View {
    modifier(Card(emphasized: emphasized, padding: padding))
  }
}

/// A rounded square holding a symbol: brand gradient when active.
struct IconTile: View {
  let systemImage: String
  var active = true
  var size: CGFloat = 42

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      .fill(active ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: systemImage)
          .font(.system(size: size * 0.44, weight: .semibold))
          .foregroundStyle(active ? .white : .secondary)
      }
      .shadow(color: active ? Brand.indigo.opacity(0.35) : .clear, radius: 6, y: 3)
  }
}

/// A small tinted capsule: "Connected", "Default route".
struct Tag: View {
  let title: String
  var systemImage: String?
  var tint: Color = .secondary

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage).imageScale(.small) }
      Text(title)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint.opacity(0.12), in: Capsule())
    .fixedSize()
  }
}

// MARK: - Buttons

/// The primary action: a gradient capsule that presses in and glows on hover.
struct GradientButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(isEnabled ? .white : .secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background {
        Capsule().fill(isEnabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
      }
      .shadow(color: isEnabled ? Brand.indigo.opacity(hovering ? 0.45 : 0.25) : .clear, radius: hovering ? 9 : 5, y: 3)
      .brightness(configuration.isPressed ? -0.06 : hovering && isEnabled ? 0.04 : 0)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.15), value: hovering)
      .onHover { hovering = $0 }
      .contentShape(Capsule())
  }
}

/// Quiet secondary actions next to the primary one.
struct SoftButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.medium))
      .foregroundStyle(isEnabled ? .primary : .tertiary)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.09 : 0.06), in: Capsule())
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
      .onHover { hovering = $0 }
      .contentShape(Capsule())
  }
}

/// A round icon-only button for the header.
struct CircleIconButtonStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(width: 30, height: 30)
      .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.09 : 0.05), in: Circle())
      .scaleEffect(configuration.isPressed ? 0.93 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
      .onHover { hovering = $0 }
      .contentShape(Circle())
  }
}

// MARK: - Inline messages

/// One line of status inside a card, with an optional trailing action.
struct InlineMessage<Accessory: View>: View {
  let text: String
  let systemImage: String
  let tint: Color
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage).foregroundStyle(tint)
      Text(text)
        .foregroundStyle(tint == .secondary ? .secondary : .primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      accessory
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

extension InlineMessage where Accessory == EmptyView {
  init(text: String, systemImage: String, tint: Color) {
    self.init(text: text, systemImage: systemImage, tint: tint) { EmptyView() }
  }
}

// MARK: - Helpers

func copyToPasteboard(_ value: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(value, forType: .string)
}

func openNetworkSettings() {
  if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension"),
     NSWorkspace.shared.open(url) {
    return
  }
  NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
}

func interfaceSymbol(_ kind: InterfaceKind) -> String {
  switch kind {
  case .wifi: "wifi"
  case .ethernet: "cable.connector.horizontal"
  case .other: "network"
  }
}
