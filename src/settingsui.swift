// Окно настроек Rondo: слева живое превью круга на обоях macOS, справа настройки в трёх вкладках.
// Главное — на виду, тонкая настройка спрятана под «Тонкая настройка». Всё применяется сразу (Settings.shared).
#if SYSTEM_GLASS
import AppKit
import SwiftUI
import Combine
import ServiceManagement
import ImageIO

/// Фирменный цвет — глина с иконки.

// ===================================================================== окно
@available(macOS 26.0, *)
/// Окно настроек: появляется с лёгким «вырастанием» и растворяется при закрытии.
final class SettingsWindow: NSWindow {
    private var closing = false

    private func scaleLayer(_ from: CGFloat, _ to: CGFloat, duration: CFTimeInterval, spring: Bool) {
        guard let v = contentView else { return }
        v.wantsLayer = true
        guard let l = v.layer else { return }
        let b = v.bounds
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: b.midX, y: b.midY)
        let a: CABasicAnimation
        if spring {
            let s = CASpringAnimation(keyPath: "transform.scale")
            s.mass = 1; s.stiffness = 320; s.damping = 26
            s.duration = s.settlingDuration
            a = s
        } else {
            a = CABasicAnimation(keyPath: "transform.scale")
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        a.fromValue = from; a.toValue = to
        a.isRemovedOnCompletion = !(to != 1)
        a.fillMode = .forwards
        l.add(a, forKey: "pop")
    }

    func animateIn() {
        guard !isVisible else { makeKeyAndOrderFront(nil); return }
        closing = false
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        scaleLayer(0.94, 1, duration: 0.3, spring: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    override func performClose(_ sender: Any?) { animateOut() }
    override func close() {
        if closing || !isVisible { super.close(); return }
        animateOut()
    }

    private func animateOut() {
        guard !closing else { return }
        closing = true
        scaleLayer(1, 0.95, duration: 0.16, spring: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.contentView?.layer?.removeAnimation(forKey: "pop")
            self.alphaValue = 1
            self.closing = false
        })
    }
}

/// Кнопка пружинисто «проседает» под пальцем, оставаясь системной на вид.
struct PressBounce: ViewModifier {
    @State private var down = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(down ? 0.93 : 1)
            .animation(.spring(duration: 0.28, bounce: 0.45), value: down)
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true } }
                .onEnded { _ in down = false })
    }
}
extension View { func pressBounce() -> some View { modifier(PressBounce()) } }

@available(macOS 26.0, *)
final class SettingsController {
    static let shared = SettingsController()
    private(set) var window: SettingsWindow?
    /// Окно реально видно на экране (не свёрнуто и не закрыто целиком другими окнами) — только тогда крутим превью.
    var visibleWindow: NSWindow? {
        guard let w = window, w.isVisible, !w.isMiniaturized, w.occlusionState.contains(.visible) else { return nil }
        return w
    }

    func show(tap: TapController?, tab: SettingsTab = .look) {
        if window == nil {
            let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            w.title = "Rondo"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 600)
            w.contentView = NSHostingView(rootView: SettingsView(tab: tab, tapRunning: { tap?.isRunning ?? false }))
            w.center()
            w.setFrameAutosaveName("RondoSettings")
            window = w
        }
        NSApp.activate()
        window?.animateIn()
    }
}

// ===================================================================== вкладки и строки
enum SettingsTab: String, CaseIterable, Identifiable {
    case look = "Вид", motion = "Анимация", system = "Основное"
    var id: String { rawValue }
    var symbol: String { switch self { case .look: "paintpalette"; case .motion: "wand.and.stars"; case .system: "gearshape" } }
}

extension Prefs.Theme {
    var title: String { switch self { case .dark: "Тёмная"; case .light: "Светлая"; case .system: "Как в системе" } }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var hint: String? = nil
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).labelsHidden()
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 1)
    }
}

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
private func pixels(_ v: Double) -> String { "\(Int(v.rounded())) px" }
private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.011 }

/// Набор готовых значений: кнопка-карточка подсвечена, когда настройки совпадают с ним.
struct Preset {
    let title: String, symbol: String
    let apply: (inout Prefs) -> Void
    let matches: (Prefs) -> Bool
}

