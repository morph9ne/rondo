// Настоящий Liquid Glass через SwiftUI (.glassEffect). Собирается только с SDK macOS 26+ (флаг SYSTEM_GLASS).
// Плитки-кусочки торта увеличиваются вокруг фокуса как иконки в доке; фокус ведёт пружина на частоте экрана.
// Все параметры (тема, стекло, увеличение, пружина…) приходят из Prefs — их меняет окно настроек.
#if SYSTEM_GLASS
import AppKit
import SwiftUI
import QuartzCore

@available(macOS 26.0, *)
final class GlassRingModel: ObservableObject {
    @Published var selected = 0
    /// Сглаженный фокус увеличения в долях сектора (может уходить за 0…n — layout сам заворачивает).
    @Published var focus = 0.0
    @Published var appeared = false
    @Published var prefs = Prefs()
    /// Живой круг может менять список на лету (закрыли приложение) — тогда плитки берутся отсюда.
    @Published var items: [RingItem]? = nil
    /// Исчезающая плитка и ход её исчезновения 0…1; поворот всего круга (радианы) после удаления.
    @Published var dying: Int? = nil
    @Published var collapse = 0.0
    @Published var spin = 0.0
}

/// Кусочек торта между углами (по часовой от верха), в координатах SwiftUI (y вниз, центр — середина вида).
struct WedgeShape: Shape {
    var start: Double, end: Double, inner: Double, outer: Double
    var gap = 7.0, corner = 13.0
    func path(in rect: CGRect) -> Path {
        let raw = RingGeometry.wedgePath(from: start, to: end, inner: inner, outer: outer, gap: gap, corner: corner)
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.midX, ty: rect.midY)
        return Path(raw.copy(using: &t) ?? raw)
    }
}

/// Все плитки и центральный диск одним контуром — для одного общего слоя стекла.
struct RingUnionShape: Shape {
    var wedges: [(start: Double, end: Double, outer: Double)]
    var inner: Double, gap: Double, corner: Double, centerRadius: Double
    func path(in rect: CGRect) -> Path {
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.midX, ty: rect.midY)
        let all = CGMutablePath()
        for w in wedges {
            let raw = RingGeometry.wedgePath(from: w.start, to: w.end, inner: inner, outer: w.outer, gap: gap, corner: corner)
            all.addPath(raw, transform: t)
        }
        all.addEllipse(in: CGRect(x: rect.midX - centerRadius, y: rect.midY - centerRadius, width: 2 * centerRadius, height: 2 * centerRadius))
        return Path(RingGeometry.flattened(all))
    }
}

/// Дуга-указатель по краю центрального диска: смотрит туда же, куда фокус.
struct PointerArc: Shape {
    var angle: Double, half: Double, radius: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // SwiftUI: 0 = вправо, по часовой (y вниз); у нас — по часовой от верха
        let a = angle - .pi / 2
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                 startAngle: .radians(a - half), endAngle: .radians(a + half), clockwise: false)
        return p
    }
}

/// Размеры круга при данных настройках: сторона вида, метрики, увеличение. `fit` — дополнительное сжатие (превью).
struct RingLayout {
    var m: RingGeometry.Metrics
    var mag: Magnifier
    var k: Double
    var side: Double { mag.diameter(m) }

    init(count: Int, prefs: Prefs, fit: Double = 1, effective: Double? = nil) {
        k = prefs.size * fit
        m = RingGeometry.metrics(effective: effective ?? Double(count), scale: k)
        var g = prefs.magnifier
        g.lift *= k
        mag = g
    }
}

/// Тема из настроек → цветовая схема SwiftUI (системная — не трогаем).
struct ThemeModifier: ViewModifier {
    let theme: Prefs.Theme
    @ViewBuilder func body(content: Content) -> some View {
        switch theme {
        case .dark:   content.environment(\.colorScheme, .dark)
        case .light:  content.environment(\.colorScheme, .light)
        case .system: content
        }
    }
}

