// Окно с кругом: размытый диск, иконки по окружности, подсветка выбранной, имя в центре.
import AppKit
import QuartzCore

/// Приводит иконку к единой форме. Иконка «по сетке» (скруглённый квадрат) обрезается и выравнивается по размеру;
/// круглая или фигурная кладётся на подложку своего краевого цвета — как macOS делает с нестандартными иконками.
enum IconNormalizer {
    static let side = 256
    static let content = 0.8                 // доля холста под видимую часть

    static func shape(_ icon: NSImage, circle: Bool) -> NSImage? {
        let n = side
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let src = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        src.interpolationQuality = .high
        var rect = CGRect(x: 0, y: 0, width: n, height: n)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        src.draw(cg, in: rect)
        guard let px = src.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }
        // память: строка 0 — верх картинки; переводим в координаты CG (y снизу)
        func alpha(_ x: Int, _ yUp: Int) -> Double {
            let xx = min(max(x, 0), n - 1), row = n - 1 - min(max(yUp, 0), n - 1)
            return Double(px[(row * n + xx) * 4 + 3]) / 255
        }
        // рамка непрозрачной части (без мягкой тени)
        var x0 = n, y0 = n, x1 = -1, y1 = -1
        for yUp in 0..<n { for x in 0..<n where alpha(x, yUp) > 0.5 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, yUp); y1 = max(y1, yUp)
        } }
        guard x1 > x0, y1 > y0 else { return nil }
        let bw = Double(x1 - x0 + 1), bh = Double(y1 - y0 + 1)
        let square = abs(bw - bh) / max(bw, bh) < 0.08
        func probe(_ fx: Double, _ fy: Double) -> Double { alpha(x0 + Int(fx * bw), y0 + Int(fy * bh)) }
        let corners = [probe(0.09, 0.09), probe(0.91, 0.09), probe(0.09, 0.91), probe(0.91, 0.91)]
        let edges = [probe(0.5, 0.02), probe(0.5, 0.98), probe(0.02, 0.5), probe(0.98, 0.5)]
        let isSquircle = square && corners.allSatisfy { $0 > 0.6 } && edges.allSatisfy { $0 > 0.6 }
        let isCircle = square && corners.allSatisfy { $0 < 0.3 } && edges.allSatisfy { $0 > 0.6 }

        // краевой цвет: непрозрачные пиксели у границы рамки фигуры
        var r = 0.0, g = 0.0, b = 0.0, cnt = 0.0
        for yUp in y0...y1 { for x in x0...x1 {
            let a = alpha(x, yUp)
            guard a > 0.9, alpha(x - 4, yUp) < 0.5 || alpha(x + 4, yUp) < 0.5 || alpha(x, yUp - 4) < 0.5 || alpha(x, yUp + 4) < 0.5 else { continue }
            let row = n - 1 - yUp, i = (row * n + x) * 4
            r += Double(px[i]) / 255 / a; g += Double(px[i + 1]) / 255 / a; b += Double(px[i + 2]) / 255 / a; cnt += 1
        } }
        let edge = cnt > 0 ? CGColor(srgbRed: r / cnt, green: g / cnt, blue: b / cnt, alpha: 1) : CGColor(gray: 0.92, alpha: 1)

        guard let dst = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srcImg = src.makeImage() else { return nil }
        dst.interpolationQuality = .high
        let s = Double(n) * content, o = (Double(n) - s) / 2
        let target = CGRect(x: o, y: o, width: s, height: s)
        let path = circle ? CGPath(ellipseIn: target, transform: nil)
                          : CGPath(roundedRect: target, cornerWidth: s * 0.2237, cornerHeight: s * 0.2237, transform: nil)
        // куда положить содержимое: своя форма — во всю цель, чужая — на подложку чуть меньше
        let fits = circle ? (isCircle || isSquircle) : isSquircle
        let k = fits ? 1.0 : (circle ? (isSquircle ? 1.0 : 0.74) : (isCircle ? 0.94 : 0.76))
        let cs = s * k, co = (Double(n) - cs) / 2
        let scale = cs / max(bw, bh)
        let draw = CGRect(x: co - (Double(x0) - (max(bw, bh) - bw) / 2) * scale,
                          y: co - (Double(y0) - (max(bw, bh) - bh) / 2) * scale,
                          width: Double(n) * scale, height: Double(n) * scale)
        dst.saveGState()
        dst.addPath(path); dst.clip()
        if !fits { dst.setFillColor(edge); dst.fill(target) }
        dst.draw(srcImg, in: draw)
        dst.restoreGState()
        guard let out = dst.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: n / 2, height: n / 2))
    }
}