extension Prefs {
    mutating func apply(theme: Theme, frost: Double, shade: Double, highlight: Double, dim: Double) {
        self.theme = theme; self.frost = frost; self.followSystemGlass = false; self.glass = frost > 0.5 ? .regular : .clear
        self.shade = shade; self.highlight = highlight; self.screenDim = dim; self.showPlate = true
    }
    func looks(theme t: Theme, frost f: Double, shade s: Double, highlight h: Double, dim d: Double) -> Bool {
        showPlate && !followSystemGlass && theme == t && near(frost, f) && near(shade, s) && near(highlight, h) && near(screenDim, d)
    }
}

enum Presets {
    static let look: [Preset] = [
        Preset(title: "Тёмное", symbol: "moon.stars.fill",
               apply: { $0.apply(theme: .dark, frost: 0, shade: 0.22, highlight: 0.16, dim: 0.04) },
               matches: { $0.looks(theme: .dark, frost: 0, shade: 0.22, highlight: 0.16, dim: 0.04) }),
        Preset(title: "Прозрачное", symbol: "drop",
               apply: { $0.apply(theme: .dark, frost: 0, shade: 0, highlight: 0.12, dim: 0) },
               matches: { $0.looks(theme: .dark, frost: 0, shade: 0, highlight: 0.12, dim: 0) }),
        Preset(title: "Светлое", symbol: "sun.max.fill",
               apply: { $0.apply(theme: .light, frost: 0, shade: 0.12, highlight: 0.20, dim: 0) },
               matches: { $0.looks(theme: .light, frost: 0, shade: 0.12, highlight: 0.20, dim: 0) }),
        Preset(title: "Матовое", symbol: "square.on.square",
               apply: { $0.apply(theme: .dark, frost: 1, shade: 0, highlight: 0.14, dim: 0.10) },
               matches: { $0.looks(theme: .dark, frost: 1, shade: 0, highlight: 0.14, dim: 0.10) }),
        Preset(title: "Без стекла", symbol: "circle.dashed",
               apply: { $0.showPlate = false },
               matches: { !$0.showPlate }),
    ]
    private static func mag(_ p: inout Prefs, _ s: Double, _ w: Double, _ g: Double, _ l: Double) {
        p.magnify = true; p.sigma = s; p.widen = w; p.iconGain = g; p.lift = l
    }
    private static func isMag(_ p: Prefs, _ s: Double, _ w: Double, _ g: Double, _ l: Double) -> Bool {
        p.magnify && near(p.sigma, s) && near(p.widen, w) && near(p.iconGain, g) && abs(p.lift - l) < 0.6
    }
    static let magnify: [Preset] = [
        Preset(title: "Без", symbol: "circle", apply: { $0.magnify = false }, matches: { !$0.magnify }),
        Preset(title: "Слегка", symbol: "plus.magnifyingglass",
               apply: { mag(&$0, 0.6, 0.3, 0.2, 8) }, matches: { isMag($0, 0.6, 0.3, 0.2, 8) }),
        Preset(title: "Как в доке", symbol: "dock.rectangle",
               apply: { mag(&$0, 0.8, 0.6, 0.38, 18) }, matches: { isMag($0, 0.8, 0.6, 0.38, 18) }),
        Preset(title: "Сильно", symbol: "sparkle.magnifyingglass",
               apply: { mag(&$0, 1.1, 0.95, 0.6, 28) }, matches: { isMag($0, 1.1, 0.95, 0.6, 28) }),
    ]
    private static func spring(_ p: inout Prefs, _ s: Double, _ d: Double, _ m: Double) { p.speed = s; p.damping = d; p.magnet = m }
    private static func isSpring(_ p: Prefs, _ s: Double, _ d: Double, _ m: Double) -> Bool {
        abs(p.speed - s) < 0.6 && near(p.damping, d) && near(p.magnet, m)
    }
    static let spring: [Preset] = [
        Preset(title: "Мягко", symbol: "leaf", apply: { spring(&$0, 16, 0.95, 0.55) }, matches: { isSpring($0, 16, 0.95, 0.55) }),
        Preset(title: "Как в доке", symbol: "dock.rectangle", apply: { spring(&$0, 24, 0.86, 0.40) }, matches: { isSpring($0, 24, 0.86, 0.40) }),
        Preset(title: "Резко", symbol: "bolt.fill", apply: { spring(&$0, 38, 0.75, 0.20) }, matches: { isSpring($0, 38, 0.75, 0.20) }),
    ]
}

