import SwiftUI

/// A MAC address as six byte tiles, the way the app icon draws it. Bytes that
/// differ from the hardware address glow in the brand gradient; while a change
/// is running the tiles dance in a wave. Click to copy.
struct ByteStrip: View {
  let address: MACAddress?
  /// The hardware address. Bytes that differ from it are highlighted.
  var reference: MACAddress?
  var dancing = false
  var size: CGFloat = 21
  var copyable = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var copied = false

  var body: some View {
    let bytes = Self.bytes(address)
    let differs = Self.differences(address, reference)
    TimelineView(.animation(minimumInterval: 1 / 60, paused: !dancing || reduceMotion)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: size * 0.28) {
        ForEach(0..<6, id: \.self) { index in
          ByteTile(text: bytes[index], highlighted: differs[index], size: size)
            .offset(y: dancing && !reduceMotion ? -abs(sin(time * 5.2 - Double(index) * 0.55)) * size * 0.32 : 0)
            .opacity(dancing && reduceMotion ? 0.55 : 1)
        }
      }
    }
    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: address)
    .animation(.easeOut(duration: 0.25), value: dancing)
    .overlay(alignment: .trailing) {
      if copied {
        Label(L("bytes.copied", "Copied"), systemImage: "checkmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Brand.mintInk, in: Capsule())
          .offset(x: 74)
          .transition(.scale(scale: 0.7).combined(with: .opacity))
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      guard copyable, let address else { return }
      copyToPasteboard(address.stringValue)
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation(.easeOut(duration: 0.25)) { copied = false }
      }
    }
    .help(copyable ? L("bytes.copy_help", "Click to copy") : "")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(macText(address))
  }

  static func bytes(_ address: MACAddress?) -> [String] {
    guard let address else { return Array(repeating: "––", count: 6) }
    let parts = address.stringValue.split(separator: ":").map(String.init)
    return parts.count == 6 ? parts : Array(repeating: "––", count: 6)
  }

  static func differences(_ address: MACAddress?, _ reference: MACAddress?) -> [Bool] {
    guard let address, let reference else { return Array(repeating: false, count: 6) }
    let a = bytes(address), b = bytes(reference)
    return (0..<6).map { a[$0] != b[$0] }
  }
}

private struct ByteTile: View {
  let text: String
  let highlighted: Bool
  let size: CGFloat

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: size, weight: .semibold, design: .monospaced))
      .contentTransition(.numericText())
      .foregroundStyle(highlighted ? .white : .primary)
      .frame(width: size * 2.05, height: size * 1.9)
      .background {
        RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
          .fill(highlighted ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.065)))
          .shadow(color: highlighted ? Brand.indigo.opacity(0.28) : .clear, radius: 5, y: 2)
      }
  }
}
