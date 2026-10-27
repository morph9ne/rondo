// Rondo (бывший RingTab) — круговой переключатель приложений вместо системного Cmd+Tab (меню-бар).
// Режимы:  RingTab                  — приложение в меню-баре
//          RingTab --cli [-v]       — то же, но лог в терминал (разрешение нужно терминалу)
//          RingTab --demo [файл]    — показать круг на пару секунд без перехвата, сохранить PNG
import AppKit
import CoreGraphics
import ApplicationServices
import Combine

let args = CommandLine.arguments
let verbose = args.contains("-v")
let logT0 = DispatchTime.now()
func log(_ s: @autoclosure () -> String) {
    guard verbose else { return }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - logT0.uptimeNanoseconds) / 1e6
    print(String(format: "[%7.0f] ", ms) + s())
}

let kTab: Int64 = 48, kEsc: Int64 = 53, kQ: Int64 = 12
let kLeft: Int64 = 123, kRight: Int64 = 124, kDown: Int64 = 125, kUp: Int64 = 126

// ===================================================================== приложения
func isSwitchable(_ a: NSRunningApplication) -> Bool {
    a.activationPolicy == .regular && !a.isTerminated && a.processIdentifier != getpid()
}

/// Готовые плитки по pid. Сборка одной (`a.icon` + анализ цвета + две растеризации формы) стоит ~19 мс,
/// на 10 приложений это ~190 мс при каждом Cmd+Tab — поэтому собираем заранее и держим.
enum ItemCache {
    private static var items: [pid_t: RingItem] = [:]
    private static var queue: [NSRunningApplication] = []
    private static var pumping = false

    static func item(for a: NSRunningApplication) -> RingItem {
        if let it = items[a.processIdentifier] { return it }
        let it = RingItem(name: a.localizedName ?? "?",
                          icon: a.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
        items[a.processIdentifier] = it
        return it
    }

    static func drop(_ pid: pid_t) { items[pid] = nil; queue.removeAll { $0.processIdentifier == pid } }

    /// Подгружает плитки по одной за оборот цикла событий: окно настроек и мышь не подвисают.
    static func prefetch(_ apps: [NSRunningApplication]) {
        queue.append(contentsOf: apps.filter { items[$0.processIdentifier] == nil })
        guard !pumping else { return }
        pumping = true
        func pump() {
            while let a = queue.first, items[a.processIdentifier] != nil || a.isTerminated { queue.removeFirst() }
            guard !queue.isEmpty else { pumping = false; return }
            _ = item(for: queue.removeFirst())
            DispatchQueue.main.async { pump() }
        }
        DispatchQueue.main.async { pump() }
    }
}

func makeItem(_ a: NSRunningApplication) -> RingItem { ItemCache.item(for: a) }

/// Переключение. Вызывается из обработчика event tap, пока система держит клавиатуру, — блокировать нельзя:
/// AX-запрос к занятому приложению ждёт ответа до секунды-полутора, и всё это время не работали ни клавиши, ни круг
/// (а потом система вообще отключала перехват по таймауту). Поэтому `activate` — сразу (он не ждёт),
/// а AX «выйти на передний план» — в фоне, с коротким таймаутом и только если выбор с тех пор не поменялся.
private let axQueue = DispatchQueue(label: "ringtab.activate", qos: .userInitiated)
private let axLock = NSLock()
private var axGeneration = 0

func activate(_ app: NSRunningApplication) {
    if app.isHidden { app.unhide() }
    app.activate(options: [.activateAllWindows])
    axLock.lock(); axGeneration += 1; let gen = axGeneration; axLock.unlock()
    let pid = app.processIdentifier
    axQueue.async {
        axLock.lock(); let stale = gen != axGeneration; axLock.unlock()
        guard !stale else { return }                       // уже выбрали другое — не перебиваем
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}

// ===================================================================== сессия переключения
final class Switcher {
    var enabled: Bool {
        get { Settings.shared.prefs.enabled }
        set { Settings.shared.prefs.enabled = newValue }
    }
    var recency = Recency<pid_t>()
    let overlay = Overlay()

    private(set) var active = false { didSet { TapMirror.shared.setActive(active) } }
    private var list: [NSRunningApplication] = []
    private var sel = RingSelection(count: 0, backwards: false)
    private var origin = NSPoint.zero          // где был курсор при открытии
    private var ringCenter = NSPoint.zero         // центр экрана, где открылся круг
    private var mouseEngaged = false           // курсор сдвинут — выбор переходит к мыши
    private var showWork: DispatchWorkItem?
    private var poll: Timer?
    private var globalMouse: Any?

    init() {
        overlay.onMove = { [weak self] p in self?.mouseMoved(p) }
        overlay.onClick = { [weak self] p in self?.clicked(p) }
    }

    // ---- недавность
    func seedRecency() {
        var order: [pid_t] = []
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
            for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
                if let pid = w[kCGWindowOwnerPID as String] as? pid_t, !order.contains(pid) { order.append(pid) }
            }
        }
        let regular = NSWorkspace.shared.runningApplications.filter(isSwitchable)
        let alive = Set(regular.map { $0.processIdentifier })
        var ids = order.filter { alive.contains($0) }
        if let f = NSWorkspace.shared.frontmostApplication?.processIdentifier, alive.contains(f) {
            ids.removeAll { $0 == f }; ids.insert(f, at: 0)
        }
        for a in regular where !ids.contains(a.processIdentifier) { ids.append(a.processIdentifier) }
        recency.reset(ids)
        // плитки заранее: в порядке недавности, чтобы первые Cmd+Tab были готовы раньше
        let byPid = Dictionary(regular.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        ItemCache.prefetch(ids.compactMap { byPid[$0] })
        #if SYSTEM_GLASS
        log("стекло: SwiftUI .glassEffect")
        #else
        log(DiscView.glassClass != nil ? "стекло: NSGlassEffectView (рантайм)" : "стекло: размытие NSVisualEffectView")
        #endif
        log("недавность: " + ids.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }.joined(separator: " > "))
    }

