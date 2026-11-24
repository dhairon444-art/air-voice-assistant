// Renders Myra's app icon (squircle gradient + sound-wave bars) to a 1024px PNG.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.current!.restoreGraphicsState()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1),  // cyan
    NSColor(srgbRed: 0.49, green: 0.36, blue: 1.00, alpha: 1),  // violet
    NSColor(srgbRed: 0.96, green: 0.45, blue: 0.71, alpha: 1),  // pink
])!
gradient.draw(in: shape, angle: -55)
// Sound-wave bars
let heights: [CGFloat] = [150, 290, 430, 560, 430, 290, 150]
let barW: CGFloat = 52, gap: CGFloat = 34
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (size - total) / 2
NSColor.white.withAlphaComponent(0.95).setFill()
for h in heights {
    NSBezierPath(roundedRect: NSRect(x: x, y: (size - h) / 2, width: barW, height: h), xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