/// Карточка, которая чуть подсвечивается при наведении и пружинисто сжимается при нажатии.
struct CardButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View { Card(configuration: configuration, scale: scale) }
    private struct Card: View {
        let configuration: Configuration
        let scale: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .brightness(hover && !configuration.isPressed ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? scale : (hover ? 1.02 : 1))
                .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hover)
                .onHover { hover = $0 }
        }
    }
}

/// Ряд карточек-пресетов: иконка над подписью, выбранная обведена фирменным цветом.
struct PresetRow: View {
    @Binding var prefs: Prefs
    let presets: [Preset]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets.indices, id: \.self) { i in
                let p = presets[i], on = p.matches(prefs)
                Button { withAnimation(.smooth(duration: 0.25)) { p.apply(&prefs) } } label: {
                    VStack(spacing: 6) {
                        Image(systemName: p.symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                            .symbolEffect(.bounce, value: on)
                        Text(p.title).font(.callout).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(on ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                    .animation(.smooth(duration: 0.25), value: on)
                }
                .buttonStyle(CardButtonStyle())
            }
        }
        .padding(.vertical, 2)
    }
}

// ===================================================================== обои для превью
/// Фоны превью: текущие обои пользователя, системные обои macOS и тестовая сетка (проверять стекло).
/// Системные картинки огромные (6016²), поэтому читаются уменьшенными и в фоне.
struct Wallpaper: Identifiable, Hashable {
    let id: String, title: String, url: URL
}

@available(macOS 26.0, *)
final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()
    let all: [Wallpaper]
    @Published private(set) var full = [String: NSImage]()
    @Published private(set) var thumbs = [String: NSImage]()
    private let queue = DispatchQueue(label: "rondo.wallpapers", qos: .userInitiated)

    private init() {
        var list = [Wallpaper]()
        if let screen = NSScreen.main, let u = NSWorkspace.shared.desktopImageURL(for: screen),
           ["heic", "jpg", "jpeg", "png", "tiff"].contains(u.pathExtension.lowercased()),
           FileManager.default.fileExists(atPath: u.path) {
            list.append(Wallpaper(id: "desktop", title: "Мой рабочий стол", url: u))
        }
        let dir = "/System/Library/Desktop Pictures"
        let system: [(String, String)] = [
            ("Sonoma", "Sonoma"), ("Mac Blue", "Mac · синий"), ("Mac Purple", "Mac · фиолетовый"),
            ("Mac Pink", "Mac · розовый"), ("Mac Yellow", "Mac · жёлтый"), ("iMac Green", "iMac · зелёный"),
            ("iMac Orange", "iMac · оранжевый"), ("iMac Silver", "iMac · серебристый"), ("Radial Sky Blue", "Радиальный синий"),
        ]
        for (file, title) in system {
            let u = URL(fileURLWithPath: "\(dir)/\(file).heic")
            if FileManager.default.fileExists(atPath: u.path) { list.append(Wallpaper(id: file, title: title, url: u)) }
        }
        if let u = Bundle.main.url(forResource: "test", withExtension: "jpg", subdirectory: "backdrops") {
            list.append(Wallpaper(id: "test", title: "Тестовая сетка", url: u))
        }
        all = list
        for w in list { load(w, size: 96, into: \.thumbs) }
    }

    func image(_ w: Wallpaper) -> NSImage? {
        if let i = full[w.id] { return i }
        load(w, size: 1800, into: \.full)
        return thumbs[w.id]               // пока грузится большая — растянутая миниатюра
    }

    private var pending = Set<String>()
    private func load(_ w: Wallpaper, size: Int, into key: ReferenceWritableKeyPath<WallpaperStore, [String: NSImage]>) {
        let tag = "\(w.id)#\(size)"
        guard !pending.contains(tag) else { return }
        pending.insert(tag)
        queue.async {
            guard let src = CGImageSourceCreateWithURL(w.url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: size,
                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async { self[keyPath: key][w.id] = img }
        }
    }
}

