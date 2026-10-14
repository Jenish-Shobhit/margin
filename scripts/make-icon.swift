#!/usr/bin/env swift
// Draws Margin's app icon with CoreGraphics and packs it into an .icns with iconutil.
//
//   swift scripts/make-icon.swift [output.icns] [--png preview.png]
//
// Default output: Resources/AppIcon.icns (run from the repo root). Every size is drawn from
// vectors rather than downsampled, so the small sizes stay crisp.
//
// The picture: an indigo→violet macOS rounded square, a white simplified screen, and a neat
// stack of three thumbnail cards in the screen's right margin (the shelf).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Apple-style "continuous" rounded rect (a squircle-ish corner), approximated with the
/// well-known bezier construction used for continuous corners.
func continuousRoundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let rad = min(radius, min(r.width, r.height) / 2 / 1.52866)
    // Control-point ratios for a continuous corner (expressed as multiples of the radius).
    let a: CGFloat = 1.52866, b: CGFloat = 1.08849, c: CGFloat = 0.86840, d: CGFloat = 0.63149
    let e: CGFloat = 0.07491, f: CGFloat = 0.37282, g: CGFloat = 0.16906
    let minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY

    p.move(to: CGPoint(x: minX + a * rad, y: minY))
    // bottom edge → bottom-right corner
    p.addLine(to: CGPoint(x: maxX - a * rad, y: minY))
    p.addCurve(to: CGPoint(x: maxX - d * rad, y: minY + e * rad),
               control1: CGPoint(x: maxX - b * rad, y: minY), control2: CGPoint(x: maxX - c * rad, y: minY))
    p.addCurve(to: CGPoint(x: maxX - e * rad, y: minY + d * rad),
               control1: CGPoint(x: maxX - f * rad, y: minY + g * rad), control2: CGPoint(x: maxX - g * rad, y: minY + f * rad))
    p.addCurve(to: CGPoint(x: maxX, y: minY + a * rad),
               control1: CGPoint(x: maxX, y: minY + c * rad), control2: CGPoint(x: maxX, y: minY + b * rad))
    // right edge → top-right corner
    p.addLine(to: CGPoint(x: maxX, y: maxY - a * rad))
    p.addCurve(to: CGPoint(x: maxX - e * rad, y: maxY - d * rad),
               control1: CGPoint(x: maxX, y: maxY - b * rad), control2: CGPoint(x: maxX, y: maxY - c * rad))
    p.addCurve(to: CGPoint(x: maxX - d * rad, y: maxY - e * rad),
               control1: CGPoint(x: maxX - g * rad, y: maxY - f * rad), control2: CGPoint(x: maxX - f * rad, y: maxY - g * rad))
    p.addCurve(to: CGPoint(x: maxX - a * rad, y: maxY),
               control1: CGPoint(x: maxX - c * rad, y: maxY), control2: CGPoint(x: maxX - b * rad, y: maxY))
    // top edge → top-left corner
    p.addLine(to: CGPoint(x: minX + a * rad, y: maxY))
    p.addCurve(to: CGPoint(x: minX + d * rad, y: maxY - e * rad),
               control1: CGPoint(x: minX + b * rad, y: maxY), control2: CGPoint(x: minX + c * rad, y: maxY))
    p.addCurve(to: CGPoint(x: minX + e * rad, y: maxY - d * rad),
               control1: CGPoint(x: minX + f * rad, y: maxY - g * rad), control2: CGPoint(x: minX + g * rad, y: maxY - f * rad))
    p.addCurve(to: CGPoint(x: minX, y: maxY - a * rad),
               control1: CGPoint(x: minX, y: maxY - c * rad), control2: CGPoint(x: minX, y: maxY - b * rad))
    // left edge → bottom-left corner
    p.addLine(to: CGPoint(x: minX, y: minY + a * rad))
    p.addCurve(to: CGPoint(x: minX + e * rad, y: minY + d * rad),
               control1: CGPoint(x: minX, y: minY + b * rad), control2: CGPoint(x: minX, y: minY + c * rad))
    p.addCurve(to: CGPoint(x: minX + d * rad, y: minY + e * rad),
               control1: CGPoint(x: minX + g * rad, y: minY + f * rad), control2: CGPoint(x: minX + f * rad, y: minY + g * rad))
    p.addCurve(to: CGPoint(x: minX + a * rad, y: minY),
               control1: CGPoint(x: minX + c * rad, y: minY), control2: CGPoint(x: minX + b * rad, y: minY))
    p.closeSubpath()
    return p
}