extension Prefs.Theme {
    var appearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

/// Размытие подложки (для «матовости»): системный материал, обрезается маской по плиткам.
struct BackdropBlur: NSViewRepresentable {
    var behindWindow: Bool
    var dark: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.material = .popover
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.blendingMode = behindWindow ? .behindWindow : .withinWindow
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

/// Размытие подложки с непрерывным радиусом (тот же слой, что внутри NSVisualEffectView): вместо проявления копии
/// радиус растёт плавно, поэтому промежуточные положения — это просто «чуть более мутное стекло», без двойного контура.
final class VarBlurView: NSView {
    var radius: CGFloat = 0 { didSet { if radius != oldValue { apply() } } }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer {
        let cls = (NSClassFromString("CABackdropLayer") as? CALayer.Type) ?? CALayer.self
        let l = cls.init()
        l.setValue(true, forKey: "windowServerAware")
        l.setValue(1.0, forKey: "scale")
        return l
    }
    override func updateLayer() { apply() }
    private func apply() {
        guard let l = layer, let fcls = NSClassFromString("CAFilter") as? NSObject.Type,
              let f = fcls.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else { return }
        f.setValue(radius, forKey: "inputRadius")
        f.setValue(true, forKey: "inputNormalizeEdges")
        l.filters = radius > 0.01 ? [f] : []
    }
}

struct VarBackdropBlur: NSViewRepresentable {
    var radius: CGFloat
    func makeNSView(context: Context) -> VarBlurView { let v = VarBlurView(); v.wantsLayer = true; return v }
    func updateNSView(_ v: VarBlurView, context: Context) { v.radius = radius }
}

/// Вход для NSHostingView и превью: применяет тему и отдаёт кругу модель.
@available(macOS 26.0, *)
struct GlassRingRoot: View {
    let items: [RingItem]
    var flat = false
    var fit = 1.0
    var behindWindow = true
    @ObservedObject var model: GlassRingModel

    var body: some View {
        GlassRingView(items: items, flat: flat, fit: fit, behindWindow: behindWindow, model: model)
            .modifier(ThemeModifier(theme: model.prefs.theme))
    }
}

@available(macOS 26.0, *)
struct GlassRingView: View {
    let items: [RingItem]
    /// true — без стекла (для PNG-демо: ImageRenderer стекло не рисует).
    var flat = false
    var fit = 1.0
    /// true — размывать то, что за окном (живой круг); false — то, что внутри окна (превью на картинке).
    var behindWindow = true
    @ObservedObject var model: GlassRingModel
    @ObservedObject private var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = model.prefs
        let items = model.items ?? self.items
        let n = items.count
        let lay = RingLayout(count: n, prefs: p, fit: fit,
                             effective: model.dying != nil ? Double(n) - model.collapse : nil)
        let m = lay.m, mag = lay.mag, k = lay.k
        let side = CGFloat(lay.side)
        let gap = p.gap * k, corner = p.corner * k
        let tiles = mag.layout(count: n, focus: model.focus, removing: model.dying, collapse: model.collapse, spin: model.spin)
        let cr = m.inner - gap
        let sector = 2 * Double.pi / Double(max(n, 1))
        let dark = scheme == .dark

