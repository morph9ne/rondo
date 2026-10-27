import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failed += 1; print("FAIL (line \(line)): \(what)") }
}

// сектора для 8 иконок: верх=0, право=2, низ=4, лево=6
check(RingGeometry.sector(dx: 0, dy: 1, count: 8) == 0, "верх")
check(RingGeometry.sector(dx: 1, dy: 0, count: 8) == 2, "право")
check(RingGeometry.sector(dx: 0, dy: -1, count: 8) == 4, "низ")
check(RingGeometry.sector(dx: -1, dy: 0, count: 8) == 6, "лево")
check(RingGeometry.sector(dx: 1, dy: 1, count: 8) == 1, "верх-право")
check(RingGeometry.sector(dx: -0.01, dy: 1, count: 8) == 0, "чуть левее верха")
check(RingGeometry.sector(dx: -1, dy: 1, count: 8) == 7, "верх-лево")
// 3 иконки: 0 сверху, 1 справа-снизу (120° по часовой), 2 слева-снизу
check(RingGeometry.sector(dx: 1, dy: -0.5, count: 3) == 1, "3: право-низ")
check(RingGeometry.sector(dx: -1, dy: -0.5, count: 3) == 2, "3: лево-низ")
check(RingGeometry.sector(dx: 5, dy: 5, count: 1) == 0, "1 иконка")
// иконка влезает в плитку: размер не больше задуманного, видимая часть не касается краёв
for n in 3...24 {
    let m = RingGeometry.metrics(count: n)
    let s = RingGeometry.fittedIcon(size: m.icon * 1.4, center: m.radius, half: .pi / Double(n), inner: m.inner, outer: m.outer, gap: 7)
    let h = s * 0.8 / 2
    check(s > 10 && s <= m.icon * 1.4, "fit n=\(n)")
    check((m.radius - h) * sin(.pi / Double(n)) - h * cos(.pi / Double(n)) >= 3.5 + 6 - 1e-6, "fit бок n=\(n)")
}
// позиция индекса 0 — сверху, индекса 2 из 8 — справа
let p0 = RingGeometry.offset(index: 0, count: 8, radius: 100)
check(abs(p0.x) < 1e-9 && abs(p0.y - 100) < 1e-9, "offset 0")
let p2 = RingGeometry.offset(index: 2, count: 8, radius: 100)
check(abs(p2.x - 100) < 1e-9 && abs(p2.y) < 1e-9, "offset 2")
// каждый сектор попадает сам в себя (для любого count)
for n in 1...40 {
    for i in 0..<n {
        let o = RingGeometry.offset(index: i, count: n, radius: 50)
        check(RingGeometry.sector(dx: o.x, dy: o.y, count: n) == i, "roundtrip n=\(n) i=\(i)")
    }
}
// метрики: иконки не меньше минимума, круг ограничен
for n in [1, 5, 10, 20, 40] {
    let m = RingGeometry.metrics(count: n)
    check(m.icon >= 34 && m.icon <= 64 && m.radius >= 135 && m.radius <= 330, "metrics n=\(n)")
}
// кусочки торта: середина своего сектора внутри, центр и чужие сектора снаружи
for n in [2, 3, 5, 8, 12, 20] {
    let m = RingGeometry.metrics(count: n)
    check(m.inner > 60 && m.inner < m.radius && m.radius < m.outer, "границы n=\(n)")
    for i in 0..<n {
        let w = RingGeometry.wedgePath(index: i, count: n, inner: m.inner, outer: m.outer, gap: 7, corner: 13)
        let mid = RingGeometry.offset(index: i, count: n, radius: m.radius)
        check(w.contains(mid), "wedge n=\(n) i=\(i) содержит свою иконку")
        check(!w.contains(.zero), "wedge n=\(n) i=\(i) без центра")
        let bb = w.boundingBoxOfPath
        check(max(abs(bb.minX), abs(bb.maxX), abs(bb.minY), abs(bb.maxY)) <= m.outer + 0.5, "wedge n=\(n) в пределах outer")
        let next = RingGeometry.offset(index: (i + 1) % n, count: n, radius: m.radius)
        check(!w.contains(next), "wedge n=\(n) i=\(i) не залезает на соседа")
    }
}
// быстрый контур совпадает с эталонным (объединение контуров) почти везде
for n in [1, 2, 3, 5, 8, 12, 20, 30] {
    let m = RingGeometry.metrics(count: n)
    for (g, c, f) in [(7.0, 13.0, 1.0), (2.0, 4.0, 1.0), (16.0, 30.0, 1.0), (7.0, 13.0, 0.5), (7.0, 13.0, 0.25), (7.0, 20.0, 0.3)] {
        let sw = 2 * Double.pi / Double(n) * f
        let a = RingGeometry.wedgePath(from: -sw / 2, to: sw / 2, inner: m.inner, outer: m.outer, gap: g, corner: c)
        let b = RingGeometry.wedgePathClipped(from: -sw / 2, to: sw / 2, inner: m.inner, outer: m.outer, gap: g, corner: c)
        let narrow = sw <= 2 * asin(min((g / 2 + c) / (m.inner + c), 1))
        if narrow {
            // старый способ тут рисовал кляксу; проверяем, что новый контур остаётся в своём секторе
            let bb = a.boundingBoxOfPath
            check(!a.contains(.zero) && bb.minY > m.inner * 0.5 && bb.maxY <= m.outer + 0.5, "узкая плитка n=\(n) f=\(f)")
            check(a.isEmpty || bb.height > 1, "узкая плитка n=\(n) f=\(f) не вырождена")
            continue
        }
        var bad = 0, total = 0
        let R = m.outer + 2
        for yi in 0..<120 { for xi in 0..<120 {
            let pt = CGPoint(x: -R + 2 * R * Double(xi) / 119, y: -R + 2 * R * Double(yi) / 119)
            let ia = a.contains(pt), ib = b.contains(pt)
            if ia || ib { total += 1; if ia != ib { bad += 1 } }
        } }
        check(total > 0 && Double(bad) / Double(total) < 0.02, "контур n=\(n) g=\(g) c=\(c): расхождение \(bad)/\(total)")
    }
}
let single = RingGeometry.wedgePath(index: 0, count: 1, inner: 80, outer: 190, gap: 7, corner: 13)
check(single.contains(CGPoint(x: 0, y: 130)) && !single.contains(.zero), "кольцо для одного приложения")
// увеличение как в доке
let mag = Magnifier()
func wrapped(_ a: Double) -> Double { var x = a.truncatingRemainder(dividingBy: 2 * .pi); if x < 0 { x += 2 * .pi }; return x }
for n in [2, 3, 5, 8, 12, 20] {
    let sw = 2 * Double.pi / Double(n)
    let m = RingGeometry.metrics(count: n)
    var prev: [Magnifier.Tile]? = nil
    var f = -0.5
    while f < Double(n) + 0.5 {
        let t = mag.layout(count: n, focus: f)
        // плитки идут подряд и закрывают весь круг
        let sum = t.reduce(0) { $0 + ($1.end - $1.start) }
        check(abs(sum - 2 * .pi) < 1e-9, "mag n=\(n) f=\(f) сумма углов")
        for i in 1..<n { check(abs(t[i].start - t[i - 1].end) < 1e-9, "mag n=\(n) стык \(i)") }
        // направление фокуса попадает в ту же плитку, что и sector()
        let k = Int(f.rounded()) % n, fk = (k + n) % n
        let dir = wrapped(f * sw)
        let lo = wrapped(t[fk].start)
        check(wrapped(dir - lo) <= t[fk].end - t[fk].start + 1e-9, "mag n=\(n) f=\(f) курсор в своей плитке \(fk)")
        // плавность: шаг фокуса 0.01 двигает плитки меньше чем на 2°
        if let p = prev {
            for i in 0..<n {
                let dm = abs(remainder(t[i].mid - p[i].mid, 2 * .pi))
                check(dm < 0.035, "mag n=\(n) f=\(f) рывок плитки \(i): \(dm)")
            }
        }
        prev = t
        f += 0.01
    }
    // в целой позиции фокуса плитка стоит ровно на своём месте и самая широкая
    for i in 0..<n {
        let t = mag.layout(count: n, focus: Double(i))
        check(abs(remainder(t[i].mid - Double(i) * sw, 2 * .pi)) < 1e-9, "mag n=\(n) i=\(i) на месте")
        let wmax = t.map { $0.end - $0.start }.max()!
        check(abs((t[i].end - t[i].start) - wmax) < 1e-9 && t[i].weight == 1, "mag n=\(n) i=\(i) самая широкая")
        // увеличенная иконка (без скруглённых углов ~12%) влезает в свою плитку
        let w = RingGeometry.wedgePath(from: t[i].start, to: t[i].end, inner: m.inner, outer: mag.outer(m, 1), gap: 7, corner: 13)
        let c = CGPoint(x: cos(RingGeometry.math(t[i].mid)) * mag.iconRadius(m, 1),
                        y: sin(RingGeometry.math(t[i].mid)) * mag.iconRadius(m, 1))
        let h = mag.iconSize(m, 1) / 2 * 0.80
        // квадрат иконки стоит ровно (не повёрнут), проверяем углы и середины сторон
        for (dx, dy) in [(-h, -h), (h, -h), (-h, h), (h, h), (0, -h * 1.1), (0, h * 1.1), (-h * 1.1, 0), (h * 1.1, 0)] {
            check(w.contains(CGPoint(x: c.x + dx, y: c.y + dy)), "mag n=\(n) i=\(i) иконка влезает (\(dx), \(dy))")
        }
        check(mag.outer(m, 1) * 2 <= mag.diameter(m), "mag n=\(n) вид вмещает выехавшую плитку")
    }
}
// скорость: перестройка 20 плиток должна укладываться в кадр с запасом
let t0 = Date()
for k in 0..<60 {
    let m = RingGeometry.metrics(count: 20)
    for t in mag.layout(count: 20, focus: Double(k) * 0.1) {
        _ = RingGeometry.wedgePath(from: t.start, to: t.end, inner: m.inner, outer: mag.outer(m, t.weight), gap: 7, corner: 13)
    }
}
let perFrame = Date().timeIntervalSince(t0) / 60 * 1000
print(String(format: "плитки: %.2f мс на кадр (20 шт.)", perFrame))
check(perFrame < 4, "перестройка плиток быстрее 4 мс")