    func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        func app(_ n: Notification) -> NSRunningApplication? {
            n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n), isSwitchable(a) { self?.recency.touch(a.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n), isSwitchable(a) { self?.recency.append(a.processIdentifier); ItemCache.prefetch([a]) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n) { self?.recency.remove(a.processIdentifier); ItemCache.drop(a.processIdentifier) }
        }
    }

    // ---- исполнение клавиш. Вызывается в ГЛАВНОМ потоке (из очереди), решение «съесть/пропустить»
    // принимает TapMirror в потоке перехвата — клавиатура не ждёт ни UI, ни иконки, ни стекло.
    func handleKey(type: CGEventType, code: Int64, flags: CGEventFlags) {
        switch type {
        case .keyDown:
            if !active {
                guard enabled, code == kTab, flags.contains(.maskCommand),
                      !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return }
                begin(backwards: flags.contains(.maskShift))
                return
            }
            switch code {
            case kTab:           step(backwards: flags.contains(.maskShift))
            case kRight, kDown:  step(backwards: false)
            case kLeft, kUp:     step(backwards: true)
            case kEsc:           cancel()
            case kQ:             if Settings.shared.prefs.quitKey { quitSelected() }
            default: break
            }
        case .flagsChanged:
            if active && !flags.contains(.maskCommand) { commit() }
        default:
            break
        }
    }

    /// Через пару секунд после запуска (плитки уже собраны) — невидимый показ круга для прогрева стекла.
    /// Окно круга иногда «прилипает» к одному рабочему столу и на полноэкранных столах не видно.
    /// Поэтому при каждой смене стола невидимо показываем его там же — окно остаётся тёплым.
    func observeSpaces() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [self] _ in
            // не пересоздаём (холодное стекло = нет анимации), а лишь невидимо показываем то же окно
            // на новом столе — система заново привязывает его к текущему столу.
            log("смена стола — перепривязываю окно круга")
            prewarm(after: 0.6)
        }
    }

    func prewarm(after delay: Double = 2.0, tries: Int = 12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            // занято (идёт сессия круга или предыдущий прогрев) — не бросаем перепривязку, а повторяем чуть позже:
            // иначе окно навсегда остаётся на старом столе и на новом круг не виден
            guard !active, !overlay.isShown else {
                if tries > 0 { prewarm(after: 0.4, tries: tries - 1) }
                return
            }
            let apps = recency.items.prefix(6).compactMap { NSRunningApplication(processIdentifier: $0) }.filter(isSwitchable)
            overlay.prewarm(items: apps.map(makeItem), mouse: NSEvent.mouseLocation)
        }
    }

    func tapWasDisabled() { if active { log("tap отключён системой — отмена сессии"); cancel() } }

    // ---- жизнь сессии
    private func begin(backwards: Bool) {
        list = recency.items.compactMap { NSRunningApplication(processIdentifier: $0) }.filter(isSwitchable)
        guard !list.isEmpty else { TapMirror.shared.setActive(false); return }
        sel = RingSelection(count: list.count, backwards: backwards)
        origin = NSEvent.mouseLocation
        mouseEngaged = false
        active = true
        log("старт: \(list.count) приложений, выбрано «\(list[sel.index].localizedName ?? "?")»")

        // защита: если Cmd отпустили, а событие потерялось — не залипнуть
        if !args.contains("--no-poll") { poll = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            if !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) { self.commit() }
        } }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.mouseMoved(NSEvent.mouseLocation)
        }
        // круг показываем с задержкой: быстрый тап Cmd+Tab обходится без мигания
        let w = DispatchWorkItem { [weak self] in self?.present() }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.prefs.showDelay / 1000, execute: w)
    }

    private func present() {
        guard active else { return }
        let wasShown = overlay.isShown
        ringCenter = overlay.show(items: list.map(makeItem), selected: sel.index, mouse: origin)
        if !wasShown && Settings.shared.prefs.centerCursor { warpCursor(to: ringCenter) }
    }

    /// Курсор — в центр круга: оттуда до любой плитки одинаково близко. Отсчёт «сдвинул мышь» тоже от центра,
    /// чтобы сам перенос не считался движением и не перехватывал выбор у клавиатуры.
    private func warpCursor(to p: NSPoint) {
        moveCursor(to: p)
        origin = p
        mouseEngaged = false
    }

    /// Перенос без «залипания»: по умолчанию после CGWarp система ~0.25 с глотает движения мыши —
    /// отсюда и замирание, если в этот момент вести мышь. Обнуляем этот интервал.
    private func moveCursor(to p: NSPoint) {
        // CGWarpMouseCursorPosition uses a global coordinate system whose
        // vertical origin is the top edge of the main display.  `p` is in
        // AppKit's global (bottom-left) coordinates, so use the actual main
        // display as the conversion anchor.  `NSScreen.screens.first` is not
        // guaranteed to be the main display when monitors are reconfigured.
        guard let main = NSScreen.main else { return }
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: main.frame.maxY - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func step(backwards: Bool) {
        sel.step(backwards: backwards)
        // клавиатура забирает фокус у мыши; мышь вернёт его, только если её снова сдвинуть
        mouseEngaged = false
        origin = NSEvent.mouseLocation
        overlay.point(nil)
        if overlay.isShown { overlay.select(sel.index) }
    }

    private func mouseMoved(_ p: NSPoint, force: Bool = false) {
        guard active, overlay.isShown, !list.isEmpty, Settings.shared.prefs.mouseSelect else { return }
        if !mouseEngaged {
            guard hypot(p.x - origin.x, p.y - origin.y) > 12 || force else { return }
            mouseEngaged = true
        }
        // направление от центра круга — везде: на плитках, за кругом и внутри центрального диска
        let dx = p.x - ringCenter.x, dy = p.y - ringCenter.y
        guard hypot(dx, dy) > 6 else { return }          // в самой середине направления нет
        let pos = RingGeometry.position(dx: dx, dy: dy, count: list.count)
        let i = Int(pos.rounded()) % list.count
        if i != sel.index { sel.index = i; overlay.select(i) }
        overlay.point(pos)
    }

    /// Клик выбирает плитку в направлении курсора и сразу переключает.
    private func clicked(_ p: NSPoint) {
        guard active else { return }
        if Settings.shared.prefs.mouseSelect { mouseMoved(p, force: true) }
        commit()
    }

    private func quitSelected() {
        guard list.indices.contains(sel.index) else { return }
        let app = list[sel.index]
        log("Q: закрываю «\(app.localizedName ?? "?")»")
        // terminate() only requests termination.  If macOS rejects the
        // request, keep the item in the session and let the user try again.
        guard app.terminate() else {
            log("Q: приложение отклонило завершение")
            return
        }
        recency.remove(app.processIdentifier)
        let removed = sel.index
        list.remove(at: removed)
        sel.shrink(removing: removed)
        if list.isEmpty { cancel(); return }
        if overlay.isShown { overlay.remove(index: removed, items: list.map(makeItem), selected: sel.index) }
    }

    func commit() {
        guard active else { return }
        let target = list.indices.contains(sel.index) ? list[sel.index] : nil
        end()
        if let t = target {
            log("→ «\(t.localizedName ?? "?")»")
            activate(t)
        }
    }

    func cancel() {
        guard active else { return }
        log("отмена")
        end()
    }

    private func end() {
        active = false
        showWork?.cancel(); showWork = nil
        poll?.invalidate(); poll = nil
        if let m = globalMouse { NSEvent.removeMonitor(m); globalMouse = nil }
        overlay.hide()
        list = []
    }
}

