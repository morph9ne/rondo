// Чистая логика круга: геометрия, выбор сектора, недавность. Без AppKit — тестируется отдельно.
import Foundation
import CoreGraphics

enum RingGeometry {
    /// Угол иконки в математических координатах (0 = вправо, против часовой).
    /// Индекс 0 — сверху, дальше по часовой стрелке.
    static func angle(index: Int, count: Int) -> Double {
        .pi / 2 - 2 * .pi * Double(index) / Double(max(count, 1))
    }

    /// Центр иконки относительно центра круга (y вверх).
    static func offset(index: Int, count: Int, radius: Double) -> CGPoint {
        let a = angle(index: index, count: count)
        return CGPoint(x: cos(a) * radius, y: sin(a) * radius)
    }

    /// Непрерывная позиция направления (dx, dy) в долях сектора: 0 — сверху, 1 — следующий по часовой, [0, count).
    static func position(dx: Double, dy: Double, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let twoPi = 2 * Double.pi
        var phi = (Double.pi / 2 - atan2(dy, dx)).truncatingRemainder(dividingBy: twoPi)   // по часовой от верха
        if phi < 0 { phi += twoPi }
        return phi / (twoPi / Double(count))
    }

    /// Какой сектор «смотрит» в сторону вектора (dx, dy), y вверх.
    static func sector(dx: Double, dy: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(position(dx: dx, dy: dy, count: count).rounded()) % count
    }

    /// radius — окружность центров иконок; inner/outer — границы «кусочков торта»; diameter — размер вида.
    struct Metrics { var radius: Double; var icon: Double; var inner: Double; var outer: Double; var diameter: Double }

    /// Радиус круга и размер иконок: чем больше приложений, тем больше круг, потом сжимаются иконки.
    /// `scale` — общий масштаб круга из настроек (1 = как раньше).
    static func metrics(count: Int, scale: Double = 1) -> Metrics { metrics(effective: Double(count), scale: scale) }
    /// То же для дробного числа плиток — пока плитка исчезает, круг плавно ужимается до нового размера.
    static func metrics(effective count: Double, scale: Double = 1) -> Metrics {
        let baseIcon = 64.0, gap = 16.0, minR = 135.0, maxR = 330.0
        let n = max(count, 1)
        let r = min(max(minR, n * (baseIcon + gap) / (2 * .pi)), maxR)
        let icon = min(baseIcon, max(34, 2 * .pi * r / n - gap))
        let half = icon * 0.85
        let k = max(scale, 0.1)
        return Metrics(radius: r * k, icon: icon * k, inner: (r - half) * k, outer: (r + half) * k,
                       diameter: 2 * (r + half + 14) * k)
    }
}

extension RingGeometry {
    /// Кусочек торта вокруг начала координат (y вверх): сектор индекса `index` между радиусами inner…outer,
    /// с зазором `gap` до соседей (параллельные кромки) и скруглёнными углами `corner`.
    static func wedgePath(index: Int, count: Int, inner: Double, outer: Double, gap: Double, corner: Double) -> CGPath {
        func disc(_ r: Double) -> CGPath { CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil) }
        if count <= 1 { return disc(outer).subtracting(disc(inner)) }

        let s = 2 * Double.pi / Double(count)
        return wedgePath(from: (Double(index) - 0.5) * s, to: (Double(index) + 0.5) * s,
                         inner: inner, outer: outer, gap: gap, corner: corner)
    }
}

/// Увеличение «как в доке»: вокруг фокуса плитки шире и выше, иконки крупнее, соседи — плавно меньше.
/// Фокус — непрерывная позиция в долях сектора (как RingGeometry.position). Точка фокуса остаётся на месте:
/// направление курсора всегда попадает в ту же плитку, что и `sector`, поэтому выбор и картинка не расходятся.
struct Magnifier {
    /// Ширина «горба» в секторах, рост ширины плитки, рост иконки, насколько плитка выезжает наружу (px).
    var sigma = 0.8, widen = 0.6, iconGain = 0.38, lift = 18.0