@available(macOS 26.0, *)
struct WallpaperView: View {
    let wallpaper: Wallpaper?
    @ObservedObject var store = WallpaperStore.shared
    var body: some View {
        GeometryReader { geo in
            if let w = wallpaper, let img = store.image(w) {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
                    .transition(.opacity)
                    .id(w.id)
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

// ===================================================================== превью
@available(macOS 26.0, *)
final class PreviewState: ObservableObject {
    let model = GlassRingModel()
    let pool: [RingItem]
    @Published var count = 9
    var hovering = false
    private(set) var driver: FocusDriver!
    private var bag = [AnyCancellable]()

    var items: [RingItem] { Array(pool.prefix(count)) }

    init() {
        // в превью — только классические приложения macOS, а не то, что сейчас запущено у пользователя
        let classic = ["/System/Library/CoreServices/Finder.app", "Safari", "Mail", "Messages", "Music", "Photos",
                       "Notes", "Calendar", "Maps", "FaceTime", "Reminders", "App Store", "System Settings",
                       "Preview", "Podcasts", "TV", "Books", "Weather"]
        var list: [RingItem] = []
        for name in classic where list.count < 16 {
            let paths = name.hasPrefix("/") ? [name]
                : ["/System/Applications", "/System/Cryptexes/App/System/Applications", "/Applications"].map { "\($0)/\(name).app" }
            if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                let title = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                list.append(RingItem(name: title, icon: NSWorkspace.shared.icon(forFile: path)))
            }
        }
        while list.count < 16 { list.append(RingItem(name: "App \(list.count + 1)", icon: NSWorkspace.shared.icon(for: .applicationBundle))) }
        pool = list
        model.prefs = Settings.shared.prefs
        model.appeared = true
        driver = FocusDriver(model: model, count: 9, selected: 1) { SettingsController.shared.visibleWindow }
        Settings.shared.$prefs.sink { [weak self] p in self?.model.prefs = p }.store(in: &bag)
    }

    func setCount(_ n: Int) {
        count = n
        driver.count = n
        model.selected = min(model.selected, n - 1)
        driver.aim(Double(model.selected))
    }

    func hover(dx: Double, dy: Double) {
        hovering = true
        guard hypot(dx, dy) > 6 else { return }
        let pos = RingGeometry.position(dx: dx, dy: dy, count: count)
        driver.setSelected(Int(pos.rounded()) % count)
        driver.setPointer(pos)
    }

    func hoverEnded() { hovering = false; driver.setPointer(nil) }

    /// Без курсора круг сам «листает» плитки — видно, как работает увеличение.
    func idleStep() {
        guard !hovering, NSApp.isActive, SettingsController.shared.visibleWindow != nil else { return }
        driver.setSelected((model.selected + 1) % count)
    }

    func replay() {
        model.appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(duration: 0.34, bounce: 0.26)) { self.model.appeared = true }
        }
    }
}

@available(macOS 26.0, *)
struct RingPreview: View {
    @ObservedObject var settings: Settings
    @StateObject private var state = PreviewState()
    @ObservedObject private var store = WallpaperStore.shared
    @AppStorage("previewWallpaper") private var wallpaperID = "Sonoma"
    @State private var replays = 0
    private let tick = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

