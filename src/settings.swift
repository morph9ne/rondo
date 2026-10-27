// Настройки RingTab: одна структура, хранится в UserDefaults как JSON. Без AppKit — тестируется отдельно.
import Foundation
import Combine

struct Prefs: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable { case dark, light, system }
    enum GlassStyle: String, Codable, CaseIterable { case clear, regular }
    /// Форма иконок: как прислало приложение, все — скруглённым квадратом, все — кругом.
    enum IconShape: String, Codable, CaseIterable { case original, squircle, circle }
    /// Как меняется название в центре при смене выбора.
    enum LabelAnim: String, Codable, CaseIterable { case blur, slide, none }

    // --- внешний вид
    var theme = Theme.dark
    var glass = GlassStyle.clear
    var shade = 0.22            // затемнение стекла плиток, 0…0.6
    var followSystemGlass = true  // стекло как в «Оформление → Liquid Glass»; иначе своё значение frost
    var frost = 0.0             // своё значение того же ползунка Liquid Glass, 0…1: 0 — прозрачное, 1 — тонированное
    var highlight = 0.16        // подсветка выбранной плитки, 0…0.5
    var screenDim = 0.04        // затемнение экрана за кругом, 0…0.6
    var size = 1.0              // масштаб круга, 0.7…1.5
    var gap = 7.0               // зазор между плитками, 2…16
    var corner = 13.0           // скругление плиток, 0…26
    var tileColor = false       // плитки окрашиваются в цвет иконки
    var tileColorAmount = 0.6   // сила окраски, 0…1
    var iconGlow = false        // иконка растекается мягким цветным пятном внутри плитки
    var iconGlowAmount = 0.9    // сила пятна, 0…1
    var iconShape = IconShape.squircle  // единая форма иконок
    var showPlate = true        // стеклянная подложка под иконками; выкл. — только иконки поверх рабочего стола
    var showLabel = true        // название приложения в центре
    var labelAnim = LabelAnim.blur  // смена названия: размытие / сдвиг / без анимации
    var showPointer = true      // дуга-указатель на краю центра

    // --- увеличение как в доке
    var magnify = true
    var sigma = 0.8             // сколько плиток вокруг фокуса увеличивается, 0.4…1.8
    var widen = 0.6             // насколько плитка в фокусе шире, 0…1.2
    var iconGain = 0.38         // насколько иконка в фокусе крупнее, 0…0.9
    var lift = 18.0             // на сколько плитка выезжает наружу, 0…36 px

    // --- движение
    var speed = 24.0            // скорость пружины, 10…48
    var damping = 0.86          // затухание пружины, 0.4…1.3 (меньше — пружинит сильнее)
    var magnet = 0.4            // притяжение фокуса к середине плитки, 0…1
    var appear = true           // анимация появления
    var showDelay = 150.0       // задержка показа круга, мс, 0…500

    // --- система
    var enabled = true          // перехватывать Cmd+Tab
    var mouseSelect = true      // выбор мышью и трекпадом
    var quitKey = true          // Q закрывает выбранное приложение
    var centerCursor = true     // при появлении круга курсор переезжает в его центр

    static let standard = Prefs()

    /// Допустимые диапазоны — одни и те же для слайдеров и для проверки того, что прочитано с диска.
    enum Limits {
        static let tileColorAmount = 0.0...1.0, iconGlowAmount = 0.0...1.0
        static let shade = 0.0...0.6, frost = 0.0...1.0, highlight = 0.0...0.5, screenDim = 0.0...0.6
        static let size = 0.7...1.5, gap = 2.0...16.0, corner = 0.0...26.0
        static let sigma = 0.4...1.8, widen = 0.0...1.2, iconGain = 0.0...0.9, lift = 0.0...36.0
        static let speed = 10.0...48.0, damping = 0.4...1.3, magnet = 0.0...1.0, showDelay = 0.0...500.0
    }

    /// Возвращает копию, где всё вернулось в допустимые границы (испорченный файл не сломает круг).
    func clamped() -> Prefs {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound }
        var p = self
        p.shade = c(shade, Limits.shade); p.frost = c(frost, Limits.frost); p.highlight = c(highlight, Limits.highlight); p.screenDim = c(screenDim, Limits.screenDim)
        p.size = c(size, Limits.size); p.gap = c(gap, Limits.gap); p.corner = c(corner, Limits.corner)
        p.tileColorAmount = c(tileColorAmount, Limits.tileColorAmount); p.iconGlowAmount = c(iconGlowAmount, Limits.iconGlowAmount)
        p.sigma = c(sigma, Limits.sigma); p.widen = c(widen, Limits.widen)
        p.iconGain = c(iconGain, Limits.iconGain); p.lift = c(lift, Limits.lift)
        p.speed = c(speed, Limits.speed); p.damping = c(damping, Limits.damping); p.magnet = c(magnet, Limits.magnet)
        p.showDelay = c(showDelay, Limits.showDelay)
        return p
    }

    /// Увеличение из настроек: при выключенном остаются только базовые размеры.
    var magnifier: Magnifier {
        magnify ? Magnifier(sigma: sigma, widen: widen, iconGain: iconGain, lift: lift)
                : Magnifier(sigma: sigma, widen: 0, iconGain: 0, lift: 0)
    }

    // Поля, которых нет в сохранённом JSON (старая версия), берут значения по умолчанию.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        theme = v(.theme, d.theme); glass = v(.glass, d.glass)
        shade = v(.shade, d.shade); frost = v(.frost, glass == .regular ? 1 : 0); followSystemGlass = v(.followSystemGlass, d.followSystemGlass); highlight = v(.highlight, d.highlight); screenDim = v(.screenDim, d.screenDim)
        size = v(.size, d.size); gap = v(.gap, d.gap); corner = v(.corner, d.corner)
        iconShape = v(.iconShape, d.iconShape)
        tileColor = v(.tileColor, d.tileColor); tileColorAmount = v(.tileColorAmount, d.tileColorAmount)
        iconGlow = v(.iconGlow, d.iconGlow); iconGlowAmount = v(.iconGlowAmount, d.iconGlowAmount)
        showPlate = v(.showPlate, d.showPlate); showLabel = v(.showLabel, d.showLabel); labelAnim = v(.labelAnim, d.labelAnim); showPointer = v(.showPointer, d.showPointer)
        magnify = v(.magnify, d.magnify); sigma = v(.sigma, d.sigma); widen = v(.widen, d.widen)
        iconGain = v(.iconGain, d.iconGain); lift = v(.lift, d.lift)
        speed = v(.speed, d.speed); damping = v(.damping, d.damping); magnet = v(.magnet, d.magnet)
        appear = v(.appear, d.appear); showDelay = v(.showDelay, d.showDelay)
        enabled = v(.enabled, d.enabled); mouseSelect = v(.mouseSelect, d.mouseSelect); quitKey = v(.quitKey, d.quitKey)
        centerCursor = v(.centerCursor, d.centerCursor)
        self = clamped()
    }

    static func decode(_ data: Data?) -> Prefs {
        guard let data, let p = try? JSONDecoder().decode(Prefs.self, from: data) else { return Prefs() }
        return p
    }
    func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Живые настройки: меняются из окна настроек, читаются кругом и меню. Каждое изменение сразу пишется на диск.