struct RingItem {
    let name: String
    let icon: NSImage
    /// Преобладающий цвет иконки (для окраски плитки) и её маленькая копия 12×12, которую растягивают в мягкое пятно.
    let accent: NSColor
    let blob: NSImage

    /// Та же иконка, приведённая к одной форме и одному размеру видимой части (80% холста, как сетка macOS).
    let squircle: NSImage
    let circle: NSImage

    init(name: String, icon: NSImage) {
        self.name = name; self.icon = icon
        let (c, b) = RingItem.analyse(icon)
        accent = c; blob = b
        squircle = IconNormalizer.shape(icon, circle: false) ?? icon
        circle = IconNormalizer.shape(icon, circle: true) ?? icon
    }

    func image(_ shape: Prefs.IconShape) -> NSImage {
        switch shape { case .original: return icon; case .squircle: return squircle; case .circle: return circle }
    }

    private static func analyse(_ icon: NSImage) -> (NSColor, NSImage) {
        let n = 12
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (.gray, NSImage(size: NSSize(width: 1, height: 1)))
        }
        ctx.interpolationQuality = .high
        var rect = CGRect(x: 0, y: 0, width: n, height: n)
        if let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) { ctx.draw(cg, in: rect) }
        guard let px = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else {
            return (.gray, NSImage(size: NSSize(width: 1, height: 1)))
        }
        // цвет: среднее по пикселям, где насыщенные и яркие весят больше (чёрный фон иконки не должен перебивать)
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        for i in 0..<(n * n) {
            let a = Double(px[i * 4 + 3]) / 255
            guard a > 0.05 else { continue }
            let pr = Double(px[i * 4]) / 255 / a, pg = Double(px[i * 4 + 1]) / 255 / a, pb = Double(px[i * 4 + 2]) / 255 / a
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let w = a * (0.04 + (mx - mn) * mx * 3 + mx * 0.15)
            r += pr * w; g += pg * w; b += pb * w; wsum += w
        }
        // насыщенность повыше: на стекле пастельный цвет теряется
        func boost(_ v: Double, _ lum: Double) -> Double { max(0, min(1, lum + (v - lum) * 1.45)) }
        let c: NSColor
        if wsum > 0 {
            let (cr, cg, cb) = (r / wsum, g / wsum, b / wsum), lum = 0.3 * cr + 0.59 * cg + 0.11 * cb
            c = NSColor(srgbRed: boost(cr, lum), green: boost(cg, lum), blue: boost(cb, lum), alpha: 1)
        } else { c = NSColor.gray }
        // пятно: те же пиксели, прозрачное заполняем цветом иконки, чтобы края не светились пустотой
        for i in 0..<(n * n) {
            let a = Double(px[i * 4 + 3]) / 255
            let pr = a > 0.05 ? Double(px[i * 4]) / 255 / a : Double(c.redComponent)
            let pg = a > 0.05 ? Double(px[i * 4 + 1]) / 255 / a : Double(c.greenComponent)
            let pb = a > 0.05 ? Double(px[i * 4 + 2]) / 255 / a : Double(c.blueComponent)
            let k = min(1, a * 1.6)
            px[i * 4]     = UInt8(max(0, min(255, (pr * k + Double(c.redComponent) * (1 - k)) * 255)))
            px[i * 4 + 1] = UInt8(max(0, min(255, (pg * k + Double(c.greenComponent) * (1 - k)) * 255)))
            px[i * 4 + 2] = UInt8(max(0, min(255, (pb * k + Double(c.blueComponent) * (1 - k)) * 255)))
            px[i * 4 + 3] = 255
        }
        guard let out = ctx.makeImage() else { return (c, NSImage(size: NSSize(width: 1, height: 1))) }
        return (c, NSImage(cgImage: out, size: NSSize(width: n, height: n)))
    }
}