// недавность
var r = Recency<Int>()
r.reset([1, 2, 3])
r.touch(3); check(r.items == [3, 1, 2], "touch")
r.remove(1); check(r.items == [3, 2], "remove")
r.append(2); r.append(9); check(r.items == [3, 2, 9], "append")
// выбор
var s = RingSelection(count: 5, backwards: false); check(s.index == 1, "старт — предыдущее приложение")
s.step(backwards: false); check(s.index == 2, "вперёд")
s.step(backwards: true); s.step(backwards: true); s.step(backwards: true); check(s.index == 4, "назад с заворотом")
s = RingSelection(count: 5, backwards: true); check(s.index == 4, "Shift: старт с конца")
s = RingSelection(count: 1, backwards: false); check(s.index == 0, "одно приложение")
s = RingSelection(count: 4, backwards: false); s.shrink(removing: 1); check(s.count == 3 && s.index == 1, "shrink")
s = RingSelection(count: 3, backwards: true); s.shrink(removing: 2); check(s.index == 1, "shrink последнего")

// ---- настройки
do {
    let d = Prefs()
    check(d.theme == .dark && d.glass == .clear, "по умолчанию тёмная тема и прозрачное стекло")
    // круг туда-обратно через JSON
    var p = Prefs(); p.theme = .light; p.glass = .regular; p.sigma = 1.2; p.magnify = false; p.showDelay = 300
    check(Prefs.decode(p.encoded()) == p, "JSON туда-обратно")
    // старый файл без новых полей: берутся значения по умолчанию, а известные поля сохраняются
    let old = #"{"theme":"light","shade":0.4}"#.data(using: .utf8)
    let o = Prefs.decode(old)
    check(o.theme == .light && o.shade == 0.4 && o.frost == 0 && o.lift == d.lift && o.magnify == d.magnify, "старый JSON без полей")
    // мусор не ломает круг
    check(Prefs.decode(Data("не json".utf8)) == d, "мусор → значения по умолчанию")
    check(Prefs.decode(nil) == d, "нет данных → значения по умолчанию")
    let bad = #"{"size":99,"speed":-5,"gap":1e9,"theme":"неизвестная"}"#.data(using: .utf8)
    let b = Prefs.decode(bad)
    check(b.size == Prefs.Limits.size.upperBound && b.speed == Prefs.Limits.speed.lowerBound &&
          b.gap == Prefs.Limits.gap.upperBound && b.theme == d.theme, "значения вне диапазона возвращаются в границы")
    // выключенное увеличение = плитки равной ширины и иконки без роста
    var q = Prefs(); q.magnify = false
    let t = q.magnifier.layout(count: 8, focus: 2.3)
    check(t.allSatisfy { abs(($0.end - $0.start) - 2 * Double.pi / 8) < 1e-9 }, "без увеличения плитки равны")
    check(q.magnifier.iconSize(RingGeometry.metrics(count: 8), 1) == RingGeometry.metrics(count: 8).icon, "без увеличения иконка не растёт")
    // масштаб круга
    let m1 = RingGeometry.metrics(count: 10), m2 = RingGeometry.metrics(count: 10, scale: 1.5)
    check(abs(m2.diameter - m1.diameter * 1.5) < 1e-9 && abs(m2.inner - m1.inner * 1.5) < 1e-9, "масштаб метрик")
    // хранилище: изменение пишется на диск и читается новым экземпляром
    let ud = UserDefaults(suiteName: "ringtab.test.\(getpid())")!
    ud.removePersistentDomain(forName: "ringtab.test.\(getpid())")
    let st = Settings(defaults: ud)
    st.prefs.frost = 0.5; st.prefs.enabled = false
    let st2 = Settings(defaults: ud)
    check(st2.prefs.frost == 0.5 && st2.prefs.enabled == false, "настройки сохраняются")
    st2.reset()
    check(st2.prefs.frost == d.frost && st2.prefs.enabled == false, "сброс не выключает перехват заново")
    ud.removePersistentDomain(forName: "ringtab.test.\(getpid())")
}