    struct Tile { var start: Double; var end: Double; var mid: Double; var weight: Double }

    /// Внешний радиус плитки, радиус центра иконки и размер иконки при весе фокуса `w`.
    func outer(_ m: RingGeometry.Metrics, _ w: Double) -> Double { m.outer + lift * w }
    func iconRadius(_ m: RingGeometry.Metrics, _ w: Double) -> Double { m.radius + lift * w / 2 }
    func iconSize(_ m: RingGeometry.Metrics, _ w: Double) -> Double { m.icon * (1 + iconGain * w) }
    /// Размер вида, в который влезает круг с выехавшей плиткой.
    func diameter(_ m: RingGeometry.Metrics) -> Double { m.diameter + 2 * lift }

    /// Насколько плитка `i` под фокусом: 1 — в фокусе, 0 — далеко.
    func weight(_ i: Int, focus: Double, count: Int) -> Double {
        let n = Double(count)
        var d = abs((Double(i) - focus).truncatingRemainder(dividingBy: n))
        d = min(d, n - d)
        return exp(-d * d / (2 * sigma * sigma))
    }

    /// Углы плиток по часовой от верха (радианы): start…end, mid — центр, weight — насколько в фокусе.
    /// `removing`/`collapse` — плитка, которая исчезает: её ширина сжимается до нуля (0…1), соседи смыкаются.
    /// `spin` — общий поворот (радианы), чтобы после удаления круг доехал до новой раскладки без скачка.
    func layout(count: Int, focus rawFocus: Double, removing: Int? = nil, collapse: Double = 0, spin: Double = 0) -> [Tile] {
        guard count > 0 else { return [] }
        let n = Double(count), s = 2 * Double.pi / n
        if count == 1 { return [Tile(start: -Double.pi, end: Double.pi, mid: 0, weight: 1)] }
        var f = rawFocus.truncatingRemainder(dividingBy: n)
        if f < -0.5 { f += n }
        if f >= n - 0.5 { f -= n }                               // f ∈ [-0.5, n - 0.5)
        var ws = (0..<count).map { weight($0, focus: f, count: count) }
        if let r = removing, (0..<count).contains(r), collapse > 0 {
            // увеличение считаем так, будто плитки за исчезающей уже сдвинулись на её место (на `c` позиций),
            // а круг стал на `c` плиток короче: к концу веса ровно как у нового круга — подмена списка без скачка
            let c = min(max(collapse, 0), 1), nEff = n - c
            func g(_ x: Double) -> Double { x - c * min(max(x - (Double(r) - 0.5), 0), 1) }
            var x = f
            while x < Double(r) - n / 2 { x += n }
            while x >= Double(r) + n / 2 { x -= n }
            let fe = g(x)
            ws = (0..<count).map { i in
                var d = abs((g(Double(i)) - fe).truncatingRemainder(dividingBy: nEff))
                d = min(d, nEff - d)
                return exp(-d * d / (2 * sigma * sigma))
            }
        }
        var raw = ws.map { 1 + widen * $0 }
        if let r = removing, raw.indices.contains(r) { raw[r] *= max(0, 1 - collapse) }
        let total = raw.reduce(0, +)
        let widths = raw.map { 2 * Double.pi * $0 / total }
        var starts = [Double](repeating: 0, count: count)
        for i in 1..<count { starts[i] = starts[i - 1] + widths[i - 1] }
        // поворот так, чтобы точка фокуса стояла там же, где без увеличения
        let k = Int((f + 0.5).rounded(.down))
        let frac = f + 0.5 - Double(k)
        let shift = f * s - (starts[k] + frac * widths[k])
        return (0..<count).map { i in
            let a = starts[i] + shift + spin
            return Tile(start: a, end: a + widths[i], mid: a + widths[i] / 2, weight: ws[i])
        }
    }
}

