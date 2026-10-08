// Rasterize an SVG to PNG with AppKit (macOS 14+ loads SVG natively).
// usage: swift render.swift in.svg out.png <pixelsWide> [opaque]
import AppKit
let a = CommandLine.arguments
guard a.count >= 4, let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else {
    FileHandle.standardError.write("cannot load \(a.count > 1 ? a[1] : "")\n".data(using: .utf8)!); exit(1)
}
let opaque = a.count > 4 && a[4] == "opaque"
let w = Int(a[3])!
let h = Int((Double(w) * img.size.height / img.size.width).rounded())
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
if opaque { ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.current = nil
let cg = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: cg)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
