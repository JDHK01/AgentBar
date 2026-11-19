import AppKit
import Foundation

let iconsetPath = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
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
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    let pad = s * 0.095
    let cardRect = NSRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = cardRect.width * 0.225
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)

    let bgGrad = NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.22, blue: 0.44, alpha: 1.0),
        NSColor(srgbRed: 0.19, green: 0.34, blue: 0.66, alpha: 1.0),
        NSColor(srgbRed: 0.36, green: 0.24, blue: 0.60, alpha: 1.0)
    ])!
    bgGrad.draw(in: cardPath, angle: -55)

    NSColor.white.withAlphaComponent(0.32).setStroke()
    cardPath.lineWidth = max(1.0, s * 0.012)
    cardPath.stroke()

    // Inner glass terminal frame
    let termW = cardRect.width * 0.64
    let termH = cardRect.height * 0.46
    let termRect = NSRect(
        x: cardRect.midX - termW / 2,
        y: cardRect.midY - termH * 0.30,
        width: termW,
        height: termH
    )
    let termPath = NSBezierPath(roundedRect: termRect, xRadius: termW * 0.16, yRadius: termW * 0.16)
    NSColor.white.withAlphaComponent(0.16).setFill()
    termPath.fill()
    NSColor.white.withAlphaComponent(0.92).setStroke()
    termPath.lineWidth = max(1.5, s * 0.038)
    termPath.stroke()

    // Prompt chevron >_
    let chev = NSBezierPath()
    chev.move(to: NSPoint(x: termRect.minX + termW * 0.22, y: termRect.maxY - termH * 0.28))
    chev.line(to: NSPoint(x: termRect.minX + termW * 0.40, y: termRect.midY))
    chev.line(to: NSPoint(x: termRect.minX + termW * 0.22, y: termRect.minY + termH * 0.28))
    chev.lineWidth = max(1.5, s * 0.042)
    chev.lineCapStyle = .round
    chev.lineJoinStyle = .round
    NSColor.white.setStroke()
    chev.stroke()

    let under = NSBezierPath()
    under.move(to: NSPoint(x: termRect.minX + termW * 0.50, y: termRect.minY + termH * 0.28))
    under.line(to: NSPoint(x: termRect.maxX - termW * 0.20, y: termRect.minY + termH * 0.28))
    under.lineWidth = max(1.5, s * 0.042)
    under.lineCapStyle = .round
    under.stroke()

    // Four status dots row at bottom
    let dotColors: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0),
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1.0),
        NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1.0),
        NSColor(srgbRed: 0.16, green: 0.62, blue: 1.0, alpha: 1.0)
    ]
    let dotD = cardRect.width * 0.095
    let spacing = cardRect.width * 0.055
    let totalDotsW = CGFloat(dotColors.count) * dotD + CGFloat(dotColors.count - 1) * spacing
    var dx = cardRect.midX - totalDotsW / 2
    let dy = cardRect.minY + cardRect.height * 0.13
    for c in dotColors {
        let p = NSBezierPath(ovalIn: NSRect(x: dx, y: dy, width: dotD, height: dotD))
        c.setFill()
        p.fill()
        NSColor.white.withAlphaComponent(0.75).setStroke()
        p.lineWidth = max(0.8, s * 0.008)
        p.stroke()
        dx += dotD + spacing
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    let png = renderIcon(pixels: px)
    try png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(filename)"))
}