final class RingPanel: NSPanel {
    // key-окно нужно ради стекла: в неактивном окне система рисует Liquid Glass плоским, без бликов и преломления.
    // Панель nonactivating — приложение при этом не активируется и фокус ввода не крадёт.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Корневой вид на весь экран: ловит движение мыши и клики (иначе клик ушёл бы в окно под кругом).
final class CaptureView: NSView {
    var onMove: ((NSPoint) -> Void)?
    var onClick: ((NSPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // панель теперь key: клавиши, которые не съел event tap, гасим тут, чтобы не пищало
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { onMove?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onMove?(NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { onClick?(NSEvent.mouseLocation) }
}

/// Круг из «кусочков торта»: каждый кусочек — отдельная стеклянная плитка с иконкой приложения.
final class DiscView: NSView {
    private let items: [RingItem]
    private let host = NSView()
    private let label = NSTextField(labelWithString: "")
    private var iconLayers: [CALayer] = []
    private var selLayers: [CAShapeLayer] = []
    /// Контуры плиток (сначала кусочки по индексам, последний — центральный диск) в координатах вида.
    private(set) var shapes: [CGPath] = []
    private(set) var effects: [NSView] = []

    /// Настоящий Liquid Glass системы (NSGlassEffectView, macOS 26+). В SDK 15.5 его нет — берём из рантайма.
    static let glassClass: NSView.Type? = {
        if ProcessInfo.processInfo.arguments.contains("--no-glass") { return nil }
        return NSClassFromString("NSGlassEffectView") as? NSView.Type
    }()
    private var usesSystemGlass: Bool { Self.glassClass != nil }

    private func addGlass(_ path: CGPath) {
        shapes.append(path)
        let bb = path.boundingBoxOfPath
        if let cls = Self.glassClass {
            let g = cls.init(frame: bb)
            let setter = NSSelectorFromString("setCornerRadius:")
            if g.responds(to: setter) { g.setValue(0, forKey: "cornerRadius") }
            g.wantsLayer = true
            let mask = CAShapeLayer()
            var shift = CGAffineTransform(translationX: -bb.minX, y: -bb.minY)
            mask.path = path.copy(using: &shift)
            mask.fillColor = NSColor.black.cgColor
            g.layer?.mask = mask
            addSubview(g)
            effects.append(g)
            return
        }
        let effect = NSVisualEffectView(frame: bb)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = NSImage(size: bb.size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: -bb.minX, y: -bb.minY)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        addSubview(effect)
        effects.append(effect)
    }

    init(items: [RingItem]) {
        self.items = items
        let m = RingGeometry.metrics(count: items.count)
        let d = CGFloat(m.diameter)
        super.init(frame: NSRect(x: 0, y: 0, width: d, height: d))
        appearance = NSAppearance(named: .darkAqua)
        let c = CGPoint(x: d / 2, y: d / 2)
        let n = items.count
        let gap = 7.0, corner = 13.0

        // 1) размытие под каждой плиткой (маска — форма плитки)
        var move = CGAffineTransform(translationX: c.x, y: c.y)
        for i in 0..<n {
            let raw = RingGeometry.wedgePath(index: i, count: n, inner: m.inner, outer: m.outer, gap: gap, corner: corner)
            addGlass(raw.copy(using: &move) ?? raw)
        }
        let cr = CGFloat(m.inner - gap)
        addGlass(CGPath(ellipseIn: CGRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr), transform: nil))

        // 2) слои стекла поверх размытия
        host.frame = bounds
        host.wantsLayer = true
        addSubview(host)
        let root = host.layer!
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let all = CGMutablePath()
        shapes.forEach { all.addPath($0) }

        // лёгкое осветление «молока»
        let tint = CAShapeLayer()
        tint.path = all
        tint.fillColor = NSColor(white: 1, alpha: 0.07).cgColor
        if !usesSystemGlass { root.addSublayer(tint) }

        // блик по поверхности: свет сверху-слева, слабый встречный блик снизу-справа
        func gradient(_ colors: [CGFloat], _ locations: [NSNumber]) -> CAGradientLayer {
            let g = CAGradientLayer()
            g.frame = CGRect(x: 0, y: 0, width: d, height: d)
            g.colors = colors.map { NSColor(white: 1, alpha: $0).cgColor }
            g.locations = locations
            g.startPoint = CGPoint(x: 0, y: 1)
            g.endPoint = CGPoint(x: 1, y: 0)
            return g
        }
        let sheen = gradient([0.20, 0.03, 0.0, 0.08], [0, 0.4, 0.7, 1])
        let sheenMask = CAShapeLayer()
        sheenMask.frame = sheen.bounds
        sheenMask.path = all
        sheenMask.fillColor = NSColor.black.cgColor
        sheen.mask = sheenMask
        if !usesSystemGlass { root.addSublayer(sheen) }

        // подсветка выбранной плитки
        for i in 0..<n {
            let l = CAShapeLayer()
            l.path = shapes[i]
            l.fillColor = NSColor(white: 1, alpha: 0.30).cgColor
            l.opacity = 0
            root.addSublayer(l)
            selLayers.append(l)
        }

        // кромка стекла: яркая в двух противоположных углах, на остальных почти не видна (не белая рамка)
        let rim = gradient([0.85, 0.16, 0.10, 0.5], [0, 0.34, 0.64, 1])
        let rimMask = CAShapeLayer()
        rimMask.frame = rim.bounds
        rimMask.path = all
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1.4
        rim.mask = rimMask
        if !usesSystemGlass { root.addSublayer(rim) }

        // 3) иконки
        let shape = Settings.shared.prefs.iconShape
        let icon = CGFloat(RingGeometry.fittedIcon(size: m.icon, center: m.radius, half: .pi / Double(max(n, 1)),
                                                   inner: m.inner, outer: m.outer, gap: 7))
        for (i, item) in items.enumerated() {
            let o = RingGeometry.offset(index: i, count: n, radius: m.radius)
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: icon, height: icon)
            l.position = CGPoint(x: c.x + o.x, y: c.y + o.y)
            l.contentsScale = scale
            l.contentsGravity = .resizeAspect
            l.minificationFilter = .trilinear
            var rect = CGRect(x: 0, y: 0, width: icon * scale, height: icon * scale)
            l.contents = item.image(shape).cgImage(forProposedRect: &rect, context: nil, hints: nil)
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.35; l.shadowRadius = 4; l.shadowOffset = CGSize(width: 0, height: -2)
            root.addSublayer(l)
            iconLayers.append(l)
        }

        // 4) имя в центре
        let inner = max(96, 2 * cr - 28)
        label.frame = NSRect(x: c.x - inner / 2, y: c.y - 24, width: inner, height: 48)
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.usesSingleLineMode = false
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    var hostLayer: CALayer? { host.layer }
    var labelView: NSTextField { label }
    var labelFrame: NSRect { label.frame }

    func setSelected(_ i: Int, animated: Bool) {
        guard iconLayers.indices.contains(i) else { return }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (k, l) in iconLayers.enumerated() {
            l.transform = k == i ? CATransform3DMakeScale(1.22, 1.22, 1) : CATransform3DIdentity
            l.zPosition = k == i ? 1 : 0
            selLayers[k].opacity = k == i ? 1 : 0
        }
        CATransaction.commit()
        label.stringValue = items[i].name
    }
}

final class Overlay {
    private var panel: RingPanel?
    private var disc: DiscView?
    private var selectFn: ((Int) -> Void)?
    private var pointFn: ((Double?) -> Void)?
    private var removeFn: ((Int, [RingItem], Int) -> Void)?
    private var fadeGen = 0
    /// Центр круга в глобальных координатах экрана.
    private(set) var center = NSPoint.zero
    var onMove: ((NSPoint) -> Void)?
    var onClick: ((NSPoint) -> Void)?

    var isShown: Bool { panel?.isVisible ?? false }

    /// Показать (или перестроить) круг по центру экрана, где сейчас курсор `mouse`; возвращает центр круга.
    /// Идёт тихий прогрев: окно уже на экране, но невидимо и не ловит мышь.
    private var warming = false
    /// Круг по-настоящему показан пользователю (между настоящим show и hide). Прогрев — не в счёт.
    private var live = false

    /// Один раз за запуск строит и «показывает» круг невидимо, чтобы первый настоящий Cmd+Tab не платил
    /// за холодный старт стекла (шейдеры, слои, текстуры) — это ~35–50 мс.
    /// Выбросить окно круга (пока оно скрыто) — следующий показ/прогрев построит новое на текущем столе.
    func dropPanel() {
        guard !isShown, let p = panel else { return }
        warming = false; live = false
        p.orderOut(nil); p.contentView = nil; panel = nil
    }

    private static var fakedStuck = false

    func prewarm(items: [RingItem], mouse: NSPoint, retry: Bool = true) {
        guard !isShown, !items.isEmpty else { return }
        show(items: items, selected: 0, mouse: mouse, silent: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.warming, let p = self.panel else { return }
            // Самопроверка: окно «показано», но система могла оставить его на другом столе (так бывает после
            // перехода в полноэкранное приложение) — тогда настоящий круг был бы невидим. Пересоздаём его
            // сейчас, пока никто не смотрит, и прогреваем новое уже на текущем столе.
            var onSpace = p.isOnActiveSpace
            // проверка самой ветки пересоздания: --fake-stuck один раз притворяется, что окно застряло
            if retry, ProcessInfo.processInfo.arguments.contains("--fake-stuck"), !Self.fakedStuck { Self.fakedStuck = true; onSpace = false }
            log("прогрев: окно круга на текущем столе — \(onSpace ? "да" : "НЕТ")")
            if !onSpace {
                self.warming = false; self.live = false
                p.orderOut(nil); p.contentView = nil; self.panel = nil
                if retry { self.prewarm(items: items, mouse: mouse, retry: false) }
                return
            }
            self.warming = false
            self.hide()
        }
    }

    @discardableResult
    func show(items: [RingItem], selected: Int, mouse: NSPoint, silent: Bool = false) -> NSPoint {
        Settings.shared.refreshSystemGlass()
        fadeGen += 1
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let p: RingPanel
        if let existing = panel { p = existing } else {
            p = RingPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
            p.isOpaque = false
            p.hasShadow = false
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.acceptsMouseMovedEvents = true
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            panel = p
        }
        // затемнение экрана из настроек; минимум 2% — иначе окно перестаёт ловить мышь (полностью прозрачное — не ловит)
        let prefs = Settings.shared.prefs
        p.backgroundColor = NSColor(white: 0, alpha: max(0.02, prefs.screenDim))
        p.appearance = prefs.theme.appearance
        p.setFrame(screen.frame, display: false)

        let capture = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        capture.onMove = { [weak self] pt in self?.onMove?(pt) }
        capture.onClick = { [weak self] pt in self?.onClick?(pt) }

        let d: NSView
        pointFn = nil
        removeFn = nil
        #if SYSTEM_GLASS
        if #available(macOS 26.0, *), !ProcessInfo.processInfo.arguments.contains("--no-glass") {
            let g = GlassRingHost(items: items, selected: selected, appear: !live, prefs: prefs)
            selectFn = { [weak g] i in g?.setSelected(i) }
            pointFn = { [weak g] pos in g?.setPointer(pos) }
            removeFn = { [weak g] i, items, sel in g?.remove(index: i, items: items, selected: sel) }
            disc = nil; d = g
        } else {
            let v = DiscView(items: items); v.setSelected(selected, animated: false)
            selectFn = { [weak v] i in v?.setSelected(i, animated: true) }
            disc = v; d = v
        }
        #else
        let v = DiscView(items: items); v.setSelected(selected, animated: false)
        selectFn = { [weak v] i in v?.setSelected(i, animated: true) }
        disc = v; d = v
        #endif
        let half = d.frame.width / 2
        // круг всегда в центре экрана (если он вдруг больше экрана — прижимаем к краям)
        let cx = max(half + 8, screen.frame.width / 2)
        let cy = max(half + 8, screen.frame.height / 2)
        d.frame.origin = NSPoint(x: cx - half, y: cy - half)
        capture.addSubview(d)
        p.contentView = capture
        center = NSPoint(x: cx + screen.frame.minX, y: cy + screen.frame.minY)

        if silent {
            p.ignoresMouseEvents = true
            p.alphaValue = 0
            p.orderFrontRegardless()
            warming = true
        } else if !live {
            // первый настоящий показ — всегда с нуля, даже если окно ещё висит от прогрева или затухает после него
            live = true
            warming = false
            p.ignoresMouseEvents = false
            p.alphaValue = 0
            p.orderFrontRegardless()
            p.makeKey()
            // плитки сами появляются пружиной, так что общий фейд короткий — иначе круг «проявляется» лишние 0.1 с
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.05
                p.animator().alphaValue = 1
            }
        }
        return center
    }

    func select(_ i: Int) { selectFn?(i) }
    /// Убрать плитку `index` с анимацией (живое стекло) или просто перестроить круг.
    func remove(index: Int, items: [RingItem], selected: Int) {
        if let f = removeFn { f(index, items, selected) }
        else { show(items: items, selected: selected, mouse: center) }
    }
    /// Куда показывает курсор (доли сектора) — для увеличения как в доке; nil — фокус у выбранного.
    func point(_ pos: Double?) { pointFn?(pos) }

    func hide() {
        guard let p = panel, p.isVisible else { live = false; return }
        warming = false
        live = false
        fadeGen += 1
        let gen = fadeGen
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.fadeGen else { return }
            p.orderOut(nil)
            p.contentView = nil
            self.disc = nil
            self.selectFn = nil
            self.pointFn = nil
            self.removeFn = nil
        })
    }

