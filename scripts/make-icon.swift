// Renders packaging/AppIcon.icns: a charcoal squircle with the amber
// "island" pill (dark notch cutout on top) and two ink text lines, in the
// AskDroid palette from DESIGN.md. Pure CoreGraphics, no window server.
//
// Usage: swift scripts/make-icon.swift
import AppKit
import Foundation

let palette = (
    background: (r: 0.07, g: 0.07, b: 0.075, a: 1.0),   // #121213 panelFill
    pill: (r: 250.0 / 255.0, g: 158.0 / 255.0, b: 46.0 / 255.0, a: 1.0), // #FA9E2E accent
    ink: (r: 1.0, g: 1.0, b: 1.0, a: 0.92)              // white @ 92%
)

func color(_ c: (r: Double, g: Double, b: Double, a: Double)) -> CGColor {
    CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Background squircle, full bleed.
    let corner = s * 0.229
    ctx.setFillColor(color(palette.background))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                       cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.fillPath()

    // Island pill, centered a touch above middle.
    let pillW = s * 0.508
    let pillH = s * 0.273
    let pillRect = CGRect(x: (s - pillW) / 2, y: s * 0.5, width: pillW, height: pillH)
    ctx.setFillColor(color(palette.pill))
    ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillH / 2,
                       cornerHeight: pillH / 2, transform: nil))
    ctx.fillPath()

    // Dark notch cutout where the lens sits (a clipped ellipse on the top edge).
    ctx.saveGState()
    ctx.setFillColor(color(palette.background))
    ctx.addEllipse(in: CGRect(x: pillRect.midX - s * 0.117, y: pillRect.maxY - s * 0.028,
                              width: s * 0.234, height: s * 0.102))
    ctx.fillPath()
    ctx.restoreGState()

    // Two ink text lines below, like a settled answer.
    let lineY1 = s * 0.565
    let lineY2 = s * 0.565 + s * 0.062
    ctx.setFillColor(color(palette.ink))
    for (lineY, lineW) in [(lineY1, s * 0.352), (lineY2, s * 0.234)] {
        let h = s * 0.025
        ctx.addPath(CGPath(roundedRect: CGRect(x: (s - lineW) / 2, y: lineY,
                                               width: lineW, height: h),
                           cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: "\(#filePath)")
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let rep = NSBitmapImageRep(cgImage: drawIcon(size: 1024))
let png = rep.representation(using: .png, properties: [:])!

for variant in variants {
    let scaled = NSImage(size: NSSize(width: variant.size, height: variant.size))
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: variant.size, height: variant.size))
    scaled.unlockFocus()
    let tiff = scaled.tiffRepresentation!
    let bitmap = NSBitmapImageRep(data: tiff)!
    let bytes = bitmap.representation(using: .png, properties: [:])!
    try bytes.write(to: iconset.appendingPathComponent(variant.name))
}

let icns = root.appendingPathComponent("packaging/AppIcon.icns")
try? fm.removeItem(at: icns)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
try? fm.removeItem(at: iconset)

print("Wrote \(icns.path)")