// Generates the web UI icons: swift scripts/make-web-icons.swift web/public/icons
import AppKit

// Brand mark: a rounded square split diagonally, orange over graphite (see .brand-mark in app.css).
let orange = CGColor(srgbRed: 0xE5/255, green: 0x70/255, blue: 0, alpha: 1)
let graphite = CGColor(srgbRed: 0x2B/255, green: 0x2F/255, blue: 0x36/255, alpha: 1)

/// `markScale`: mark size relative to the canvas; `fullBleed`: square corners filling the canvas, for
/// platforms that crop icons to their own shape.
func render(_ size: Int, markScale: CGFloat, fullBleed: Bool, to path: String) {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let side = s * markScale
    let rect = CGRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side)
    let corner = fullBleed ? 0 : side * 0.22
    let shape = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(shape); ctx.clip()
    ctx.setFillColor(graphite); ctx.fill(rect)
    // Top-left triangle (CoreGraphics origin is bottom-left).
    ctx.setFillColor(orange)
    ctx.move(to: CGPoint(x: rect.minX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); ctx.closePath(); ctx.fillPath()
    // Light separator between the halves.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(side * 0.045)
    ctx.move(to: CGPoint(x: rect.minX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); ctx.strokePath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
render(192, markScale: 0.92, fullBleed: false, to: "\(out)/icon-192.png")
render(512, markScale: 0.92, fullBleed: false, to: "\(out)/icon-512.png")
// Maskable: launchers crop to their own shape; any crop of the split still reads as the mark.
render(512, markScale: 1, fullBleed: true, to: "\(out)/icon-maskable-512.png")
// iOS rounds the corners itself and shows transparency as black.
render(180, markScale: 1, fullBleed: true, to: "\(out)/apple-touch-icon.png")
render(32, markScale: 0.94, fullBleed: false, to: "\(out)/favicon-32.png")