// --hitch: сторож главного потока — раз в 4 мс пингует его с фонового и печатает залипания дольше 25 мс.
func startHitchWatch() {
    DispatchQueue.global().async {
        while true {
            let t = DispatchTime.now(); let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { sem.signal() }
            sem.wait()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6
            if ms > 25 { log(String(format: "ЗАЛИПАНИЕ главного потока %.0f мс", ms)) }
            usleep(4000)
        }
    }
}

// ===================================================================== event tap
/// Минимальное состояние для решения «съесть клавишу или пропустить» — читается из потока перехвата,
/// поэтому под замком и без обращений к главному потоку/Settings/AppKit. Тяжёлую работу делает Switcher в main.
final class TapMirror {
    static let shared = TapMirror()
    private let lock = NSLock()
    private var active = false
    private var enabled = true
    private var swallowed = Set<Int64>()

    func setActive(_ v: Bool) { lock.lock(); active = v; lock.unlock() }
    func setEnabled(_ v: Bool) {
        lock.lock()
        enabled = v
        // If the setting is switched off while Cmd is held, clear the
        // speculative active state set by the tap thread.  Otherwise the
        // next key events could be swallowed until a restart.
        if !v {
            active = false
            swallowed.removeAll()
        }
        lock.unlock()
    }