        ZStack {
            // 1а) матовость: размытие подложки с радиусом по ползунку Liquid Glass (растёт плавно), маска — форма плиток.
            // Размывает то, что за кругом (в живом окне — рабочий стол, в превью — картинку внутри окна).
            let radius = Settings.frostRadius(settings.glassLevel)
            if radius > 0.05 && !flat && p.showPlate {
                VarBackdropBlur(radius: CGFloat(radius))
                    .frame(width: side, height: side)
                    .mask {
                        ZStack {
                            ForEach(0..<n, id: \.self) { i in
                                let t = tiles[i]
                                WedgeShape(start: t.start, end: t.end, inner: m.inner, outer: mag.outer(m, t.weight),
                                           gap: gap, corner: corner)
                                    .fill(Color.black)
                            }
                            Circle().inset(by: side / 2 - CGFloat(cr)).fill(Color.black)
                        }
                        .frame(width: side, height: side)
                    }
            }

            // 1б) стекло. Живое — ОДИН слой на весь контур (плитки + диск): 17 отдельных стёкол с меняющейся
            // формой съедали половину процессора и роняли кадры. Затемнение и подсветка — обычные заливки под ним.
            if !p.showPlate {
                // без подложки: ни стекла, ни заливок — круг состоит из иконок и подписи
            } else if flat {
                GlassEffectContainer(spacing: 2) {
                    ZStack {
                        ForEach(0..<n, id: \.self) { i in
                            let t = tiles[i]
                            glass(WedgeShape(start: t.start, end: t.end, inner: m.inner, outer: mag.outer(m, t.weight),
                                             gap: gap, corner: corner),
                                  weight: t.weight, dark: dark, side: side)
                        }
                        glass(Circle().inset(by: side / 2 - CGFloat(cr)), weight: 0, dark: dark, side: side)
                    }
                }
            } else {
                let ws = (0..<n).map { i in (start: tiles[i].start, end: tiles[i].end, outer: mag.outer(m, tiles[i].weight)) }
                let u = RingUnionShape(wedges: ws, inner: m.inner, gap: gap, corner: corner, centerRadius: cr)
                tintFills(items: items, tiles: tiles, m: m, mag: mag, gap: gap, corner: corner, cr: cr, side: side, dark: dark)
                Color.clear.frame(width: side, height: side).glassEffect(Glass.clear, in: u)
            }

            // 2) указатель направления на краю центрального диска
            if p.showPointer && p.showPlate {   // дуга сидит на краю центрального диска; без подложки диска нет
                PointerArc(angle: model.focus * sector, half: min(sector * 0.45, 0.42), radius: cr - 7 * k)
                    .stroke((dark ? Color.white : Color.black).opacity(0.55),
                            style: StrokeStyle(lineWidth: max(2, 3 * k), lineCap: .round))
                    .blur(radius: 0.6)
                    .shadow(color: (dark ? Color.white : Color.black).opacity(0.4), radius: 5 * k)
                    .frame(width: side, height: side)
            }

            // 3) иконки: крупнее и выше в фокусе, у соседей — плавно меньше
            ForEach(0..<n, id: \.self) { i in
                let t = tiles[i]
                let a = RingGeometry.math(t.mid), r = mag.iconRadius(m, t.weight)
                // размер — сколько влезает в плитку с отступом, но не больше задуманного
                let s = CGFloat(RingGeometry.fittedIcon(size: mag.iconSize(m, t.weight), center: r, half: (t.end - t.start) / 2,
                                                        inner: m.inner, outer: mag.outer(m, t.weight), gap: gap))
                // исчезающая иконка тает быстрее, чем смыкаются соседи: размывается, бледнеет и проваливается внутрь
                let fade = model.dying == i ? min(1, model.collapse * 1.7) : 0
                Image(nsImage: items[i].image(p.iconShape))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: s, height: s)
                    .blur(radius: CGFloat(fade * 8) * k)
                    .opacity(1 - fade)
                    // без подложки иконке не на чем «стоять» — тень сильнее, иначе теряется на светлых обоях
                    .shadow(color: .black.opacity((p.showPlate ? 0.22 : 0.38) + 0.18 * t.weight),
                            radius: (3 + 5 * t.weight) * k, y: (2 + 3 * t.weight) * k)
                    .scaleEffect(model.appeared ? 1 : 0.4)
                    .opacity(model.appeared ? 1 : 0)
                    .animation(.spring(duration: 0.42, bounce: 0.32).delay(0.012 * Double(i)), value: model.appeared)
                    .offset(x: CGFloat(cos(a) * r), y: CGFloat(-sin(a) * r))
            }

