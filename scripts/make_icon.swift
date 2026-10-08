// Renders the app icon to a 1024x1024 PNG: swift scripts/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Tile on the standard macOS icon grid: 824pt body, centered, with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.set()
NSColor.black.setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.42, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 0.55, green: 0.24, blue: 0.93, alpha: 1)])!
    .draw(in: tile, angle: -60)

// Dashed selection rectangle.
let selection = NSBezierPath(roundedRect: body.insetBy(dx: 150, dy: 150), xRadius: 36, yRadius: 36)
selection.lineWidth = 30
selection.lineCapStyle = .round
selection.setLineDash([60, 52], count: 2, phase: 0)
NSColor.white.withAlphaComponent(0.55).setStroke()
selection.stroke()

// Scissors glyph, centered.
let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = scissors.size
    scissors.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
