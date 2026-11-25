// Draws the Junction app icon (1024×1024 PNG): two cables meeting at a gold junction and leaving as one, into a
// plug, on an indigo tile. Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// MARK: Family style
// The sibling apps' icon scripts share this part word for word: a solid colour tile shaded slightly lighter at the
// top, one bold cream symbol with a gold accent, and a small kite tail in the lower-right corner. Only `tile` and the
// symbol differ between apps. Change all of them together.

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
/// `hex` moved `amount` of the way towards white (positive) or black (negative).
func shade(_ hex: UInt32, _ amount: CGFloat) -> CGColor {
    let c = rgb(hex).components!
    let target: CGFloat = amount > 0 ? 1 : 0
    let t = abs(amount)
    return CGColor(red: c[0] + (target - c[0]) * t, green: c[1] + (target - c[1]) * t, blue: c[2] + (target - c[2]) * t, alpha: 1)
}
let cream = rgb(0xf6f0e4)
let gold = rgb(0xe2b552)
let tile: UInt32 = 0x353f7a  // indigo

// The tile, on the macOS icon grid: inset from the canvas, with rounded corners and a drop shadow.
let inset: CGFloat = 100
let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                   cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(rgb(tile)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let tileShade = CGGradient(colorsSpace: space, colors: [shade(tile, 0.10), rgb(tile), shade(tile, -0.10)] as CFArray,
                           locations: [0, 0.5, 1])!
cg.drawLinearGradient(tileShade, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
cg.restoreGState()

/// Draws `body` with a soft shadow under it, so the symbol sits just above the tile.
func raised(_ body: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.18))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    cg.endTransparencyLayer()
    cg.restoreGState()
}

/// The family mark: a wavy cream ribbon hanging from a gold bow, like a kite's tail.
func kiteTail() {
    let knot = CGPoint(x: 796, y: 246)
    let ribbon = CGMutablePath()
    let steps = 40
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = CGPoint(x: knot.x + sin(t * 2 * .pi) * (6 + 10 * t), y: knot.y - 96 * t)
        if i == 0 { ribbon.move(to: point) } else { ribbon.addLine(to: point) }
    }
    cg.addPath(ribbon)
    cg.setStrokeColor(cream); cg.setLineWidth(15); cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.strokePath()
    let s: CGFloat = 21
    let bow = CGMutablePath()
    for side: CGFloat in [-1, 1] {
        bow.move(to: knot)
        bow.addLine(to: CGPoint(x: knot.x + side * s, y: knot.y + s * 0.7))
        bow.addLine(to: CGPoint(x: knot.x + side * s, y: knot.y - s * 0.7))
        bow.closeSubpath()
    }
    cg.addPath(bow); cg.setFillColor(gold); cg.fillPath()
    cg.addEllipse(in: CGRect(x: knot.x - 6, y: knot.y - 6, width: 12, height: 12)); cg.fillPath()
}

// MARK: Symbol

// Two cables come in from the left edge, meet at a gold junction and leave to the right as one, ending in a plug.
let upper: CGFloat = 640, lower: CGFloat = 384, mid = size / 2
let junction = CGPoint(x: 540, y: mid)
let cableWidth: CGFloat = 40

cg.saveGState()
cg.addPath(shape); cg.clip()  // the incoming cables run off the tile's edge
raised {
    cg.setStrokeColor(cream); cg.setLineWidth(cableWidth); cg.setLineCap(.round)
    for y in [upper, lower] {
        cg.move(to: CGPoint(x: 60, y: y))
        cg.addLine(to: CGPoint(x: 250, y: y))
        cg.addCurve(to: junction, control1: CGPoint(x: 400, y: y), control2: CGPoint(x: 410, y: mid))
        cg.strokePath()
        // A connector sleeve where each cable enters, with one groove.
        let sleeve = CGRect(x: 40, y: y - 34, width: 220, height: 68)
        cg.addPath(CGPath(roundedRect: sleeve, cornerWidth: 22, cornerHeight: 22, transform: nil))
        cg.setFillColor(cream); cg.fillPath()
        cg.setFillColor(rgb(tile)); cg.fill(CGRect(x: 196, y: y - 34, width: 12, height: 68))
    }
    // The single cable out, into a jack plug: body, collar, shaft and tip.
    cg.move(to: junction); cg.addLine(to: CGPoint(x: 680, y: mid)); cg.strokePath()
    cg.addPath(CGPath(roundedRect: CGRect(x: 660, y: mid - 40, width: 112, height: 80), cornerWidth: 22, cornerHeight: 22,
                      transform: nil))
    cg.setFillColor(cream); cg.fillPath()
    cg.fill(CGRect(x: 772, y: mid - 26, width: 22, height: 52))
    cg.addPath(CGPath(roundedRect: CGRect(x: 790, y: mid - 18, width: 86, height: 36), cornerWidth: 18, cornerHeight: 18,
                      transform: nil))
    cg.fillPath()
    cg.setFillColor(rgb(tile)); cg.fill(CGRect(x: 840, y: mid - 18, width: 8, height: 36))

    let r: CGFloat = 62
    cg.addEllipse(in: CGRect(x: junction.x - r, y: junction.y - r, width: 2 * r, height: 2 * r))
    cg.setFillColor(gold); cg.fillPath()
}
cg.restoreGState()
kiteTail()

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