    private var wallpaper: Wallpaper? { store.all.first { $0.id == wallpaperID } ?? store.all.first }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let side = RingLayout(count: state.count, prefs: settings.prefs).side
            let fit = min(1.0, (min(w - 24, h - 150) - 16) / side)
            ZStack {
                WallpaperView(wallpaper: wallpaper)
                    .animation(.easeInOut(duration: 0.35), value: wallpaperID)
                    .ignoresSafeArea()

                GlassRingRoot(items: state.items, fit: fit, behindWindow: false, model: state.model)
                    .position(x: w / 2, y: h / 2 - 20)
                    .allowsHitTesting(false)

                VStack {
                    Spacer()
                    controls.padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt): state.hover(dx: pt.x - w / 2, dy: (h / 2 - 20) - pt.y)
                case .ended: state.hoverEnded()
                }
            }
        }
        .clipped()
        .onAppear { state.replay() }
        .onReceive(tick) { _ in
            guard SettingsController.shared.visibleWindow != nil else { return }
            state.idleStep(); settings.refreshSystemGlass()
        }
    }

    /// Плавающая стеклянная панель: обои, число плиток, повтор появления.
    private var controls: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(store.all) { wp in
                        let on = wp.id == wallpaper?.id
                        Button { withAnimation(.smooth(duration: 0.3)) { wallpaperID = wp.id } } label: {
                            Group {
                                if let t = store.thumbs[wp.id] { Image(nsImage: t).resizable().scaledToFill() }
                                else { Color.white.opacity(0.15) }
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.white.opacity(on ? 1 : 0.25), lineWidth: on ? 2.5 : 1))
                            .overlay(alignment: .bottomTrailing) {
                                if wp.id == "desktop" {
                                    Image(systemName: "desktopcomputer").font(.system(size: 9, weight: .bold))
                                        .padding(3).background(.black.opacity(0.55), in: Circle()).offset(x: 3, y: 3)
                                }
                            }
                            .scaleEffect(on ? 1.08 : 1)
                            .padding(3)
                        }
                        .buttonStyle(CardButtonStyle(scale: 0.88))
                        .help(wp.title)
                    }
                }
                .padding(.horizontal, 6)
            }
            HStack(spacing: 10) {
                Text(wallpaper?.title ?? "").font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .contentTransition(.opacity).id(wallpaper?.id).transition(.opacity)
                Spacer(minLength: 0)
                Text("Плиток").font(.callout).foregroundStyle(.white.opacity(0.85))
                Stepper("", value: Binding(get: { state.count }, set: { n in withAnimation(.spring(duration: 0.35, bounce: 0.3)) { state.setCount(n) } }), in: 3...16).labelsHidden()
                Text("\(state.count)").contentTransition(.numericText(value: Double(state.count))).font(.callout.monospacedDigit()).foregroundStyle(.white).frame(width: 18)
                Button { state.replay(); replays += 1 } label: { Image(systemName: "play.fill").symbolEffect(.bounce, value: replays) }
                    .buttonStyle(.glass)
                    .pressBounce()
                    .help("Показать анимацию появления")
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

// ===================================================================== настройки
@available(macOS 26.0, *)
struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @State var tab: SettingsTab
    let tapRunning: () -> Bool
    @State private var trusted = AXIsProcessTrusted()
    @State private var running = false
    @State private var forward = true
    @Namespace private var tabNS
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            RingPreview(settings: settings)
                .frame(minWidth: 420, idealWidth: 450, maxWidth: 520)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
            .frame(minWidth: 460)
            .background(.background)
        }
        .frame(minHeight: 600)
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted(); running = tapRunning() }
        .onAppear { trusted = AXIsProcessTrusted(); running = tapRunning() }
    }

    private func select(_ t: SettingsTab) {
        guard t != tab else { return }
        let all = SettingsTab.allCases
        forward = all.firstIndex(of: t)! > all.firstIndex(of: tab)!
        // направление выставляем отдельным кадром — иначе уходящая вкладка уедет не в ту сторону
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.42, bounce: 0.18)) { tab = t }
        }
    }

    /// Свой сегмент-контрол: выбранная «таблетка» переезжает между вкладками.
    private var header: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { t in
                let on = t == tab
                Button { select(t) } label: {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if on {
                                Capsule().fill(Color.accentColor)
                                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: tabNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(CardButtonStyle(scale: 0.94))
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .frame(maxWidth: 300)
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 10)
        .sensoryFeedback(.selection, trigger: tab)
    }

    /// Все переключатели одной строкой — меняется ровно тогда, когда щёлкнули какой-то тумблер.
    private var togglesKey: [Bool] {
        let p = settings.prefs
        return [p.followSystemGlass, p.showLabel, p.tileColor, p.iconGlow, p.showPointer, p.appear,
                p.enabled, p.mouseSelect, p.centerCursor, p.quitKey, p.showPlate, p.magnify]
    }

    private var content: some View {
        let b = $settings.prefs
        let move = AnyTransition.asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
        return ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .look: LookTab(settings: settings, prefs: b)
                    case .motion: MotionTab(prefs: b)
                    case .system: SystemSection(prefs: b, trusted: trusted, running: running)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(.smooth(duration: 0.3), value: settings.prefs)
            }
            .scrollIndicators(.automatic)
            .id(tab)
            .transition(move)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .sensoryFeedback(.alignment, trigger: togglesKey)
    }
}

// ===================================================================== карточки-секции
/// Группа строк как в «Системных настройках»: заголовок, карточка, разделители между строками.
struct Card<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline).padding(.leading, 4) }
            Rows { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.leading, 4) }
        }
    }
}

/// Строки с разделителями; появляющиеся и исчезающие строки плавно въезжают сверху.
struct Rows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subs in
                ForEach(subs) { sub in
                    VStack(spacing: 0) {
                        if sub.id != subs.first?.id { Divider().padding(.horizontal, 12) }
                        sub.padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                            removal: .opacity))
                }
            }
        }
        .clipped()
    }
}

