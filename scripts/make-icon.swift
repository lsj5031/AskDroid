// Packs packaging/AppIcon.icns from packaging/AppIcon-source.jpg (Imagine master).
// Flood-fills the white studio backdrop from the corners so the tile is
// full-bleed (Finder applies the macOS squircle). Also writes
// packaging/AppIcon.png and docs/icon.png (transparent corners for README).
//
// Usage: swift scripts/make-icon.swift
import AppKit
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: "\(#filePath)")
    .deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("packaging/AppIcon-source.jpg")
let masterURL = root.appendingPathComponent("packaging/AppIcon.png")
let readmeURL = root.appendingPathComponent("docs/icon.png")
let icnsURL = root.appendingPathComponent("packaging/AppIcon.icns")

guard let sourceImage = NSImage(contentsOf: sourceURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("missing \(sourceURL.path)\n", stderr)
    exit(1)
}

let width = sourceImage.width
let height = sourceImage.height
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func makeBuffer() -> (ctx: CGContext, ptr: UnsafeMutablePointer<UInt8>, stride: Int) {
    let stride = width * 4
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: stride, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .none
    ctx.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (ctx, ctx.data!.assumingMemoryBound(to: UInt8.self), stride)
}

func luma(_ p: UnsafeMutablePointer<UInt8>, _ i: Int) -> Int {
    // Rec. 709, integer.
    (2126 * Int(p[i]) + 7152 * Int(p[i + 1]) + 722 * Int(p[i + 2])) / 10000
}

func floodFill(ptr: UnsafeMutablePointer<UInt8>, stride: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let threshold = 158 // ~0.62 * 255
    var seen = [UInt8](repeating: 0, count: width * height)
    var qx = [Int]()
    var qy = [Int]()
    qx.reserveCapacity(width * 4)
    qy.reserveCapacity(height * 4)
    func push(_ x: Int, _ y: Int) {
        let idx = y * width + x
        if seen[idx] == 1 { return }
        seen[idx] = 1
        qx.append(x)
        qy.append(y)
    }
    push(0, 0)
    push(width - 1, 0)
    push(0, height - 1)
    push(width - 1, height - 1)
    var head = 0
    while head < qx.count {
        let x = qx[head], y = qy[head]
        head += 1
        let i = y * stride + x * 4
        if luma(ptr, i) <= threshold { continue }
        ptr[i] = r
        ptr[i + 1] = g
        ptr[i + 2] = b
        ptr[i + 3] = a
        if x > 0 { push(x - 1, y) }
        if x + 1 < width { push(x + 1, y) }
        if y > 0 { push(x, y - 1) }
        if y + 1 < height { push(x, y + 1) }
    }
}

func png(from ctx: CGContext, url: URL) throws {
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("failed to write \(url.path)\n", stderr)
        exit(1)
    }
}

func scale(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// Sample the tile fill just inside the top edge, center.
let sample = makeBuffer()
let midTop = 80 * sample.stride + (width / 2) * 4
let tileR = sample.ptr[midTop]
let tileG = sample.ptr[midTop + 1]
let tileB = sample.ptr[midTop + 2]

let opaque = makeBuffer()
floodFill(ptr: opaque.ptr, stride: opaque.stride, r: tileR, g: tileG, b: tileB, a: 255)
try png(from: opaque.ctx, url: masterURL)

let clear = makeBuffer()
floodFill(ptr: clear.ptr, stride: clear.stride, r: 0, g: 0, b: 0, a: 0)
try png(from: clear.ctx, url: readmeURL)

guard let masterImage = opaque.ctx.makeImage() else {
    fputs("failed to make master CGImage\n", stderr)
    exit(1)
}

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
for variant in variants {
    let dest = CGImageDestinationCreateWithURL(
        iconset.appendingPathComponent(variant.name) as CFURL,
        "public.png" as CFString, 1, nil
    )!
    CGImageDestinationAddImage(dest, scale(masterImage, to: variant.size), nil)
    CGImageDestinationFinalize(dest)
}

try? fm.removeItem(at: icnsURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(process.terminationStatus)
}
try? fm.removeItem(at: iconset)

print("Wrote \(masterURL.path)")
print("Wrote \(readmeURL.path)")
print("Wrote \(icnsURL.path)")
