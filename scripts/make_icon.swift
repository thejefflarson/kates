#!/usr/bin/env swift
import AppKit

// Renders the Kates app icon: a stylized 7-spoke Kubernetes helm on a blue
// squircle. Outputs a 1024×1024 PNG that bundle.sh expands into an .icns.

let size = 1024.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background squircle with a vertical blue gradient (Kubernetes blue).
let inset = 48.0
let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 215, yRadius: 215)
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.22, green: 0.47, blue: 0.95, alpha: 1),   // #386FF2-ish
    ending: NSColor(srgbRed: 0.13, green: 0.30, blue: 0.78, alpha: 1))!
gradient.draw(in: bg, angle: -90)

// Helm geometry.
let center = NSPoint(x: size / 2, y: size / 2)
let outerR = 312.0
let white = NSColor.white

func point(_ i: Int, radius: Double) -> NSPoint {
    let angle = -Double.pi / 2 + Double(i) * (2 * .pi / 7)   // 7 spokes, point up
    return NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
}

// Outer heptagon ring.
white.setStroke()
let ring = NSBezierPath()
ring.lineWidth = 40
ring.lineJoinStyle = .round
for i in 0..<7 {
    let p = point(i, radius: outerR)
    if i == 0 { ring.move(to: p) } else { ring.line(to: p) }
}
ring.close()
ring.stroke()

// Spokes from hub to each vertex.
white.setStroke()
for i in 0..<7 {
    let spoke = NSBezierPath()
    spoke.lineWidth = 30
    spoke.lineCapStyle = .round
    spoke.move(to: center)
    spoke.line(to: point(i, radius: outerR - 6))
    spoke.stroke()
}

// "Sail" caps at each vertex.
white.setFill()
for i in 0..<7 {
    let p = point(i, radius: outerR)
    let r = 46.0
    NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
}

// Center hub: small filled heptagon.
let hub = NSBezierPath()
for i in 0..<7 {
    let p = point(i, radius: 96)
    if i == 0 { hub.move(to: p) } else { hub.line(to: p) }
}
hub.close()
white.setFill()
hub.fill()

NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png")
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: outURL)
print("wrote \(outURL.path)")
