import AppKit
import CoreGraphics

// MACDancer icon: six "byte" capsules dancing on a blue-violet squircle.
let size: CGFloat = 1024
// sRGB on purpose: a Display P3 image makes the asset catalog store every size twice.
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}

/// Apple-style continuous corner (superellipse) inside rect.
func squircle(_ rect: CGRect, n: CGFloat = 5.0) -> CGPath {
  let path = CGMutablePath()
  let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
  for i in 0...720 {
    let t = CGFloat(i) / 720 * 2 * .pi
    let c = cos(t), s = sin(t)
    let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
    let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
  }
  path.closeSubpath()
  return path
}

// macOS icon grid: 824 pt body centred in 1024, room for the drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x0A0A2A, 0.30))
ctx.addPath(shape); ctx.setFillColor(color(0x4A55F0)); ctx.fillPath()
ctx.restoreGState()

// Background gradient: bright blue (top-left) to violet (bottom-right).
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0x3D8BFF), color(0x5B5BF6), color(0x8B3FE8)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 140, y: 924), end: CGPoint(x: 884, y: 100), options: [])
// Soft light from the top.
let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 380, y: 900), startRadius: 0, endCenter: CGPoint(x: 380, y: 900), endRadius: 620, options: [])
// Deeper floor.
let floor = CGGradient(colorsSpace: cs, colors: [color(0x1A0E5C, 0), color(0x1A0E5C, 0.28)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(floor, start: CGPoint(x: 512, y: 520), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Hairline inner border for definition on dark docks.
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.addPath(shape); ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

// Six capsules = six bytes of a MAC address, in a dance wave.
let width: CGFloat = 72, gap: CGFloat = 46
let heights: [CGFloat] = [240, 400, 540, 450, 320, 210]
let lifts: [CGFloat] = [-24, 14, 26, -12, 20, -6]   // vertical offsets: off-beat, not a flat bar chart
let tilts: [CGFloat] = [-9, -6, -10, -7, -11, -8]   // degrees: all lean together, like a beat
let accentIndex = 3
let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
var x = 512 - total / 2
for (index, height) in heights.enumerated() {
  let centre = CGPoint(x: x + width / 2, y: 500 + lifts[index])
  ctx.saveGState()
  ctx.translateBy(x: centre.x, y: centre.y)
  ctx.rotate(by: tilts[index] * .pi / 180)
  let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
  let capsule = CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x160A50, 0.30))
  ctx.addPath(capsule)
  ctx.setFillColor(index == accentIndex ? color(0x5FF5C8) : color(0xFFFFFF))
  ctx.fillPath()
  ctx.setShadow(offset: .zero, blur: 0, color: nil)
  // Subtle top-to-bottom shading inside each capsule.
  ctx.addPath(capsule); ctx.clip()
  let shade = CGGradient(colorsSpace: cs,
    colors: (index == accentIndex ? [color(0xB4FFE9, 0.55), color(0x1FC9A0, 0.35)] : [color(0xFFFFFF, 0), color(0xC9D2FF, 0.55)]) as CFArray,
    locations: [0, 1])!
  ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: height / 2), end: CGPoint(x: 0, y: -height / 2), options: [])
  ctx.restoreGState()
  x += width + gap
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