extension RingGeometry {
    /// Наибольший размер иконки (не больше `size`), при котором её видимая часть (доля `content` холста)
    /// стоит на радиусе `center` внутри плитки с полууглом `half`, зазором `gap` и отступом `pad` от всех краёв.
    static func fittedIcon(size: Double, center rc: Double, half: Double, inner: Double, outer: Double,
                           gap: Double, pad: Double = 6, content: Double = 0.8) -> Double {
        func ok(_ s: Double) -> Bool {
            let h = s * content / 2
            if rc - h < inner + pad { return false }
            if hypot(rc + h, h) > outer - pad { return false }
            if half < .pi / 2 && (rc - h) * sin(half) - h * cos(half) < gap / 2 + pad { return false }
            return true
        }
        if ok(size) { return size }
        var lo = 0.0, hi = size
        for _ in 0..<24 { let mid = (lo + hi) / 2; if ok(mid) { lo = mid } else { hi = mid } }
        return lo
    }

    /// Тот же контур ломаной с шагом ~`step` пт (отклонение от дуги < 0.1 пт). Системному стеклу так
    /// вдвое дешевле: оно каждый кадр «нормализует» контур, и кривые там дорогие.
    static func flattened(_ p: CGPath, step: CGFloat = 3) -> CGPath {
        let out = CGMutablePath(); var cur = CGPoint.zero
        p.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: out.move(to: pts[0]); cur = pts[0]
            case .addLineToPoint: out.addLine(to: pts[0]); cur = pts[0]
            case .addQuadCurveToPoint: out.addQuadCurve(to: pts[1], control: pts[0]); cur = pts[1]
            case .addCurveToPoint:
                let p0 = cur, p1 = pts[0], p2 = pts[1], p3 = pts[2]
                let len = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y) + hypot(p3.x - p2.x, p3.y - p2.y)
                let k = max(1, Int((len / step).rounded(.up)))
                for i in 1...k {
                    let t = CGFloat(i) / CGFloat(k), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    out.addLine(to: CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y))
                }
                cur = p3
            case .closeSubpath: out.closeSubpath()
            @unknown default: break
            }
        }
        return out
    }

    /// Угол «по часовой от верха» → математический (0 = вправо, против часовой).
    static func math(_ clockwiseFromTop: Double) -> Double { .pi / 2 - clockwiseFromTop }

    /// Кусочек торта между углами (по часовой от верха) и радиусами, с зазором и скруглением.
    static func wedgePath(from a0: Double, to a1: Double, inner: Double, outer: Double, gap: Double, corner: Double) -> CGPath {
        guard a1 - a0 > 1e-4 else { return CGMutablePath() }   // нулевая плитка (исчезла) — без контура, а не целое кольцо
        let lo = math(a1), hi = math(a0)
        let k = gap / 2 + corner
        let rIn = inner + corner, rOut = outer - corner
        // контур строится сразу: «ужатая» плитка, раздутая на corner = прямые бока + дуги-скругления.
        // В вырожденных случаях (крошечная плитка) — через объединение контуров, как раньше.
        guard corner > 0, inner > 0, rOut > rIn, k < rIn else { return wedgePathClipped(from: a0, to: a1, inner: inner, outer: outer, gap: gap, corner: corner) }
        let di = asin(k / rIn), dO = asin(k / rOut)
        func polar(_ r: Double, _ t: Double) -> CGPoint { CGPoint(x: cos(t) * r, y: sin(t) * r) }
        let C = polar(rOut, hi - dO), D = polar(rOut, lo + dO)
        let p = CGMutablePath()
        if hi - di > lo + di {
            let A = polar(rIn, lo + di), B = polar(rIn, hi - di)
            p.move(to: polar(inner, lo + di))
            p.addArc(center: .zero, radius: inner, startAngle: lo + di, endAngle: hi - di, clockwise: false)
            p.addArc(center: B, radius: corner, startAngle: hi + .pi - di, endAngle: hi + .pi / 2, clockwise: true)
            p.addArc(center: C, radius: corner, startAngle: hi + .pi / 2, endAngle: hi - dO, clockwise: true)
            p.addArc(center: .zero, radius: outer, startAngle: hi - dO, endAngle: lo + dO, clockwise: true)
            p.addArc(center: D, radius: corner, startAngle: lo + dO, endAngle: lo - .pi / 2, clockwise: true)
            p.addArc(center: A, radius: corner, startAngle: lo - .pi / 2, endAngle: lo + di - .pi, clockwise: true)
            p.closeSubpath()
            return p
        }
        // узкая плитка: бока сходятся раньше внутреннего круга — острие тоже скругляется
        let half = (hi - lo) / 2
        guard half > 0, half < .pi / 2 else { return wedgePathClipped(from: a0, to: a1, inner: inner, outer: outer, gap: gap, corner: corner) }
        let rP = k / sin(half)
        guard rP < rOut else {
            // скругление не влезает — берём наибольшее, которое влезает (старый способ тут давал кляксу)
            let sh = sin(half), c2 = 0.9 * (outer * sh - gap / 2) / (1 + sh)
            return c2 > 0.5 ? wedgePath(from: a0, to: a1, inner: inner, outer: outer, gap: gap, corner: c2) : CGMutablePath()
        }
        let P = polar(rP, lo + half)
        p.move(to: CGPoint(x: P.x + cos(hi + .pi / 2) * corner, y: P.y + sin(hi + .pi / 2) * corner))
        p.addArc(center: C, radius: corner, startAngle: hi + .pi / 2, endAngle: hi - dO, clockwise: true)
        p.addArc(center: .zero, radius: outer, startAngle: hi - dO, endAngle: lo + dO, clockwise: true)
        p.addArc(center: D, radius: corner, startAngle: lo + dO, endAngle: lo - .pi / 2, clockwise: true)
        p.addArc(center: P, radius: corner, startAngle: lo - .pi / 2, endAngle: hi + .pi / 2 - 2 * .pi, clockwise: true)
        p.closeSubpath()
        return p
    }

    /// Та же плитка через объединение контуров (медленно; эталон для тестов и запасной путь).
    static func wedgePathClipped(from a0: Double, to a1: Double, inner: Double, outer: Double, gap: Double, corner: Double) -> CGPath {
        // математические углы: по часовой от верха идёт в обратную сторону
        let lo = math(a1), hi = math(a0)
        let k = gap / 2 + corner
        let rIn = inner + corner, rOut = outer - corner
        func delta(_ r: Double) -> Double { asin(min(k / r, 1)) }
        func polar(_ r: Double, _ t: Double) -> CGPoint { CGPoint(x: cos(t) * r, y: sin(t) * r) }
        let base = CGMutablePath()
        base.addArc(center: .zero, radius: rIn, startAngle: lo + delta(rIn), endAngle: hi - delta(rIn), clockwise: false)
        base.addLine(to: polar(rOut, hi - delta(rOut)))
        base.addArc(center: .zero, radius: rOut, startAngle: hi - delta(rOut), endAngle: lo + delta(rOut), clockwise: true)
        base.closeSubpath()
        let rim = base.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return base.union(rim)
    }
}

/// Список по недавности: первый — самый свежий.
struct Recency<ID: Hashable> {
    private(set) var items: [ID] = []
    mutating func touch(_ id: ID) { items.removeAll { $0 == id }; items.insert(id, at: 0) }
    mutating func append(_ id: ID) { if !items.contains(id) { items.append(id) } }
    mutating func remove(_ id: ID) { items.removeAll { $0 == id } }
    mutating func reset(_ ids: [ID]) { items = []; ids.forEach { append($0) } }
}

/// Выбор в сессии: стартует с предыдущего приложения (как системный Cmd+Tab).
struct RingSelection {
    private(set) var count: Int
    var index: Int

    init(count: Int, backwards: Bool) {
        self.count = count
        index = count > 1 ? (backwards ? count - 1 : 1) : 0
    }
    mutating func step(backwards: Bool) {
        guard count > 0 else { return }
        index = (index + (backwards ? -1 : 1) + count) % count
    }
    mutating func shrink(removing i: Int) {
        guard count > 0 else { return }
        count -= 1
        index = count == 0 ? 0 : min(i, count - 1)
    }
}