    var windowNumber: Int { panel?.windowNumber ?? 0 }

    /// Отрисовка круга в PNG: настоящего размытия окна вне экрана нет, поэтому фон и «молоко» рисуем приближённо.
    func snapshotPNG() -> Data? {
        guard let d = disc, let layer = d.hostLayer else { return nil }
        let pad: CGFloat = 24
        let w = Int(d.bounds.width + pad * 2), h = Int(d.bounds.height + pad * 2)
        let scale = 2
        guard let ctx = CGContext(data: nil, width: w * scale, height: h * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // фон «обои»
        let colors = [CGColor(red: 0.16, green: 0.30, blue: 0.62, alpha: 1), CGColor(red: 0.45, green: 0.22, blue: 0.55, alpha: 1),
                      CGColor(red: 0.85, green: 0.45, blue: 0.35, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        }
        ctx.translateBy(x: pad, y: pad)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.42))               // грубая замена hudWindow
        d.shapes.forEach { ctx.addPath($0); ctx.fillPath() }
        layer.render(in: ctx)                                            // стекло, иконки
        // подпись в центре
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let text = NSAttributedString(string: d.labelView.stringValue, attributes: [
            .font: d.labelView.font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white, .paragraphStyle: para])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(in: d.labelFrame.insetBy(dx: 0, dy: 2))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
