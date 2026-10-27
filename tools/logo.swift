import AppKit
import CoreGraphics

// Логотип «Rondo»: кольцо стеклянных плиток, одна выбрана и увеличена, в центре — диск.
let S: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["SZ"] ?? "1024")!)
let GW = CGFloat(Double(ProcessInfo.processInfo.environment["GW"] ?? "1")!), GH = CGFloat(Double(ProcessInfo.processInfo.environment["GH"] ?? "1")!)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "logo.png"

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S * GW), height: Int(S * GH), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }

// суперэллипс n=5 — форма иконки macOS (824 из 1024)
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath(); let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}

// плитка-клин со скруглёнными углами
func wedge(_ c0: CGPoint, r0: CGFloat, r1: CGFloat, a0: CGFloat, a1: CGFloat, corner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let ca = corner / r1, ci = corner / r0
    p.addArc(center: c0, radius: r1, startAngle: a0 + ca, endAngle: a1 - ca, clockwise: false)
    p.addQuadCurve(to: CGPoint(x: c0.x + (r1 - corner) * cos(a1), y: c0.y + (r1 - corner) * sin(a1)),
                   control: CGPoint(x: c0.x + r1 * cos(a1), y: c0.y + r1 * sin(a1)))
    p.addLine(to: CGPoint(x: c0.x + (r0 + corner) * cos(a1), y: c0.y + (r0 + corner) * sin(a1)))
    p.addQuadCurve(to: CGPoint(x: c0.x + r0 * cos(a1 - ci), y: c0.y + r0 * sin(a1 - ci)),
                   control: CGPoint(x: c0.x + r0 * cos(a1), y: c0.y + r0 * sin(a1)))
    p.addArc(center: c0, radius: r0, startAngle: a1 - ci, endAngle: a0 + ci, clockwise: true)
    p.addQuadCurve(to: CGPoint(x: c0.x + (r0 + corner) * cos(a0), y: c0.y + (r0 + corner) * sin(a0)),
                   control: CGPoint(x: c0.x + r0 * cos(a0), y: c0.y + r0 * sin(a0)))
    p.addLine(to: CGPoint(x: c0.x + (r1 - corner) * cos(a0), y: c0.y + (r1 - corner) * sin(a0)))
    p.addQuadCurve(to: CGPoint(x: c0.x + r1 * cos(a0 + ca), y: c0.y + r1 * sin(a0 + ca)),
                   control: CGPoint(x: c0.x + r1 * cos(a0), y: c0.y + r1 * sin(a0)))
    p.closeSubpath(); return p
}

struct Style { var accent: CGColor; var dark: Bool; var n = 8; var variant = 0 }
let ivory = c(0.941, 0.933, 0.902), slate = c(0.098, 0.098, 0.094)
func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let x = a.components!, y = b.components!
    return c(x[0] + (y[0]-x[0])*t, x[1] + (y[1]-x[1])*t, x[2] + (y[2]-x[2])*t)
}

/// variant: 0 — база; 1 — соседи выбранной в полутоне (как лупа); 2 — в центре указатель-дуга вместо точки;
/// 3 — центральная точка «выросла» в выбранную плитку (выбранная плитка без отдельного акцента, точка + плитка — одна форма)
func icon(origin o: CGPoint, scale k: CGFloat, _ st: Style) {
    ctx.saveGState(); ctx.translateBy(x: o.x, y: o.y); ctx.scaleBy(x: k, y: k)
    let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    let bg = st.dark ? slate : ivory, ink = st.dark ? ivory : slate
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: c(0, 0, 0, 0.22))
    ctx.addPath(shape); ctx.setFillColor(bg); ctx.fillPath(); ctx.restoreGState()

    let C = CGPoint(x: 512, y: 512), n = st.n, focus = 1
    let gap: CGFloat = n <= 6 ? 0.16 : 0.12
    let r0: CGFloat = n <= 6 ? 160 : 170, r1: CGFloat = n <= 6 ? 304 : 300
    let weights: [CGFloat] = (0..<n).map { i in
        let d = CGFloat(min(abs(i - focus), n - abs(i - focus))); return 1 + 0.5 * exp(-d * d / 0.9) }
    let wsum = weights.reduce(0, +)
    var starts: [CGFloat] = []; var acc: CGFloat = 0
    for w in weights { starts.append(acc); acc += w / wsum * 2 * .pi }
    let off = CGFloat.pi / 4 + (starts[focus] + weights[focus] / wsum * .pi)
    for i in 0..<n {
        let wi = weights[i] / wsum * 2 * .pi, mid = off - (starts[i] + wi / 2), sel = i == focus
        let half = wi / 2 - gap / 2
        let ri = sel ? r0 - 10 : r0, ro = sel ? r1 + 40 : r1
        let d = min(abs(i - focus), n - abs(i - focus))
        var col = sel ? st.accent : ink
        if st.variant == 1 && d == 1 { col = mix(ink, st.accent, 0.42) }
        ctx.addPath(wedge(C, r0: ri, r1: ro, a0: mid - half, a1: mid + half, corner: 26))
        ctx.setFillColor(col); ctx.fillPath()
    }
    ctx.setFillColor(st.accent); ctx.setStrokeColor(st.accent)
    switch st.variant {
    case 2:
        ctx.setLineCap(.round); ctx.setLineWidth(34)
        ctx.addArc(center: C, radius: 92, startAngle: .pi / 4 - 0.55, endAngle: .pi / 4 + 0.55, clockwise: false); ctx.strokePath()
    case 3:
        // точка-курсор, смещённая к выбранной плитке
        let p = CGPoint(x: C.x + 46 * cos(.pi / 4), y: C.y + 46 * sin(.pi / 4))
        ctx.addEllipse(in: CGRect(x: p.x - 44, y: p.y - 44, width: 88, height: 88)); ctx.fillPath()
    default:
        ctx.addEllipse(in: CGRect(x: C.x - 58, y: C.y - 58, width: 116, height: 116)); ctx.fillPath()
    }
    ctx.restoreGState()
}

// палитра: акценты из вторичных цветов Anthropic
let accents: [(String, CGColor)] = [
    ("clay",   c(0.851, 0.467, 0.341)),   // #D97757
    ("sky",    c(0.416, 0.608, 0.800)),   // #6A9BCC
    ("olive",  c(0.471, 0.549, 0.365)),   // #788C5D
    ("fig",    c(0.769, 0.400, 0.525)),   // #C46686
    ("heather",c(0.545, 0.525, 0.780)),   // лаванда, темнее #CBCADB чтобы читалась
]
let spec = ProcessInfo.processInfo.environment["SPEC"] ?? "grid"
if spec == "grid" {
    // строки: варианты; столбцы: цвета
    let rows: [(Bool, Int, Int)] = [(false, 8, 0), (true, 8, 1), (false, 6, 2), (true, 8, 3)]
    for (r, row) in rows.enumerated() {
        for (ci, a) in accents.enumerated() {
            icon(origin: CGPoint(x: CGFloat(ci) * S, y: (GH - 1 - CGFloat(r)) * S), scale: S / 1024,
                 Style(accent: a.1, dark: row.0, n: row.1, variant: row.2))
        }
    }
} else {
    let p = spec.split(separator: ",").map(String.init)   // color,dark,n,variant
    icon(origin: .zero, scale: S / 1024, Style(accent: accents.first { $0.0 == p[0] }!.1, dark: p[1] == "1", n: Int(p[2])!, variant: Int(p[3])!))
}
let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