// MARK: - Drawing (1024 × 1024 design space, origin bottom-left)

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824 pt body centred in 1024, corner radius ≈ 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = continuousRoundedRect(body, radius: 185)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x1B1060, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x5A54F0))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: indigo → violet, lighter at the top.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x8B6CFA)), (0.5, rgb(0x6A5CF4)), (1, rgb(0x4339D6))]),
        start: CGPoint(x: 240, y: 924), end: CGPoint(x: 784, y: 100), options: [])
    // Soft glow at the top-left.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFFFFFF, 0.22)), (1, rgb(0xFFFFFF, 0))]),
        startCenter: CGPoint(x: 330, y: 900), startRadius: 0,
        endCenter: CGPoint(x: 330, y: 900), endRadius: 620, options: [])
    // Slight darkening toward the bottom for depth.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x1B1060, 0.0)), (1, rgb(0x1B1060, 0.18))]),
        start: CGPoint(x: 512, y: 520), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Hairline highlight along the body's edge.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.addPath(continuousRoundedRect(body.insetBy(dx: 2, dy: 2), radius: 183))
    ctx.setLineWidth(4)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.strokePath()
    ctx.restoreGState()

    // The screen.
    let screen = CGRect(x: 196, y: 262, width: 632, height: 500)
    let screenPath = continuousRoundedRect(screen, radius: 54)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x16104A, 0.38))
    ctx.addPath(screenPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    // Very light lavender wash so the white isn't flat.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF)), (1, rgb(0xF1EFFE))]),
        start: CGPoint(x: 512, y: screen.maxY), end: CGPoint(x: 512, y: screen.minY), options: [])
    // Menu bar strip.
    ctx.setFillColor(rgb(0xE6E3FD))
    ctx.fill(CGRect(x: screen.minX, y: screen.maxY - 40, width: screen.width, height: 40))
    ctx.restoreGState()

    // A capture selection on the left: a soft tinted area framed by corner brackets.
    let sel = CGRect(x: screen.minX + 50, y: screen.minY + 68, width: 318, height: 288)
    let arm: CGFloat = 70, weight: CGFloat = 16
    ctx.saveGState()
    ctx.setFillColor(rgb(0x5A54F0, 0.10))
    ctx.fill(sel.insetBy(dx: weight / 2, dy: weight / 2))
    ctx.restoreGState()
    let corners = CGMutablePath()
    corners.move(to: CGPoint(x: sel.minX, y: sel.maxY - arm)); corners.addLine(to: CGPoint(x: sel.minX, y: sel.maxY))
    corners.addLine(to: CGPoint(x: sel.minX + arm, y: sel.maxY))
    corners.move(to: CGPoint(x: sel.maxX - arm, y: sel.maxY)); corners.addLine(to: CGPoint(x: sel.maxX, y: sel.maxY))
    corners.addLine(to: CGPoint(x: sel.maxX, y: sel.maxY - arm))
    corners.move(to: CGPoint(x: sel.maxX, y: sel.minY + arm)); corners.addLine(to: CGPoint(x: sel.maxX, y: sel.minY))
    corners.addLine(to: CGPoint(x: sel.maxX - arm, y: sel.minY))
    corners.move(to: CGPoint(x: sel.minX + arm, y: sel.minY)); corners.addLine(to: CGPoint(x: sel.minX, y: sel.minY))
    corners.addLine(to: CGPoint(x: sel.minX, y: sel.minY + arm))
    ctx.saveGState()
    ctx.addPath(corners)
    ctx.setLineWidth(weight)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0x5A54F0))
    ctx.strokePath()
    ctx.restoreGState()

    // The shelf: three thumbnail cards stacked in the right margin, newest at the bottom.
    let cardW: CGFloat = 164, cardH: CGFloat = 104, gap: CGFloat = 20
    let cardX = screen.maxX - 36 - cardW
    for i in 0..<3 {
        let y = screen.minY + 36 + CGFloat(i) * (cardH + gap)
        let card = CGRect(x: cardX, y: y, width: cardW, height: cardH)
        drawCard(card, in: ctx, age: i)
    }
}

/// One thumbnail card. `age` 0 is the newest (bottom); older cards are a touch lighter.
func drawCard(_ card: CGRect, in ctx: CGContext, age: Int) {
    let path = continuousRoundedRect(card, radius: 20)
    let fade: [CGFloat] = [1, 0.86, 0.72]

    ctx.saveGState()
    ctx.setAlpha(fade[age])
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x2A1F8F, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x5A54F0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // Sky.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x7D74FF)), (1, rgb(0x5049E8))]),
        start: CGPoint(x: card.midX, y: card.maxY), end: CGPoint(x: card.midX, y: card.minY), options: [])
    // Sun.
    ctx.setFillColor(rgb(0xFFFFFF, 0.9))
    ctx.fillEllipse(in: CGRect(x: card.maxX - 50, y: card.maxY - 44, width: 24, height: 24))
    // Hills.
    let back = CGMutablePath()
    back.move(to: CGPoint(x: card.minX, y: card.minY))
    back.addLine(to: CGPoint(x: card.minX, y: card.minY + 34))
    back.addLine(to: CGPoint(x: card.minX + 52, y: card.minY + 70))
    back.addLine(to: CGPoint(x: card.minX + 98, y: card.minY + 36))
    back.addLine(to: CGPoint(x: card.maxX, y: card.minY + 22))
    back.addLine(to: CGPoint(x: card.maxX, y: card.minY))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(rgb(0xB9B4FF, 0.9))
    ctx.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: card.minX, y: card.minY))
    front.addLine(to: CGPoint(x: card.minX, y: card.minY + 14))
    front.addLine(to: CGPoint(x: card.minX + 80, y: card.minY + 26))
    front.addLine(to: CGPoint(x: card.minX + 122, y: card.minY + 52))
    front.addLine(to: CGPoint(x: card.maxX, y: card.minY + 24))
    front.addLine(to: CGPoint(x: card.maxX, y: card.minY))
    front.closeSubpath()
    ctx.addPath(front)
    ctx.setFillColor(rgb(0xE4E1FF))
    ctx.fillPath()
    ctx.restoreGState()

    // Thin white border.
    ctx.addPath(continuousRoundedRect(card.insetBy(dx: 1.5, dy: 1.5), radius: 18.5))
    ctx.setLineWidth(3)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
    ctx.strokePath()

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - Output

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

var args = Array(CommandLine.arguments.dropFirst())
var previewURL: URL?
if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
    previewURL = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
let outputURL = URL(fileURLWithPath: args.first ?? "Resources/AppIcon.icns")

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("margin-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

for base in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let previewURL { writePNG(render(pixels: 1024), to: previewURL) }

try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed (\(iconutil.terminationStatus))") }
print("Wrote \(outputURL.path)")