            // 4) имя выбранного в центре: две строки, длинное — ужимается, а не обрезается
            if p.showLabel {
                // Каждое имя — отдельный вид с id: старое уходит, новое приходит. Иначе SwiftUI морфит
                // один текст в другой, и у слов разной ширины получается мутная каша из двух надписей.
                ZStack {
                    Text(items.indices.contains(model.selected) ? items[model.selected].name : "")
                        .font(.system(size: 15 * k, weight: .semibold))
                        .foregroundStyle(dark || !p.showPlate ? Color.white : Color.black.opacity(0.85))
                        .shadow(color: (dark ? Color.black : Color.white).opacity(0.35), radius: 3, y: 1)
                        .shadow(color: .black.opacity(p.showPlate ? 0 : 0.5), radius: 6, y: 1)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .frame(width: CGFloat(cr) * 1.45, height: CGFloat(cr) * 1.1)
                        .id(model.selected)
                        .transition(labelTransition(p.labelAnim, k: k))
                }
                .animation(p.labelAnim == .none ? nil : .smooth(duration: 0.22), value: model.selected)
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(model.appeared ? 1 : 0.86)
        .opacity(model.appeared ? 1 : 0)
    }

    /// Цвет плитки: вдали — затемнение, у фокуса — светлая подсветка (по весу фокуса).
    private func tintColor(_ w: Double, dark: Bool) -> Color {
        let p = model.prefs
        let tintAmt = Settings.glassTint(settings.glassLevel) * 0.34
        return Color(white: (dark ? 0.0 : 1.0) * (1 - w) + w, opacity: (p.shade + tintAmt) * (1 - w) + p.highlight * w)
    }

    @ViewBuilder
    private func tintFills(items: [RingItem], tiles: [Magnifier.Tile], m: RingGeometry.Metrics, mag: Magnifier, gap: Double, corner: Double,
                           cr: Double, side: CGFloat, dark: Bool) -> some View {
        ForEach(0..<tiles.count, id: \.self) { i in
            let t = tiles[i]
            WedgeShape(start: t.start, end: t.end, inner: m.inner, outer: mag.outer(m, t.weight), gap: gap, corner: corner)
                .fill(tintColor(t.weight, dark: dark)).frame(width: side, height: side)
        }
        Circle().inset(by: side / 2 - CGFloat(cr)).fill(tintColor(0, dark: dark)).frame(width: side, height: side)
        let p = model.prefs
        if p.iconGlow {
            // растекание: крошечная копия иконки растянута и мягко интерполирована, обрезана формой плитки
            ForEach(0..<tiles.count, id: \.self) { i in
                let t = tiles[i]
                let a = RingGeometry.math(t.mid), r = mag.iconRadius(m, t.weight)
                let s = CGFloat(mag.iconSize(m, t.weight)) * 2.6
                Image(nsImage: items[i].blob)
                    .resizable().interpolation(.high)
                    .frame(width: s, height: s)
                    .offset(x: CGFloat(cos(a) * r), y: CGFloat(-sin(a) * r))
                    .frame(width: side, height: side)
                    .clipShape(WedgeShape(start: t.start, end: t.end, inner: m.inner, outer: mag.outer(m, t.weight), gap: gap, corner: corner))
                    .opacity(p.iconGlowAmount * (0.7 + 0.3 * t.weight))
            }
        }
        if p.tileColor {
            ForEach(0..<tiles.count, id: \.self) { i in
                let t = tiles[i]
                WedgeShape(start: t.start, end: t.end, inner: m.inner, outer: mag.outer(m, t.weight), gap: gap, corner: corner)
                    .fill(Color(nsColor: items[i].accent).opacity(p.tileColorAmount * 0.85 * (0.7 + 0.3 * t.weight)))
                    .frame(width: side, height: side)
            }
        }
    }