    /// swallow — съесть событие; forward — отдать в главный поток на исполнение.
    func decide(type: CGEventType, code: Int64, flags: CGEventFlags) -> (swallow: Bool, forward: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch type {
        case .keyDown:
            if !active {
                guard enabled, code == kTab, flags.contains(.maskCommand),
                      !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return (false, false) }
                swallowed.insert(code)
                active = true            // сразу: следующие клавиши уже идут в сессию, не дожидаясь main
                return (true, true)
            }
            swallowed.insert(code)
            return (true, true)
        case .keyUp:
            return (swallowed.remove(code) != nil, false)
        case .flagsChanged:
            return (false, active && !flags.contains(.maskCommand))
        default:
            return (false, false)
        }
    }
}

final class TapController {
    let switcher: Switcher
    private(set) var tap: CFMachPort?
    private var thread: Thread?
    private var bag = [AnyCancellable]()
    init(_ s: Switcher) { switcher = s }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.keyUp.rawValue)
                 | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let loc: CGEventTapLocation = args.contains("--session-tap") ? .cgSessionEventTap : .cghidEventTap
        guard let t = CGEvent.tapCreate(tap: loc, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
            let c = Unmanaged<TapController>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                log(type == .tapDisabledByTimeout ? "tap: отключён по таймауту" : "tap: отключён пользовательским вводом")
                if let t = c.tap { CGEvent.tapEnable(tap: t, enable: true) }
                DispatchQueue.main.async { c.switcher.tapWasDisabled() }
                return Unmanaged.passUnretained(event)
            }
            // Быстрый путь: всё нужное берём из события и решаем здесь, не трогая главный поток.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let d = TapMirror.shared.decide(type: type, code: code, flags: flags)
            if d.forward { DispatchQueue.main.async { c.switcher.handleKey(type: type, code: code, flags: flags) } }
            return d.swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = t

        // «Включён ли перехват» — зеркалом для потока перехвата (настройка меняется из UI в главном потоке).
        Settings.shared.$prefs.map(\.enabled).removeDuplicates()
            .sink { TapMirror.shared.setEnabled($0) }.store(in: &bag)

        // Отдельный поток с высоким приоритетом: клавиши не стоят в очереди за UI RingTab.
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        let th = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "RingTab.keytap"
        th.qualityOfService = .userInteractive
        thread = th
        th.start()
        log("event tap создан (\(loc == .cghidEventTap ? "hid" : "session")), отдельный поток")
        return true
    }
}

