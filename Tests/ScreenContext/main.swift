import Foundation
import CoreGraphics

var failures = 0
var count = 0
func check(_ name: String, _ value: @autoclosure () -> Bool) {
    count += 1
    if !value() { failures += 1; print("FAIL: \(name)") } else { print("PASS: \(name)") }
}
let small = CGRect(x: 20, y: 30, width: 300, height: 200)
let large = CGRect(x: 400, y: 50, width: 900, height: 700)
let windows = [ScreenWindowCandidate(pid: 10, id: 1, layer: 0, frame: large),
               ScreenWindowCandidate(pid: 10, id: 2, layer: 0, frame: small)]
check("Выбрано маленькое сфокусированное окно", ScreenWindowPolicy.select(pid: 10, frame: small, windowID: nil, from: windows) == 2)
check("Собственное окно сопоставлено по идентификатору", ScreenWindowPolicy.select(pid: 10, frame: nil, windowID: 1, from: windows) == 1)
check("Собственный неизвестный идентификатор исключён", ScreenWindowPolicy.select(pid: 10, frame: small, windowID: 9, from: windows) == nil)
check("Другой процесс исключён", ScreenWindowPolicy.select(pid: 11, frame: small, windowID: nil, from: windows) == nil)
check("Без доказательства фокуса нет окна", ScreenWindowPolicy.select(pid: 10, frame: nil, windowID: nil, from: windows) == nil)
check("Совпадающие рамки неоднозначны", ScreenWindowPolicy.select(pid: 10, frame: small, windowID: nil, from: windows + [ScreenWindowCandidate(pid: 10, id: 3, layer: 0, frame: small)]) == nil)
check("Служебный слой исключён", ScreenWindowPolicy.select(pid: 10, frame: small, windowID: nil, from: [ScreenWindowCandidate(pid: 10, id: 4, layer: 1, frame: small)]) == nil)
check("Допустимо округление рамки", ScreenWindowPolicy.select(pid: 10, frame: small.offsetBy(dx: 0.5, dy: -0.5), windowID: nil, from: windows) == 2)
check("Сдвиг рамки не выбирает соседнее окно", ScreenWindowPolicy.select(pid: 10, frame: small.offsetBy(dx: 3, dy: 0), windowID: nil, from: windows) == nil)
let invalid = CGRect(x: CGFloat.nan, y: 0, width: 300, height: 200)
check("Некорректная рамка исключена", ScreenWindowPolicy.select(pid: 10, frame: invalid, windowID: nil, from: windows) == nil)

// Строки обозначают разные окна одного процесса, затем окно другого процесса.
var state = ScreenContextState<String>()
let first = state.begin(focus: "10:small", now: 100)!
check("Первый запрос начат", first.focus == "10:small")
check("Повторный запрос того же окна не запущен", state.begin(focus: "10:small", now: 101) == nil)
check("Первый результат опубликован", state.complete(first, windowID: 2, text: "SMALL", now: 101))
check("Текст доступен своему окну", state.text(focus: "10:small", now: 102) == "SMALL")
check("Текст недоступен после смены окна того же процесса", state.text(focus: "10:large", now: 102) == nil)
let second = state.begin(focus: "10:large", now: 102)!
check("Смена окна снимает троттлинг", second.focus == "10:large")
let third = state.begin(focus: "11:other", now: 102)!
check("Устаревший результат не опубликован", !state.complete(second, windowID: 1, text: "LARGE", now: 103))
state.finish(second)
check("Старый запрос не завершает новый", state.begin(focus: "11:other", now: 106) == nil)
check("Новый результат опубликован", state.complete(third, windowID: 8, text: "OTHER", now: 103))
check("Другой процесс не читает текст", state.text(focus: "10:small", now: 104) == nil)
let fourth = state.begin(focus: "11:other", now: 104)!
check("Кэш привязан к точному окну", state.cached(fourth, windowID: 9, now: 104) == nil)
check("Свежий кэш точного окна доступен", state.cached(fourth, windowID: 8, now: 104) == "OTHER")
check("Старый кэш исключён", state.cached(fourth, windowID: 8, now: 114) == nil)
state.observe(nil)
check("Потеря фокуса инвалидирует выполняющийся запрос", !state.complete(fourth, windowID: 8, text: "LATE", now: 105))
check("Без фокуса нет текста", state.text(focus: nil, now: 105) == nil)
let fifth = state.begin(focus: "10:small", now: 110)!
_ = state.complete(fifth, windowID: 2, text: "FRESH", now: 110)
check("Троттлинг действует внутри одного окна", state.begin(focus: "10:small", now: 112) == nil)
check("Старый текст исключён", state.text(focus: "10:small", now: 126) == nil)
var switched = ScreenContextState<String>()
let oldSmall = switched.begin(focus: "10:small", now: 0)!
let newLarge = switched.begin(focus: "10:large", now: 1)!
check("Старый снимок того же PID не публикуется после смены окна", !switched.complete(oldSmall, windowID: 2, text: "OLD SMALL", now: 2))
let newSmall = switched.begin(focus: "10:small", now: 2)!
check("Возврат в то же окно не оживляет устаревший запрос", !switched.complete(oldSmall, windowID: 2, text: "OLD SMALL", now: 3))
switched.finish(newLarge)
check("Завершение другого окна не сбрасывает текущий запрос", switched.begin(focus: "10:small", now: 6) == nil)
check("Актуальный запрос после возврата публикуется", switched.complete(newSmall, windowID: 2, text: "NEW SMALL", now: 3))
var ttl = ScreenContextState<String>()
let original = ttl.begin(focus: "window", now: 0)!
_ = ttl.complete(original, windowID: 1, text: "OLD", now: 0)
let reuse = ttl.begin(focus: "window", now: 3)!
check("Повторное использование кэша завершает запрос", ttl.complete(reuse, windowID: 1, text: "OLD", now: 3, reusingCache: true))
let later = ttl.begin(focus: "window", now: 6)!
check("Чтение кэша не продлевает срок снимка", ttl.cached(later, windowID: 1, now: 10) == nil)
check("Повторное использование кэша не продлевает срок текста", ttl.text(focus: "window", now: 16) == nil)
check("Отказ разрешения исключает OCR", !ScreenWindowPolicy.allowed(pid: 10, frontmostPID: 10, permission: false, excluded: false))
check("Исключённое приложение не снимается", !ScreenWindowPolicy.allowed(pid: 10, frontmostPID: 10, permission: true, excluded: true))
check("Фоновый процесс не снимается", !ScreenWindowPolicy.allowed(pid: 10, frontmostPID: 11, permission: true, excluded: false))
check("Активное разрешённое приложение допускается", ScreenWindowPolicy.allowed(pid: 10, frontmostPID: 10, permission: true, excluded: false))
print("screen context: \(count) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