    /// Плитка стекла. Вдали от фокуса — затемнение (`shade`), в фокусе — светлая подсветка (`highlight`):
    /// цвет и прозрачность подмешиваются по весу фокуса, поэтому переход плавный.
    @ViewBuilder
    private func glass<S: Shape>(_ shape: S, weight w: Double, dark: Bool, side: CGFloat) -> some View {
        let base = Glass.clear
        let p = model.prefs
        // тонировка по ползунку Liquid Glass: на прозрачном стекле сам ключ NSGlassTintAmount почти не виден
        let tintAmt = Settings.glassTint(settings.glassLevel) * 0.34
        let opacity = (p.shade + tintAmt) * (1 - w) + p.highlight * w
        let white = (dark ? 0.0 : 1.0) * (1 - w) + w                // чёрный → белый по мере приближения фокуса
        if flat {
            shape.fill(Color(white: white, opacity: opacity * 0.9 + 0.12))
                .overlay(shape.stroke(.white.opacity(0.28), lineWidth: 1))
                .frame(width: side, height: side)
        } else {
            Color.clear
                .frame(width: side, height: side)
                .glassEffect(opacity > 0.005 ? base.tint(Color(white: white, opacity: opacity)) : base, in: shape)
        }
    }
}

/// Пружина, которая ведёт фокус увеличения. Общая для живого круга и превью в настройках.
@available(macOS 26.0, *)
final class FocusDriver: NSObject {
    let model: GlassRingModel
    var count: Int
    /// Окно, в котором показан круг (нужно для частоты экрана); nil — круга на экране нет, пружину не крутим.
    var window: () -> NSWindow?
    private var pointer: Double?          // позиция курсора в долях сектора; nil — ведёт клавиатура
    private var target = 0.0, value = 0.0, velocity = 0.0
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0

    init(model: GlassRingModel, count: Int, selected: Int, window: @escaping () -> NSWindow?) {
        self.model = model; self.count = count; self.window = window
        super.init()
        value = Double(selected); target = value
        model.selected = selected
        model.focus = value
    }

    // ---- удаление плитки (Q): плитка сжимается, соседи смыкаются, потом список меняется без скачка
    private var removal: (index: Int, items: [RingItem], selected: Int, t0: CFTimeInterval)?
    private var pendingSelected: Int?
    private var pendingPointer: Double??
    private var spinVelocity = 0.0
    private let collapseTime = 0.30

    /// Убрать плитку `index`; `items` — новый список (без неё), `selected` — выбор в новом списке.
    func remove(index: Int, items: [RingItem], selected: Int) {
        finishRemoval()                                   // предыдущее удаление ещё идёт — доводим мгновенно
        guard count > 1, (0..<count).contains(index), window() != nil else {
            replace(items: items, selected: selected, from: nil); return
        }
        pointer = nil
        aim(Double(index))                                // фокус садится на исчезающую плитку
        removal = (index, items, selected, CACurrentMediaTime())
        model.dying = index
        model.collapse = 0
        startLink()
    }

    private func finishRemoval() {
        guard let r = removal else { return }
        removal = nil
        replace(items: r.items, selected: r.selected, from: r.index)
    }

    /// Подменяет список. `from` — индекс исчезнувшей плитки в старом списке: на её месте сейчас щель,
    /// новую раскладку ставим фокусом в эту щель и доворачиваем `spin`, чтобы картинка не прыгнула.
    private func replace(items: [RingItem], selected: Int, from gapIndex: Int?) {
        let old = count
        count = items.count
        model.dying = nil; model.collapse = 0
        if let d = gapIndex, old > 1, count > 0 {
            let mag = RingLayout(count: old, prefs: model.prefs).mag
            let before = mag.layout(count: old, focus: value, removing: d, collapse: 1, spin: model.spin)
            // фокус в новых индексах: всё, что за удалённой плиткой, сдвинулось на одну назад
            let on = Double(old)
            var x = value
            while x < Double(d) - on / 2 { x += on }
            while x >= Double(d) + on / 2 { x -= on }
            var f = x - min(max(x - (Double(d) - 0.5), 0), 1)
            f = f.truncatingRemainder(dividingBy: Double(count)); if f < 0 { f += Double(count) }
            let after = mag.layout(count: count, focus: f)
            let j = (d + 1) % old, jn = d % count                // одна и та же уцелевшая плитка до и после
            let sp = remainder(before[j].mid - after[jn].mid, 2 * .pi)
            value = f; target = f; velocity = 0
            model.spin = sp
            model.items = items
            model.focus = value
        } else {
            model.items = items
            value = Double(selected); target = value; velocity = 0
            model.focus = value
        }
        model.selected = selected
        let pend = pendingSelected; pendingSelected = nil
        let pp = pendingPointer; pendingPointer = nil
        let sel = pend ?? selected
        if sel != model.selected { withAnimation(.easeOut(duration: 0.14)) { model.selected = sel } }
        if let pp { setPointer(pp) } else { aim(Double(sel)) }
        startLink()
    }

