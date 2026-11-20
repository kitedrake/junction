// Draws the Junction app icon (1024×1024 PNG): three nodes joined by two cables, on a violet-to-pink rounded
// square. Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// macOS icon grid: the shape is inset from the canvas and has rounded corners.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(CGColor(red: 0.25, green: 0.15, blue: 0.45, alpha: 1)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let background = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.36, green: 0.27, blue: 0.93, alpha: 1), CGColor(red: 0.90, green: 0.29, blue: 0.52, alpha: 1)] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(background, start: CGPoint(x: inset, y: size - inset), end: CGPoint(x: size - inset, y: inset), options: [])
let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(shine, start: CGPoint(x: size / 2, y: size - inset), end: CGPoint(x: size / 2, y: size / 2), options: [])
cg.restoreGState()

let white = CGColor(gray: 1, alpha: 0.97)
let soft = CGColor(gray: 1, alpha: 0.55)

// Two sources on the left, one destination on the right.
let sourceA = CGPoint(x: 300, y: 650)
let sourceB = CGPoint(x: 300, y: 374)
let sink = CGPoint(x: 724, y: 512)

func cable(_ a: CGPoint, _ b: CGPoint, color: CGColor) {
    let dx = (b.x - a.x) * 0.55
    cg.move(to: a)
    cg.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
    cg.setStrokeColor(color)
    cg.setLineWidth(38)
    cg.setLineCap(.round)
    cg.strokePath()
}
cable(sourceA, sink, color: white)
cable(sourceB, sink, color: soft)

func node(_ center: CGPoint, radius: CGFloat) {
    cg.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    cg.setFillColor(white)
    cg.fillPath()
    let hole = radius * 0.42
    cg.addEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
    cg.setFillColor(CGColor(red: 0.55, green: 0.28, blue: 0.75, alpha: 1))
    cg.fillPath()
}
node(sourceA, radius: 70)
node(sourceB, radius: 70)
node(sink, radius: 92)

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
