// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Renders the disk-image window background (660 × 420 pt) at a given scale.
// Usage: swift make-dmg-background.swift out.png SCALE VERSION SIGNED(0|1)
// Icon slots (Finder coordinates, top-left origin): Aether at (180, 205), Applications at (480, 205).
import AppKit

let args = CommandLine.arguments
let out = args[1]
let scale = CGFloat(Double(args[2]) ?? 1)
let version = args[3]
let signed = args[4] == "1"
let W: CGFloat = 660, H: CGFloat = 420

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()

// Background: deep blue-black with a soft mint glow behind the icons.
let bg = CGGradient(colorsSpace: rgb, colors: [CGColor(red: 0.075, green: 0.105, blue: 0.13, alpha: 1),
                                               CGColor(red: 0.03, green: 0.045, blue: 0.06, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
let glow = CGGradient(colorsSpace: rgb, colors: [CGColor(red: 0.55, green: 0.89, blue: 0.80, alpha: 0.10),
                                                 CGColor(red: 0.55, green: 0.89, blue: 0.80, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H - 205), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H - 205), endRadius: 300, options: [])

let mint = NSColor(red: 0.55, green: 0.89, blue: 0.80, alpha: 1)
let text = NSColor(red: 0.91, green: 0.94, blue: 0.95, alpha: 1)
let secondary = NSColor(red: 0.62, green: 0.68, blue: 0.72, alpha: 1)

func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, kern: CGFloat = 0, italic: Bool = false) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern,
                                                          .paragraphStyle: para])
    let h = attr.size().height
    attr.draw(in: CGRect(x: 30, y: H - y - h / 2, width: W - 60, height: h + 2))
}

// Header
draw("AETHER", size: 22, weight: .semibold, color: text, y: 48, kern: 7)
draw("IEM soundstage spatializer · version \(version)", size: 11.5, weight: .regular, color: secondary, y: 76)
draw("a project by Ambarish Mallick", size: 11, weight: .medium, color: mint.withAlphaComponent(0.9), y: 95, italic: true)

// Arrow from the app slot to the Applications slot
let y = H - 205
ctx.setStrokeColor(mint.withAlphaComponent(0.75).cgColor)
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [2, 7])
ctx.move(to: CGPoint(x: 262, y: y))
ctx.addLine(to: CGPoint(x: 392, y: y))
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])
ctx.move(to: CGPoint(x: 384, y: y + 9))
ctx.addLine(to: CGPoint(x: 396, y: y))
ctx.addLine(to: CGPoint(x: 384, y: y - 9))
ctx.strokePath()

// Footer
draw("Drag Aether onto Applications to install", size: 13, weight: .medium, color: text, y: 318)
if signed {
    draw("Then open it from Applications and press Engine On.", size: 11, weight: .regular, color: secondary, y: 345)
} else {
    draw("First launch: if macOS says it can’t verify Aether, open System Settings ›", size: 11, weight: .regular,
         color: secondary, y: 345)
    draw("Privacy & Security, scroll down and click “Open Anyway”. Needed once.", size: 11, weight: .regular,
         color: secondary, y: 362)
}
draw("Requires macOS 14.4 or later · wired IEMs recommended", size: 10, weight: .regular,
     color: secondary.withAlphaComponent(0.7), y: 396)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
