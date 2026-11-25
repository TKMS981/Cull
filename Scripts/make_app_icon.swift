// Usage: swift Scripts/make_app_icon.swift Cull/Assets.xcassets/AppIcon.appiconset
// Draws Cull's app icon (light, dark, tinted) at 1024×1024.
import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024

func render(_ name: String, background: [CGColor]?, card: CGColor, back: CGColor, mark: CGColor) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background {
        let gradient = CGGradient(colorsSpace: space, colors: background as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    }
    func drawCard(angle: CGFloat, dx: CGFloat, color: CGColor, shadow: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: size / 2 + dx, y: size / 2)
        ctx.rotate(by: angle * .pi / 180)
        let rect = CGRect(x: -230, y: -310, width: 460, height: 620)
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(gray: 0, alpha: 0.35)) }
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 70, cornerHeight: 70, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }
    drawCard(angle: 12, dx: 90, color: back, shadow: false)
    drawCard(angle: -8, dx: -40, color: card, shadow: true)
    // checkmark on front card
    ctx.saveGState()
    ctx.translateBy(x: size / 2 - 40, y: size / 2)
    ctx.rotate(by: -8 * .pi / 180)
    ctx.setStrokeColor(mark)
    ctx.setLineWidth(70)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: -120, y: 0))
    ctx.addLine(to: CGPoint(x: -30, y: -95))
    ctx.addLine(to: CGPoint(x: 135, y: 110))
    ctx.strokePath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

let teal = CGColor(srgbRed: 0.10, green: 0.72, blue: 0.62, alpha: 1)
let indigo = CGColor(srgbRed: 0.25, green: 0.28, blue: 0.85, alpha: 1)
let green = CGColor(srgbRed: 0.16, green: 0.72, blue: 0.36, alpha: 1)
render("AppIcon.png", background: [teal, indigo], card: .white, back: CGColor(gray: 1, alpha: 0.45), mark: green)
render("AppIcon-Dark.png", background: nil, card: CGColor(gray: 0.18, alpha: 1), back: CGColor(srgbRed: 0.10, green: 0.72, blue: 0.62, alpha: 0.55), mark: CGColor(srgbRed: 0.25, green: 0.85, blue: 0.5, alpha: 1))
render("AppIcon-Tinted.png", background: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1)], card: CGColor(gray: 0.95, alpha: 1), back: CGColor(gray: 0.5, alpha: 1), mark: CGColor(gray: 0.2, alpha: 1))