// ===================================================================== меню-бар
final class MenuBar: NSObject {
    let switcher: Switcher
    let tapController: TapController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let toggle = NSMenuItem(title: "Перехватывать Cmd+Tab", action: #selector(toggleEnabled), keyEquivalent: "")
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let access = NSMenuItem(title: "Открыть «Универсальный доступ»…", action: #selector(openAccess), keyEquivalent: "")
    private var bag = [AnyCancellable]()

    init(_ s: Switcher, _ t: TapController) {
        switcher = s; tapController = t
        super.init()
        item.button?.image = MenuBar.glyph()
        let menu = NSMenu()
        status.isEnabled = false
        menu.addItem(status)
        toggle.target = self; access.target = self
        menu.addItem(toggle)
        menu.addItem(access)
        menu.addItem(.separator())
        #if SYSTEM_GLASS
        if #available(macOS 26.0, *) {
            let prefs = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
            prefs.target = self
            menu.addItem(prefs)
            menu.addItem(.separator())
        }
        #endif
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        item.menu = menu
        refresh()
        // «Перехватывать» можно переключить и из окна настроек — меню следует за ним
        Settings.shared.$prefs.map(\.enabled).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
    }

    /// Значок меню-бара — тот же рисунок, что на иконке: кольцо из плиток, выбранная крупнее, точка в центре.
    /// Шаблонный (одноцветный): система сама красит его под светлую и тёмную строку меню.
    static func glyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = CGPoint(x: 9, y: 9), n = 8, focus = 1
            let w: [Double] = (0..<n).map { i in let d = Double(min(abs(i - focus), n - abs(i - focus))); return 1 + 0.5 * exp(-d * d / 0.9) }
            let sum = w.reduce(0, +)
            var start = 0.0
            let off = Double.pi / 4 + (w[0] + w[1] / 2) / sum * 2 * .pi
            NSColor.black.setFill()
            for i in 0..<n {
                let wi = w[i] / sum * 2 * .pi, mid = off - (start + wi / 2); start += wi
                let sel = i == focus, half = wi / 2 - 0.2
                let r0: CGFloat = sel ? 4.6 : 5.0, r1: CGFloat = sel ? 9.0 : 8.0
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: r1, startAngle: (mid - half) * 180 / .pi, endAngle: (mid + half) * 180 / .pi)
                p.appendArc(withCenter: c, radius: r0, startAngle: (mid + half) * 180 / .pi, endAngle: (mid - half) * 180 / .pi, clockwise: true)
                p.close(); p.fill()
            }
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.9, y: c.y - 1.9, width: 3.8, height: 3.8)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Rondo"
        return img
    }

    func refresh() {
        toggle.state = switcher.enabled ? .on : .off
        access.isHidden = tapController.isRunning
        status.title = tapController.isRunning ? (switcher.enabled ? "Работает" : "Выключен")
                                               : "Нет доступа: нужен «Универсальный доступ»"
    }

    @objc private func toggleEnabled() {
        switcher.enabled.toggle()
        if !switcher.enabled { switcher.cancel() }
        refresh()
    }
    @objc private func openAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    #if SYSTEM_GLASS
    @available(macOS 26.0, *)
    @objc private func openSettings() { SettingsController.shared.show(tap: tapController) }
    #endif
}

