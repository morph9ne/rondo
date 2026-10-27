// Фон окна установщика: слоновая кость, терракотовая стрелка от приложения к «Программам».
// Использование: dmg-bg <выход.png> <масштаб 1|2>
import AppKit

let out = CommandLine.arguments[1]
let k = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let W: CGFloat = 660, H: CGFloat = 400

let ivory = NSColor(srgbRed: 0.941, green: 0.933, blue: 0.902, alpha: 1)
let clay  = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let slate = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.075, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * k), pixelsHigh: Int(H * k),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W * k, height: H * k)
NSGraphicsContext.saveGraphicsState()
let g = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = g
let ctx = g.cgContext
ctx.scaleBy(x: k, y: k)

ivory.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

// мягкое тёплое пятно сверху, как на иконке
let grad = NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.78, blue: 0.68, alpha: 0.35), ivory.withAlphaComponent(0)])!
grad.draw(fromCenter: NSPoint(x: W / 2, y: H + 40), radius: 0, toCenter: NSPoint(x: W / 2, y: H + 40), radius: 360, options: [])

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                            .foregroundColor: color, .paragraphStyle: para]
    NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: y, width: W, height: size + 8))
}
text("Rondo", size: 26, weight: .semibold, color: slate, y: H - 62)
text("Перетащи Rondo в «Программы»", size: 13, weight: .regular, color: slate.withAlphaComponent(0.6), y: H - 90)

// стрелка между двумя иконками (они стоят в точках (170,190) и (490,190) по центру окна)
let ay = H - 190
ctx.setStrokeColor(clay.cgColor); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 260, y: ay)); ctx.addLine(to: CGPoint(x: 390, y: ay)); ctx.strokePath()
ctx.move(to: CGPoint(x: 372, y: ay + 16)); ctx.addLine(to: CGPoint(x: 394, y: ay)); ctx.addLine(to: CGPoint(x: 372, y: ay - 16)); ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