final class Settings: ObservableObject {
    /// RINGTAB_SUITE — отдельный набор настроек для снимков и отладки, чтобы не трогать настоящие.
    static let shared = Settings(defaults: ProcessInfo.processInfo.environment["RINGTAB_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard)
    private let defaults: UserDefaults
    private let key = "prefs.v1"

    @Published var prefs: Prefs {
        didSet {
            if let d = prefs.encoded() { defaults.set(d, forKey: key) }
            if prefs.followSystemGlass != oldValue.followSystemGlass || prefs.frost != oldValue.frost { Self.applyGlassTint(prefs) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var p = Prefs.decode(defaults.data(forKey: key))
        // старое отдельное значение «перехватывать Cmd+Tab» из первых версий
        if defaults.data(forKey: key) == nil, let old = defaults.object(forKey: "enabled") as? Bool { p.enabled = old }
        prefs = p
        Self.applyGlassTint(p)
    }

    /// Тот же ключ, что пишет системный ползунок Liquid Glass, но только в домене RingTab: AppKit берёт значение
    /// приложения поверх общего, поэтому стекло меняется ровно как в системе. Без своего значения — работает общее.
    /// Текущее значение системного ползунка Liquid Glass (общий домен, без значения RingTab).
    static func systemGlassTint() -> Double {
        let v = (CFPreferencesCopyValue("NSGlassTintAmount" as CFString, kCFPreferencesAnyApplication,
                                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.doubleValue ?? 0
        return min(max(v, 0), 1)
    }

    /// Системное значение на момент последней проверки (перечитывается при показе круга и в окне настроек).
    @Published private(set) var systemTint = Settings.systemGlassTint()
    func refreshSystemGlass() {
        let v = Self.systemGlassTint()
        guard abs(v - systemTint) > 0.001 else { return }
        systemTint = v
        if prefs.followSystemGlass { Self.applyGlassTint(prefs) }
    }
    /// Положение ползунка Liquid Glass, которое сейчас действует: системное или своё.
    var glassLevel: Double { prefs.followSystemGlass ? systemTint : prefs.frost }

    /// Ползунок Liquid Glass 0…1 → вид стекла. 0 — прозрачное `.clear`, как «Прозрачное» в системе (там все
    /// элементы максимально прозрачны). Дальше плавно, одним слоем стекла, без наложения двух стёкол:
    /// матовость — размытие подложки под стеклом (растёт на 0…0.5), тонировка — цвет стекла и NSGlassTintAmount (растёт на 0.35…1).
    static func frostBlur(_ level: Double) -> Double {
        let t = min(1, max(0, level / 0.5))
        return t * t * (3 - 2 * t)
    }
    /// Радиус размытия подложки, пт: растёт плавно на 0…0.6 ползунка.
    static func frostRadius(_ level: Double) -> Double { 30 * min(1, max(0, level / 0.6)) }
    static func glassTint(_ level: Double) -> Double { min(1, max(0, (level - 0.35) / 0.65)) }

    static func applyGlassTint(_ p: Prefs) {
        let level = p.followSystemGlass ? systemGlassTint() : p.frost
        UserDefaults.standard.set(glassTint(level), forKey: "NSGlassTintAmount")  // ключ системного ползунка
        // этим уведомлением AppKit сам перечитывает настройку и перерисовывает всё стекло на лету
        NotificationCenter.default.post(name: Notification.Name("NSGlassEffectDiffusionDidChangeNotification"), object: nil)
    }

    func reset() { prefs = Prefs(enabled: prefs.enabled) }
}

extension Prefs {
    init(enabled: Bool) { self.init(); self.enabled = enabled }
}