    func setSelected(_ i: Int) {
        if removal != nil { pendingSelected = i; return }
        guard i != model.selected else { return }
        withAnimation(.easeOut(duration: 0.14)) { model.selected = i }
        if pointer == nil { aim(Double(i)) }
    }

    /// Курсор показывает на позицию `p` (доли сектора) или nil — фокус возвращается к выбранному.
    func setPointer(_ p: Double?) {
        if removal != nil { pendingPointer = .some(p); return }
        pointer = p
        guard let p else { aim(Double(model.selected)); return }
        // лёгкий «магнит» к середине плитки: увеличение плавное, но выбранная всё равно крупнее всех
        aim(p + (p.rounded() - p) * model.prefs.magnet)
    }

    func aim(_ t: Double) {
        let n = Double(max(count, 1))
        target = value + remainder(t - value, n)          // короткий путь по кругу
        guard window() != nil else { value = target; model.focus = value; return }
        startLink()
    }

    private func startLink() {
        guard let w = window(), let screen = w.screen ?? NSScreen.main else { return }
        if link == nil {
            let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            lastTime = 0
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        let dt = lastTime == 0 ? 1.0 / 120 : min(max(now - lastTime, 0), 1.0 / 30)
        lastTime = now
        // пружина: быстро догоняет курсор и мягко садится на плитку
        let omega = model.prefs.speed, zeta = model.prefs.damping
        var left = dt
        while left > 0 {
            let h = min(left, 1.0 / 480)
            let acc = -omega * omega * (value - target) - 2 * zeta * omega * velocity
            velocity += acc * h
            value += velocity * h
            left -= h
        }
        // поворот после удаления — та же пружина, только к нулю
        if model.spin != 0 || spinVelocity != 0 {
            var sp = model.spin, left = dt
            while left > 0 {
                let h = min(left, 1.0 / 480)
                spinVelocity += (-omega * omega * sp - 2 * zeta * omega * spinVelocity) * h
                sp += spinVelocity * h
                left -= h
            }
            if abs(sp) < 0.0005 && abs(spinVelocity) < 0.01 { sp = 0; spinVelocity = 0 }
            model.spin = sp
        }
        if let r = removal {
            let t = min(1, (now - r.t0) / collapseTime)
            model.collapse = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2     // easeInOutCubic
            if t >= 1 { finishRemoval() }
        }
        let settled = abs(value - target) < 0.0005 && abs(velocity) < 0.01
        if settled { value = target; velocity = 0 }
        if settled && removal == nil && model.spin == 0 { stop() }
        let n = Double(max(count, 1))
        if value >= n || value < 0 {                          // держим числа маленькими
            let k = (value / n).rounded(.down) * n
            value -= k; target -= k
        }
        model.focus = value
    }

    func stop() { link?.invalidate(); link = nil }
    deinit { link?.invalidate() }
}

/// Обёртка для AppKit: мышь проходит насквозь в CaptureView.
@available(macOS 26.0, *)
final class GlassRingHost: NSView {
    private let model = GlassRingModel()
    private var driver: FocusDriver!