// ===================================================================== demo
func runDemo() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let outPath = args.drop(while: { $0 != "--demo" }).dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
    let apps = NSWorkspace.shared.runningApplications.filter(isSwitchable)
    let items = apps.map(makeItem)
    guard !items.isEmpty else { print("нет приложений"); exit(1) }
    let selected = min(1, items.count - 1)
    #if SYSTEM_GLASS
    // та же SwiftUI-раскладка, что в живом круге; --focus 1.4 — фокус между плитками (как при наведении)
    if #available(macOS 26.0, *), let path = outPath {
        let focus = args.drop(while: { $0 != "--focus" }).dropFirst().first.flatMap(Double.init) ?? Double(selected)
        let sel = Int(focus.rounded()) % items.count
        let png = MainActor.assumeIsolated { renderGlassRingPNG(items: items, selected: sel, focus: focus) }
        guard let png else { print("не удалось отрисовать круг"); exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("демо: \(items.count) приложений, фокус \(focus)\nкартинка круга: \(path)")
        exit(0)
    }
    #endif
    let overlay = Overlay()
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let mid = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    // для --shot: цветные полосы за кругом, чтобы было видно размытие и преломление
    var backdrop: NSWindow?
    if args.contains("--shot") {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .normal; w.isOpaque = true
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        let g = CAGradientLayer()
        g.frame = v.bounds
        g.colors = [NSColor.systemBlue, .systemPink, .systemYellow, .systemGreen, .systemPurple, .systemOrange].map { $0.cgColor }
        g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
        v.layer = g
        if let img = ProcessInfo.processInfo.environment["RB_IMG"].flatMap({ NSImage(contentsOfFile: $0) }) {
            g.contents = img; g.contentsGravity = .resizeAspectFill
        }
        w.contentView = v
        w.orderFront(nil)
        backdrop = w
    }
    _ = backdrop
    overlay.show(items: items, selected: selected, mouse: mid)
    print("демо: \(items.count) приложений")
    // --shot файл: живой круг (настоящее стекло) снимаем сами — свои окна видны без Screen Recording
    if let shot = args.drop(while: { $0 != "--shot" }).dropFirst().first {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                let fn = unsafeBitCast(sym, to: Fn.self)
                let r = CGDisplayBounds(CGMainDisplayID())
                if let cg = fn(r, 1, 0, 0)?.takeRetainedValue() {      // OnScreenOnly, все окна
                    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                    try? png?.write(to: URL(fileURLWithPath: shot))
                    print("снимок: \(shot) \(cg.width)x\(cg.height)")
                } else { print("снимок не получился (nil)") }
            } else { print("нет CGWindowListCreateImage") }
            exit(0)
        }
        app.run()
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        if let path = outPath {
            if let png = overlay.snapshotPNG() {
                try? png.write(to: URL(fileURLWithPath: path))
                print("картинка круга: \(path)")
            } else { print("не удалось отрисовать круг") }
        }
        // перебор выбора, чтобы глазом проверить подсветку
        overlay.select(items.count > 2 ? 2 : 0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (outPath == nil ? 4 : 1.4)) { exit(0) }
    app.run()
    exit(0)
}


