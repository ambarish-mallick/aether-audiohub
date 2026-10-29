// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Renders Aether's 1024×1024 app icon: two virtual speakers and a listener on a
// deep blue-black tile with the mint accent. Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [CGColor(red: 0.07, green: 0.10, blue: 0.13, alpha: 1),
                             CGColor(red: 0.02, green: 0.03, blue: 0.045, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let mint = CGColor(red: 0.55, green: 0.89, blue: 0.80, alpha: 1)
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [CGColor(red: 0.55, green: 0.89, blue: 0.80, alpha: 0.28),
                               CGColor(red: 0.55, green: 0.89, blue: 0.80, alpha: 0)] as CFArray,
                      locations: [0, 1])!
let listener = CGPoint(x: 512, y: 390)
ctx.drawRadialGradient(glow, startCenter: listener, startRadius: 0, endCenter: listener, endRadius: 420, options: [])

// Guide rings
ctx.setLineWidth(5)
for (r, a) in [(170.0, 0.18), (300.0, 0.12)] {
    ctx.setStrokeColor(mint.copy(alpha: a)!)
    ctx.strokeEllipse(in: CGRect(x: listener.x - r, y: listener.y - r, width: 2 * r, height: 2 * r))
}
// Arc through the speakers
let rs: CGFloat = 300
ctx.setStrokeColor(mint.copy(alpha: 0.75)!)
ctx.setLineWidth(12)
ctx.setLineCap(.round)
ctx.addArc(center: listener, radius: rs, startAngle: .pi / 2 + 0.72, endAngle: .pi / 2 - 0.72, clockwise: true)
ctx.strokePath()
// Speakers at ±30°
for side in [-1.0, 1.0] {
    let a = CGFloat(side) * .pi / 6
    let p = CGPoint(x: listener.x + rs * sin(a), y: listener.y + rs * cos(a))
    ctx.drawRadialGradient(glow, startCenter: p, startRadius: 0, endCenter: p, endRadius: 120, options: [])
    ctx.setFillColor(CGColor(red: 0.08, green: 0.11, blue: 0.13, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: p.x - 58, y: p.y - 58, width: 116, height: 116))
    ctx.setStrokeColor(mint)
    ctx.setLineWidth(10)
    ctx.strokeEllipse(in: CGRect(x: p.x - 58, y: p.y - 58, width: 116, height: 116))
    ctx.setFillColor(mint)
    ctx.fillEllipse(in: CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48))
    // dashed path to the listener
    ctx.setStrokeColor(mint.copy(alpha: 0.55)!)
    ctx.setLineWidth(7)
    ctx.setLineDash(phase: 0, lengths: [18, 16])
    ctx.move(to: CGPoint(x: p.x - CGFloat(side) * 30, y: p.y - 52))
    ctx.addLine(to: CGPoint(x: listener.x + CGFloat(side) * 70, y: listener.y + 20))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
}
// Listener
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
ctx.setLineWidth(8)
ctx.strokeEllipse(in: CGRect(x: listener.x - 78, y: listener.y - 78, width: 156, height: 156))
ctx.setFillColor(mint)
ctx.fillEllipse(in: CGRect(x: listener.x - 30, y: listener.y - 6, width: 60, height: 60))
ctx.addPath(CGPath(roundedRect: CGRect(x: listener.x - 52, y: listener.y - 56, width: 104, height: 56),
                   cornerWidth: 28, cornerHeight: 28, transform: nil))
ctx.fillPath()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