    init(items: [RingItem], selected: Int, appear: Bool, prefs: Prefs) {
        model.prefs = prefs
        let side = CGFloat(RingLayout(count: items.count, prefs: prefs).side)
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        driver = FocusDriver(model: model, count: items.count, selected: selected) { [weak self] in self?.window }
        model.appeared = !(appear && prefs.appear)
        let host = NSHostingView(rootView: GlassRingRoot(items: items, model: model))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var occObserver: NSObjectProtocol?
    private var attachedAt = DispatchTime.now()

    private func stopWaiting() {
        if let o = occObserver { NotificationCenter.default.removeObserver(o); occObserver = nil }
    }

    /// Пружина появления. Запускается только когда окно РЕАЛЬНО видно на экране: на полноэкранном столе
    /// окно появляется с задержкой, и анимация, начатая раньше, проигрывалась бы на невидимом окне.
    private func startAppear() {
        stopWaiting()
        guard !model.appeared else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - attachedAt.uptimeNanoseconds) / 1e6
        log(String(format: "анимация появления: старт через %.0f мс после привязки к окну", ms))
        withAnimation(.spring(duration: 0.34, bounce: 0.26)) { model.appeared = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWaiting()
        // окно закрыли — пружину останавливаем (display link держит вид, иначе он жил бы до конца анимации)
        guard let w = window else { driver.stop(); return }
        guard !model.appeared else { return }
        attachedAt = DispatchTime.now()
        // ждём, пока окно станет видимым; запасной таймер — на случай, если система не пришлёт уведомление
        occObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                             object: w, queue: .main) { [weak self] _ in
            guard let self, let w = self.window, w.occlusionState.contains(.visible), w.isVisible else { return }
            DispatchQueue.main.async { self.startAppear() }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window, w.occlusionState.contains(.visible), w.isVisible, w.alphaValue >= 0 else { return }
            if w.occlusionState.contains(.visible) && w.isVisible { self.startAppear() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startAppear() }
    }

    func setSelected(_ i: Int) { driver.setSelected(i) }
    func setPointer(_ p: Double?) { driver.setPointer(p) }
    func remove(index: Int, items: [RingItem], selected: Int) { driver.remove(index: index, items: items, selected: selected) }
}

/// PNG круга для `--demo`: та же раскладка, но плоские плитки на «обоях» (стекло вне экрана не рисуется).
@available(macOS 26.0, *)
@MainActor
func renderGlassRingPNG(items: [RingItem], selected: Int, focus: Double, prefs: Prefs = Settings.shared.prefs) -> Data? {
    let model = GlassRingModel()
    model.selected = selected
    model.focus = focus
    model.appeared = true
    model.prefs = prefs
    // RB_DYING=«индекс,ход» — кадр исчезновения плитки (проверка анимации Q)
    if let d = ProcessInfo.processInfo.environment["RB_DYING"]?.split(separator: ","), d.count == 2,
       let i = Int(d[0]), let c = Double(d[1]) { model.dying = i; model.collapse = c }
    let side = CGFloat(RingLayout(count: items.count, prefs: prefs).side)
    let view = ZStack {
        LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.62), Color(red: 0.45, green: 0.22, blue: 0.55),
                                Color(red: 0.85, green: 0.45, blue: 0.35)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        Color.black.opacity(0.18)
        GlassRingRoot(items: items, flat: true, model: model)
    }
    .frame(width: side + 40, height: side + 40)
    let r = ImageRenderer(content: view)
    r.scale = 2
    // ImageRenderer отдаёт 16-битный линейный цвет; перерисовываем в обычный 8-битный sRGB, иначе PNG «выцветает»
    guard let cg = r.cgImage, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
}
#endif

/// Состояние перехода подписи: размытие, масштаб, сдвиг и прозрачность одним модификатором.
private struct LabelFade: ViewModifier {
    var blur: CGFloat = 0, scale: CGFloat = 1, dy: CGFloat = 0, opacity: Double = 1
    func body(content: Content) -> some View {
        content.blur(radius: blur).scaleEffect(scale).offset(y: dy).opacity(opacity)
    }
}

private func labelTransition(_ a: Prefs.LabelAnim, k: CGFloat) -> AnyTransition {
    switch a {
    case .none:
        return .identity
    case .blur:
        // новое имя «проявляется» из размытия и чуть растёт, старое быстро растворяется в размытие
        return .asymmetric(
            insertion: .modifier(active: LabelFade(blur: 7, scale: 0.9, opacity: 0), identity: LabelFade()),
            removal: .modifier(active: LabelFade(blur: 7, scale: 1.06, opacity: 0), identity: LabelFade()))
    case .slide:
        // колесо барабана: новое приезжает снизу, старое уезжает вверх
        return .asymmetric(
            insertion: .modifier(active: LabelFade(blur: 2, dy: 12 * k, opacity: 0), identity: LabelFade()),
            removal: .modifier(active: LabelFade(blur: 2, dy: -12 * k, opacity: 0), identity: LabelFade()))
    }
}
