#!/usr/bin/env swift
// Renders Resources/Compagnion.icns: the app's asterisk motif in white on a
// blue squircle, matching Theme.Colors.primary and the menu-bar glyph.
//
//     swift Resources/make-icon.swift
//
// Run from the repo root; writes Compagnion.icns next to this file.

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent()
let iconsetDirectory = outputDirectory.appendingPathComponent("Compagnion.iconset")
let icnsURL = outputDirectory.appendingPathComponent("Compagnion.icns")

// MARK: - Geometry

/// Apple's icon grid: the rounded shape covers 824 of a 1024 pt canvas, with
/// the remaining margin reserved for the drop shadow.
let contentRatio: CGFloat = 824.0 / 1024.0
/// Exponent of the superellipse |x|^n + |y|^n = 1. n = 6 is the closest simple
/// fit to the continuous-corner squircle macOS uses.
let squircleExponent: CGFloat = 6

func squirclePath(in rect: CGRect, samples: Int = 1440) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let power = 2 / squircleExponent

    for step in 0..<samples {
        let t = 2 * CGFloat.pi * CGFloat(step) / CGFloat(samples)
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: cx + a * (c < 0 ? -1 : 1) * pow(abs(c), power),
            y: cy + b * (s < 0 ? -1 : 1) * pow(abs(s), power)
        )
        if step == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

// MARK: - Drawing

// Theme.Colors.primary (#0058BC) lightened at the top so the face reads as a
// lit surface rather than a flat fill.
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.47, blue: 0.93, alpha: 1),
    NSColor(srgbRed: 0.00, green: 0.28, blue: 0.68, alpha: 1),
])!

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current else { return image }
    context.imageInterpolation = .high

    let scale = size / 1024
    let side = size * contentRatio
    let content = CGRect(
        x: (size - side) / 2,
        y: (size - side) / 2,
        width: side,
        height: side
    )
    let shape = squirclePath(in: content)

    // Ambient shadow, sized off the canvas margin so it never clips.
    context.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    context.restoreGraphicsState()

    context.saveGraphicsState()
    shape.addClip()
    gradient.draw(in: content, angle: -90)

    // Specular sheen across the upper half.
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    sheen.draw(
        in: CGRect(x: content.minX, y: content.midY, width: content.width, height: content.height / 2),
        angle: -90
    )
    context.restoreGraphicsState()

    // Inner hairline: keeps the edge crisp against a light desktop.
    context.saveGraphicsState()
    NSColor.white.withAlphaComponent(0.18).setStroke()
    shape.lineWidth = 2 * scale
    shape.stroke()
    context.restoreGraphicsState()

    drawAsterisk(in: content, scale: scale)
    return image
}

/// The same `asterisk` SF Symbol the menu-bar item uses, so the Dock icon and
/// the status item read as one mark.
func drawAsterisk(in content: CGRect, scale: CGFloat) {
    let glyphBox = content.insetBy(dx: content.width * 0.24, dy: content.height * 0.24)
    let configuration = NSImage.SymbolConfiguration(
        pointSize: glyphBox.height,
        weight: .medium
    )
    guard let symbol = NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return }

    let aspect = symbol.size.width / symbol.size.height
    let height = glyphBox.height
    let width = height * aspect
    let target = CGRect(
        x: content.midX - width / 2,
        y: content.midY - height / 2,
        width: width,
        height: height
    )

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 10 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -4 * scale)
    shadow.set()

    let tinted = NSImage(size: target.size)
    tinted.lockFocus()
    symbol.draw(in: CGRect(origin: .zero, size: target.size))
    NSColor(srgbRed: 0.988, green: 0.976, blue: 0.973, alpha: 1).set()  // Theme surface
    CGRect(origin: .zero, size: target.size).fill(using: .sourceAtop)
    tinted.unlockFocus()

    tinted.draw(in: target)
    NSGraphicsContext.current?.restoreGraphicsState()
}

// MARK: - Emit

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("cannot allocate \(pixels)px bitmap") }
    representation.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(pixels)px PNG")
    }
    try data.write(to: url)
}

try? FileManager.default.removeItem(at: iconsetDirectory)
try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

// iconutil expects exactly these names.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    // Draw at the target size rather than downsampling one master: the
    // asterisk keeps its stroke weight at 16 pt that way.
    let image = drawIcon(size: CGFloat(variant.pixels))
    try writePNG(image, pixels: variant.pixels, to: iconsetDirectory.appendingPathComponent(variant.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDirectory.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

try FileManager.default.removeItem(at: iconsetDirectory)
print("Wrote \(icnsURL.path)")