// ===================================================================== bench
// --bench [секунд]: быстро водит фокус по кольцу и печатает, как держатся кадры и сколько съедает процессор.
func runBench() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let items = NSWorkspace.shared.runningApplications.filter(isSwitchable).map(makeItem)
    guard !items.isEmpty else { print("нет приложений"); exit(1) }
    let secs = args.drop(while: { $0 != "--bench" }).dropFirst().first.flatMap(Double.init) ?? 6
    let overlay = Overlay()
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let mid = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    overlay.show(items: items, selected: 0, mouse: mid)
    let n = Double(items.count)
    let t0 = CACurrentMediaTime()
    var last = t0, gaps: [Double] = []
    func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
    var c0 = 0.0
    // «мышь» ~250 событий в секунду, туда-сюда по кругу
    // --keys [Гц]: вместо мыши — очередь нажатий Tab с заданной частотой (долбёжка Cmd+Tab); по секундам печатает худший кадр
    let keyHz = args.drop(while: { $0 != "--keys" }).dropFirst().first.flatMap(Double.init)
    var keyIdx = 0
    var perSec: [[Double]] = []
    Timer.scheduledTimer(withTimeInterval: 1.0 / (keyHz ?? 250), repeats: true) { _ in
        let t = CACurrentMediaTime() - t0
        if t < 1 { return }
        if keyHz != nil { keyIdx = (keyIdx + 1) % items.count; overlay.select(keyIdx); return }
        overlay.point(((t * 9).truncatingRemainder(dividingBy: n * 2)) < n ? (t * 9).truncatingRemainder(dividingBy: n) : n - (t * 9).truncatingRemainder(dividingBy: n))
    }
    let link = screen.displayLink(target: BenchTick { now in
        if now - t0 > 1 {
            gaps.append((now - last) * 1000)
            let sec = Int(now - t0) - 1
            while perSec.count <= sec { perSec.append([]) }
            perSec[sec].append((now - last) * 1000)
        }
        last = now
    }, selector: #selector(BenchTick.tick(_:)))
    link.add(to: .main, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c0 = cpu() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + secs) {
        let used = cpu() - c0
        let s = gaps.sorted()
        func q(_ f: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * f))] }
        let over = gaps.filter { $0 > 1000.0 / 60 * 1.5 }.count
        print(String(format: "кадров %d, интервал медиана %.1f мс, p95 %.1f, p99 %.1f, макс %.1f; пропусков (>25 мс) %d; процессор %.0f%% одного ядра",
                     gaps.count, q(0.5), q(0.95), q(0.99), s.last ?? 0, over, used / secs * 100))
        if keyHz != nil {
            print("по секундам (худший кадр, мс / кадров): " + perSec.enumerated().map { String(format: "%d:%.0f/%d", $0.offset + 1, $0.element.max() ?? 0, $0.element.count) }.joined(separator: "  "))
        }
        exit(0)
    }
    app.run()
    exit(0)
}
final class BenchTick: NSObject {
    let f: (Double) -> Void
    init(_ f: @escaping (Double) -> Void) { self.f = f }
    @objc func tick(_ l: CADisplayLink) { f(l.timestamp) }
}

