// Usage: swift Scripts/make_app_icon.swift <source-artwork> Cull/Assets.xcassets/AppIcon.appiconset
//
// Builds Cull's three 1024×1024 app icon variants from square artwork drawn on a flat,
// solid background (the artwork itself is kept outside the repo):
//   AppIcon.png        default: the artwork as is, opaque (App Store icons can't have alpha)
//   AppIcon-Dark.png   foreground only; the flat background becomes transparent so iOS
//                      draws its own dark backdrop behind it
//   AppIcon-Tinted.png grayscale foreground on black, which iOS recolours with the tint
//
// The background is found by flood-filling from the image border over pixels close to the
// corner colour, so dark strokes *inside* the artwork are kept. Edge pixels get partial
// alpha with the background colour removed, so there's no dark fringe in dark mode.
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: swift Scripts/make_app_icon.swift <source-artwork> <AppIcon.appiconset>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
guard let source = NSImage(contentsOf: URL(fileURLWithPath: args[1]))?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("cannot read \(args[1])")
    exit(1)
}

let size = 1024
/// Fraction of the source kept (centred), enlarging the artwork to suit the icon grid.
let cropFraction: CGFloat = 0.82
/// Colour distance (0…441) treated as fully background / fully foreground.
let backgroundTolerance: Double = 28
let foregroundDistance: Double = 70

// MARK: Load and crop to a 1024 RGBA buffer

let space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: size * size * 4)
pixels.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(size) / (CGFloat(min(source.width, source.height)) * cropFraction)
    let w = CGFloat(source.width) * scale, h = CGFloat(source.height) * scale
    ctx.draw(source, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
}

func rgb(_ i: Int) -> (Double, Double, Double) {
    (Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2]))
}

// Background colour: average of the four corner patches.
var bg = (0.0, 0.0, 0.0)
var samples = 0.0
for (cx, cy) in [(0, 0), (size - 16, 0), (0, size - 16), (size - 16, size - 16)] {
    for y in cy..<cy + 16 { for x in cx..<cx + 16 {
        let c = rgb(y * size + x)
        bg = (bg.0 + c.0, bg.1 + c.1, bg.2 + c.2)
        samples += 1
    } }
}
bg = (bg.0 / samples, bg.1 / samples, bg.2 / samples)

func distance(_ i: Int) -> Double {
    let c = rgb(i)
    return ((c.0 - bg.0) * (c.0 - bg.0) + (c.1 - bg.1) * (c.1 - bg.1) + (c.2 - bg.2) * (c.2 - bg.2)).squareRoot()
}

// MARK: Flood fill the background from the border

var alpha = [Double](repeating: 1, count: size * size)
var visited = [Bool](repeating: false, count: size * size)
var stack: [Int] = []
for i in 0..<size {
    stack += [i, (size - 1) * size + i, i * size, i * size + size - 1]
}
while let i = stack.popLast() {
    guard !visited[i] else { continue }
    visited[i] = true
    let d = distance(i)
    guard d < foregroundDistance else { continue }
    // Fully transparent near the background colour, ramping up across the anti-aliased edge.
    alpha[i] = max(0, min(1, (d - backgroundTolerance) / (foregroundDistance - backgroundTolerance)))
    let x = i % size, y = i / size
    if x > 0 { stack.append(i - 1) }
    if x < size - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - size) }
    if y < size - 1 { stack.append(i + size) }
}

// MARK: Write the variants

func write(_ name: String, opaque: Bool, _ pixel: (Int) -> (r: Double, g: Double, b: Double, a: Double)) {
    var out = [UInt8](repeating: 0, count: size * size * 4)
    for i in 0..<(size * size) {
        let p = pixel(i)
        let a = opaque ? 1 : p.a
        // Premultiplied storage.
        out[i * 4] = UInt8(max(0, min(255, p.r * a)).rounded())
        out[i * 4 + 1] = UInt8(max(0, min(255, p.g * a)).rounded())
        out[i * 4 + 2] = UInt8(max(0, min(255, p.b * a)).rounded())
        out[i * 4 + 3] = UInt8((a * 255).rounded())
    }
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let image = out.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                  space: space, bitmapInfo: info)!.makeImage()!
    }
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name)")
}

/// Foreground colour with the background's contribution removed from partially transparent edges.
func foreground(_ i: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    let a = alpha[i]
    let c = rgb(i)
    guard a > 0 else { return (0, 0, 0, 0) }
    guard a < 1 else { return (c.0, c.1, c.2, 1) }
    return ((c.0 - (1 - a) * bg.0) / a, (c.1 - (1 - a) * bg.1) / a, (c.2 - (1 - a) * bg.2) / a, a)
}

write("AppIcon.png", opaque: true) { i in
    let c = rgb(i)
    return (c.0, c.1, c.2, 1)
}
write("AppIcon-Dark.png", opaque: false, foreground)
write("AppIcon-Tinted.png", opaque: true) { i in
    let f = foreground(i)
    let luma = 0.2126 * f.r + 0.7152 * f.g + 0.0722 * f.b
    // Composite over black; iOS maps luminance to the user's tint.
    return (luma * f.a, luma * f.a, luma * f.a, 1)
}