/// Сворачиваемая карточка: шеврон поворачивается, строки выезжают.
struct Expander<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.4, bounce: 0.12)) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 12)
                    Rows { content }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct PickerRow<V: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: V
    @ViewBuilder var options: Options
    init(_ title: String, selection: Binding<V>, @ViewBuilder options: () -> Options) {
        self.title = title; _selection = selection; self.options = options()
    }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: $selection) { options }.labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }
}

// ===================================================================== «Вид»
@available(macOS 26.0, *)
struct LookTab: View {
    @ObservedObject var settings: Settings
    @Binding var prefs: Prefs
    @AppStorage("lookFineTune") private var fine = false

    var body: some View {
        Card(title: "Стиль") {
            PresetRow(prefs: $prefs, presets: Presets.look)
        }
        if prefs.showPlate {
            Card(title: "Стекло") {
                PickerRow("Тема", selection: $prefs.theme) {
                    ForEach(Prefs.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ToggleRow("Liquid Glass как в системе", isOn: Binding(
                    get: { prefs.followSystemGlass },
                    set: { on in
                        // выключили — свой ползунок начинает с того, что сейчас стоит в системе
                        if !on { prefs.frost = settings.systemTint }
                        prefs.followSystemGlass = on
                    }))
                if !prefs.followSystemGlass {
                    SliderRow(title: "Прозрачность", value: $prefs.frost, range: Prefs.Limits.frost,
                              hint: "Слева прозрачное стекло, справа тонированное — как в «Оформлении».",
                              format: { $0 < 0.05 ? "прозрачное" : $0 > 0.95 ? "тонированное" : percent($0) })
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        Card(title: "Круг") {
            SliderRow(title: "Размер", value: $prefs.size, range: Prefs.Limits.size, format: percent)
            PickerRow("Форма иконок", selection: $prefs.iconShape) {
                Text("Как есть").tag(Prefs.IconShape.original)
                Text("Скруглённые").tag(Prefs.IconShape.squircle)
                Text("Круглые").tag(Prefs.IconShape.circle)
            }
            ToggleRow("Название приложения в центре", isOn: $prefs.showLabel)
            if prefs.showPlate {
                ToggleRow("Плитки в цвет иконки", isOn: $prefs.tileColor)
            }
        }
        Expander(title: "Тонкая настройка", expanded: $fine) {
            if prefs.showPlate {
                SliderRow(title: "Затемнение стекла", value: $prefs.shade, range: Prefs.Limits.shade, format: percent)
                SliderRow(title: "Подсветка выбранной плитки", value: $prefs.highlight, range: Prefs.Limits.highlight, format: percent)
            }
            SliderRow(title: "Затемнение экрана", value: $prefs.screenDim, range: Prefs.Limits.screenDim,
                      hint: "Помогает читать подписи на светлых обоях.", format: percent)
            if prefs.showPlate {
                SliderRow(title: "Зазор между плитками", value: $prefs.gap, range: Prefs.Limits.gap, format: pixels)
                SliderRow(title: "Скругление плиток", value: $prefs.corner, range: Prefs.Limits.corner, format: pixels)
                if prefs.tileColor {
                    SliderRow(title: "Сила окраски плиток", value: $prefs.tileColorAmount, range: Prefs.Limits.tileColorAmount, format: percent)
                }
                ToggleRow("Цветное свечение под иконкой", isOn: $prefs.iconGlow)
                if prefs.iconGlow {
                    SliderRow(title: "Сила свечения", value: $prefs.iconGlowAmount, range: Prefs.Limits.iconGlowAmount, format: percent)
                }
            }
            ToggleRow("Указатель направления", isOn: $prefs.showPointer)
            if prefs.showLabel {
                PickerRow("Смена названия", selection: $prefs.labelAnim) {
                    Text("Размытие").tag(Prefs.LabelAnim.blur)
                    Text("Сдвиг").tag(Prefs.LabelAnim.slide)
                    Text("Сразу").tag(Prefs.LabelAnim.none)
                }
            }
        }
    }
}

// ===================================================================== «Анимация»
@available(macOS 26.0, *)
struct MotionTab: View {
    @Binding var prefs: Prefs
    @AppStorage("motionFineTune") private var fine = false

    var body: some View {
        Card(title: "Увеличение под курсором") {
            PresetRow(prefs: $prefs, presets: Presets.magnify)
        }
        Card(title: "Отклик", footer: "Как быстро фокус догоняет курсор и насколько пружинит.") {
            PresetRow(prefs: $prefs, presets: Presets.spring)
        }
        Card(title: "Появление") {
            ToggleRow("Анимация появления", isOn: $prefs.appear)
            SliderRow(title: "Задержка показа", value: $prefs.showDelay, range: Prefs.Limits.showDelay,
                      hint: "Быстрый Cmd+Tab переключает без мигания: круг появится, только если держать дольше.") {
                $0 < 1 ? "сразу" : "\(Int($0.rounded())) мс"
            }
        }
        Expander(title: "Тонкая настройка", expanded: $fine) {
            Group {
                SliderRow(title: "Ширина зоны увеличения", value: $prefs.sigma, range: Prefs.Limits.sigma,
                          hint: "Сколько соседних плиток подтягиваются за выбранной.") { String(format: "%.1f", $0) }
                SliderRow(title: "Ширина плитки в фокусе", value: $prefs.widen, range: Prefs.Limits.widen, format: { "+" + percent($0) })
                SliderRow(title: "Размер иконки в фокусе", value: $prefs.iconGain, range: Prefs.Limits.iconGain, format: { "+" + percent($0) })
                SliderRow(title: "Выезд наружу", value: $prefs.lift, range: Prefs.Limits.lift, format: pixels)
            }
            .disabled(!prefs.magnify)
            .opacity(prefs.magnify ? 1 : 0.45)
            SliderRow(title: "Скорость", value: $prefs.speed, range: Prefs.Limits.speed) { String(format: "%.0f", $0) }
            SliderRow(title: "Затухание", value: $prefs.damping, range: Prefs.Limits.damping,
                      hint: "Меньше — фокус пружинит и чуть перелетает, больше — садится ровно.") { String(format: "%.2f", $0) }
            SliderRow(title: "Притяжение к середине плитки", value: $prefs.magnet, range: Prefs.Limits.magnet, format: percent)
        }
    }
}

// ===================================================================== «Основное»
@available(macOS 26.0, *)
struct SystemSection: View {
    @Binding var prefs: Prefs
    let trusted: Bool
    let running: Bool
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?
    @State private var confirmReset = false

    var body: some View {
        let ok = trusted && running
        Card {
            HStack(spacing: 12) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(ok ? Color.green : Color.orange)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ok ? "Всё работает" : "Нужен «Универсальный доступ»").font(.headline)
                    Text(ok ? "Rondo перехватывает Cmd+Tab."
                            : "Разреши Rondo в «Конфиденциальность и безопасность → Универсальный доступ».")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !ok {
                    Button("Открыть") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.borderedProminent)
                    .pressBounce()
                }
            }
            .padding(.vertical, 2)
        }
        Card(title: "Управление") {
            ToggleRow("Заменить системный Cmd+Tab", isOn: $prefs.enabled)
            ToggleRow("Выбор мышью и трекпадом", isOn: $prefs.mouseSelect)
            ToggleRow("Курсор в центр круга", isOn: $prefs.centerCursor)
            ToggleRow("Q закрывает выбранное приложение", isOn: $prefs.quitKey)
        }
        Card(title: "Запуск") {
            ToggleRow("Открывать при входе в систему", isOn: Binding(get: { login }, set: { on in withAnimation(.smooth) { setLogin(on) } }))
            if let loginNote { Text(loginNote).font(.caption).foregroundStyle(.secondary) }
        }
        Card {
            HStack {
                Text("Rondo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Сбросить настройки…", role: .destructive) { confirmReset = true }
                    .pressBounce()
                    .confirmationDialog("Вернуть все настройки вида и анимации к исходным?", isPresented: $confirmReset) {
                        Button("Сбросить", role: .destructive) { withAnimation(.smooth) { Settings.shared.reset() } }
                    }
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let s = SMAppService.mainApp.status
            login = s == .enabled || s == .requiresApproval
            loginNote = s == .requiresApproval ? "Разреши Rondo в «Основные → Объекты входа»." : nil
        } catch {
            login = SMAppService.mainApp.status == .enabled
            loginNote = "Не получилось: \(error.localizedDescription)"
        }
    }
}
#endif
