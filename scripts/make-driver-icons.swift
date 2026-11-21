// Draws the device icons bundled in the driver (Driver/Icons/<name>.icns), which apps such as Audio MIDI Setup show
// for a virtual device (kAudioDevicePropertyIcon). Plain Core Graphics shapes, no fonts or symbol sets; "junction"
// is the app icon. Run from the repository root after changing a drawing or the app icon:
//
//   xcrun swift scripts/make-driver-icons.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: "Driver/Icons", isDirectory: true)
let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.temporaryDirectory
let work = temporary.appendingPathComponent("junction-icons-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

/// Sizes in each icon: (points, scale), and the .icns type code of each (points × 10 + scale).
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2)]
let types: [Int: String] = [161: "icp4", 162: "ic11", 321: "icp5", 322: "ic12", 1281: "ic07", 1282: "ic13", 2561: "ic08",
                            2562: "ic14"]

/// Draws on a 100 × 100 canvas (origin bottom left) in white on a tinted rounded square.
func render(_ pixels: Int, tint: (CGFloat, CGFloat, CGFloat), glyph: (CGContext) -> Void) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 100, y: CGFloat(pixels) / 100)
    let square = CGPath(roundedRect: CGRect(x: 6, y: 6, width: 88, height: 88), cornerWidth: 20, cornerHeight: 20, transform: nil)
    context.addPath(square)
    context.clip()
    let top = CGColor(srgbRed: tint.0, green: tint.1, blue: tint.2, alpha: 1)
    let bottom = CGColor(srgbRed: tint.0 * 0.72, green: tint.1 * 0.72, blue: tint.2 * 0.72, alpha: 1)
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 50, y: 94), end: CGPoint(x: 50, y: 6), options: [])
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    glyph(context)
    return context.makeImage()!
}

func microphone(_ c: CGContext) {
    c.addPath(CGPath(roundedRect: CGRect(x: 40, y: 42, width: 20, height: 36), cornerWidth: 10, cornerHeight: 10, transform: nil))
    c.fillPath()
    c.setLineWidth(5)
    c.addArc(center: CGPoint(x: 50, y: 56), radius: 17, startAngle: .pi * 1.05, endAngle: .pi * 1.95, clockwise: false)
    c.strokePath()
    c.move(to: CGPoint(x: 50, y: 39))
    c.addLine(to: CGPoint(x: 50, y: 26))
    c.move(to: CGPoint(x: 40, y: 24))
    c.addLine(to: CGPoint(x: 60, y: 24))
    c.strokePath()
}

func speaker(_ c: CGContext) {
    c.move(to: CGPoint(x: 22, y: 40))
    c.addLine(to: CGPoint(x: 34, y: 40))
    c.addLine(to: CGPoint(x: 50, y: 26))
    c.addLine(to: CGPoint(x: 50, y: 74))
    c.addLine(to: CGPoint(x: 34, y: 60))
    c.addLine(to: CGPoint(x: 22, y: 60))
    c.closePath()
    c.fillPath()
    c.setLineWidth(5)
    for radius in [12.0, 22.0] {
        c.addArc(center: CGPoint(x: 52, y: 50), radius: radius, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
        c.strokePath()
    }
}

func headphones(_ c: CGContext) {
    c.setLineWidth(6)
    c.addArc(center: CGPoint(x: 50, y: 48), radius: 26, startAngle: .pi * 1.0, endAngle: 0, clockwise: true)
    c.strokePath()
    for x in [20.0, 66.0] {
        c.addPath(CGPath(roundedRect: CGRect(x: x, y: 24, width: 14, height: 26), cornerWidth: 6, cornerHeight: 6, transform: nil))
    }
    c.fillPath()
}

func stream(_ c: CGContext) {
    c.fillEllipse(in: CGRect(x: 42, y: 42, width: 16, height: 16))
    c.setLineWidth(5)
    for radius in [17.0, 29.0] {
        for (start, end) in [(-CGFloat.pi / 4, CGFloat.pi / 4), (CGFloat.pi * 3 / 4, CGFloat.pi * 5 / 4)] {
            c.addArc(center: CGPoint(x: 50, y: 50), radius: radius, startAngle: start, endAngle: end, clockwise: false)
            c.strokePath()
        }
    }
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// Writes an .icns file: the "icns" header, then one PNG per size under its type code.
func makeIcns(_ name: String, image: (Int) -> URL) {
    var body = Data()
    for (points, scale) in sizes {
        let png = try! Data(contentsOf: image(points * scale))
        body.append(Data(types[points * 10 + scale]!.utf8))
        body.append(bigEndian(UInt32(8 + png.count)))
        body.append(png)
    }
    var file = Data("icns".utf8)
    file.append(bigEndian(UInt32(8 + body.count)))
    file.append(body)
    try! file.write(to: output.appendingPathComponent("\(name).icns"))
}

func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

let glyphs: [(String, (CGFloat, CGFloat, CGFloat), (CGContext) -> Void)] = [
    ("microphone", (0.93, 0.36, 0.33), microphone),
    ("speaker", (0.27, 0.55, 0.93), speaker),
    ("headphones", (0.55, 0.40, 0.88), headphones),
    ("stream", (0.20, 0.70, 0.52), stream),
]
for (name, tint, glyph) in glyphs {
    makeIcns(name) { pixels in
        let url = work.appendingPathComponent("\(name)-\(pixels).png")
        write(render(pixels, tint: tint, glyph: glyph), to: url)
        return url
    }
}
// The default icon is the app's, scaled down.
let appIcon = CGImageSourceCreateImageAtIndex(
    CGImageSourceCreateWithURL(URL(fileURLWithPath: "Resources/AppIcon-1024.png") as CFURL, nil)!, 0, nil)!
makeIcns("junction") { pixels in
    let url = work.appendingPathComponent("junction-\(pixels).png")
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(appIcon, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    write(context.makeImage()!, to: url)
    return url
}
print("Wrote \(glyphs.count + 1) icons to \(output.path)")