// удаление плитки: в конце сжатия раскладка совпадает с новым кругом (на n−1) с точностью до поворота
do {
    let mag = Magnifier()
    for n in [3, 5, 10, 16] { for d in 0..<n { for fo in [0.0, 0.3, -0.3] {
        let f0 = Double(d) + fo
        let before = mag.layout(count: n, focus: f0, removing: d, collapse: 1)
        var x = f0
        while x < Double(d) - Double(n) / 2 { x += Double(n) }
        while x >= Double(d) + Double(n) / 2 { x -= Double(n) }
        var f = x - min(max(x - (Double(d) - 0.5), 0), 1)
        f = f.truncatingRemainder(dividingBy: Double(n - 1)); if f < 0 { f += Double(n - 1) }
        let after = mag.layout(count: n - 1, focus: f)
        let sp = remainder(before[(d + 1) % n].mid - after[d % (n - 1)].mid, 2 * .pi)
        var bad = 0.0
        for i in 0..<n where i != d {
            let j = i < d ? i : i - 1
            bad = max(bad, abs(remainder(before[i].mid - after[j].mid - sp, 2 * .pi)),
                      abs(before[i].weight - after[j].weight),
                      abs((before[i].end - before[i].start) - (after[j].end - after[j].start)))
        }
        check(bad < 1e-6, "удаление плитки без скачка n=\(n) d=\(d) f=\(fo): \(bad)")
    } } }
    let m1 = RingGeometry.metrics(effective: 15), m2 = RingGeometry.metrics(count: 15)
    check(abs(m1.radius - m2.radius) < 1e-9, "дробные метрики совпадают с целыми")
}

print(failed == 0 ? "OK: все проверки прошли" : "ПРОВАЛЕНО: \(failed)")
exit(failed == 0 ? 0 : 1)