// ===================================================================== latency
// --latency: сколько проходит от вызова show() до первой отправленной картинки (холодный и повторный показ).
func runLatency() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let items = NSWorkspace.shared.runningApplications.filter(isSwitchable).map(makeItem)
    guard !items.isEmpty else { print("нет приложений"); exit(1) }
    for k in 1...3 {
        let t = CACurrentMediaTime()
        let apps = NSWorkspace.shared.runningApplications.filter(isSwitchable)
        let t1 = CACurrentMediaTime()
        _ = apps.map(makeItem)
        print(String(format: "список приложений #%d: %.1f мс, makeItem×%d: %.1f мс", k, (t1 - t) * 1000, apps.count, (CACurrentMediaTime() - t1) * 1000))
    }
    let overlay = Overlay()
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let mid = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    var t0 = 0.0, tShow = 0.0, commits: [Double] = []
    // CA отправляет кадр в observer'е BeforeWaiting (порядок 2_000_000); наш идёт сразу за ним
    let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { _, _ in
        if t0 > 0 && commits.count < 6 { commits.append((CACurrentMediaTime() - t0) * 1000) }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    var round = 0
    func next() {
        round += 1
        commits = []
        t0 = CACurrentMediaTime()
        overlay.show(items: items, selected: 1, mouse: mid)
        tShow = (CACurrentMediaTime() - t0) * 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            print(String(format: "%@: show() вернулся за %.1f мс; отправка кадров через (мс): %@", round == 1 ? (args.contains("--no-prewarm") ? "холодный" : "после прогрева") : "повторный \(round - 1)",
                         tShow, commits.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
            overlay.hide()
            if round < 4 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } } else { exit(0) }
        }
    }
    if args.contains("--no-prewarm") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
    } else {
        overlay.prewarm(items: Array(items.prefix(6)), mouse: mid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
    }
    app.run()
    exit(0)
}

// ===================================================================== запуск
setvbuf(stdout, nil, _IOLBF, 0)
if args.contains("--demo") { runDemo() }
if args.contains("--bench") { runBench() }
if args.contains("--latency") { runLatency() }

let nsapp = NSApplication.shared
nsapp.setActivationPolicy(.accessory)

let switcher = Switcher()
switcher.seedRecency()
switcher.observeWorkspace()
switcher.prewarm()
switcher.observeSpaces()
if args.contains("--hitch") { startHitchWatch() }
let tapController = TapController(switcher)
let cliMode = args.contains("--cli")
let menu: MenuBar? = cliMode ? nil : MenuBar(switcher, tapController)

let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) { log("нет разрешения «Универсальный доступ» — жду…") }

// пока доступа нет, пробуем раз в секунду; как выдадут — перехват включается сам
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
    if tapController.start() { t.invalidate(); log("перехват включён") }
    menu?.refresh()
}.fire()

#if SYSTEM_GLASS
// --settings [--tab N] [--shot-window файл.png]: сразу открыть окно настроек (и снять его — для проверки вида)
if #available(macOS 26.0, *), args.contains("--settings") {
    let tabIndex = args.drop(while: { $0 != "--tab" }).dropFirst().first.flatMap(Int.init) ?? 0
    let tab = SettingsTab.allCases[min(max(tabIndex, 0), SettingsTab.allCases.count - 1)]
    DispatchQueue.main.async {
        SettingsController.shared.show(tap: tapController, tab: tab)
        guard let file = args.drop(while: { $0 != "--shot-window" }).dropFirst().first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard let w = SettingsController.shared.window else { exit(1) }
            typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                let fn = unsafeBitCast(sym, to: Fn.self)
                // optionIncludingWindow = 1<<3, boundsIgnoreFraming = 1<<0
                if let cg = fn(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: file))
                    print("снимок окна: \(file) \(cg.width)x\(cg.height)")
                } else { print("снимок окна не получился") }
            }
            exit(0)
        }
    }
}
#endif

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { exit(0) }
sigint.resume()

nsapp.run()
