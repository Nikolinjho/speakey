import Foundation

var checks = 0, failures = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
// Синтетические абзацы: AXValue содержит переводы строк, AXStringForRange их не считает.
let value = "Первая\nВторая\nТретья "
let ranged = "ПерваяВтораяТретья " as NSString
func readRange(_ range: NSRange) -> CompletionFieldText.RangeRead {
    guard range.location <= ranged.length, range.length <= ranged.length - range.location else { return .outOfBounds }
    return .text(ranged.substring(with: range))
}
let end = ranged.length
let after = CompletionFieldText.read(NSRange(location: end, length: 2), truncatingAtEnd: true,
                                     readRange: readRange, fullValue: { value })
expect(after == "", "Конец многоабзацного поля не получает ложную букву из AXValue")
let middle = CompletionFieldText.read(NSRange(location: end - 3, length: 5), truncatingAtEnd: true,
                                      readRange: readRange, fullValue: { value })
expect(middle == ranged.substring(from: end - 3), "Настоящий хвост сохраняется при завышенной длине поля")
let before = CompletionFieldText.read(NSRange(location: 0, length: end), readRange: readRange, fullValue: { value })
expect(before == ranged as String, "Текст до каретки остаётся в координатах AXStringForRange")
expect(CompletionFieldText.read(NSRange(location: end, length: 2), readRange: readRange, fullValue: { value }) == nil,
       "Обязательный диапазон не подменяется срезом другого представления")
expect(CompletionFieldText.read(NSRange(location: 0, length: 3), readRange: { _ in .unsupported }, fullValue: { "Тест" }) == "Тес",
       "Редактор без диапазонного API сохраняет резервное чтение AXValue")
expect(CompletionFieldText.read(NSRange(location: 0, length: 3), truncatingAtEnd: true,
                                readRange: { _ in .unavailable }, fullValue: { "Тест" }) == nil,
       "Временная ошибка AX не превращается в другой текст")
expect(CompletionFieldText.read(NSRange(location: 4, length: 1), readRange: { _ in .unsupported }, fullValue: { "Тест" }) == nil,
       "Недоступный диапазон резервного значения не читается")
expect(CompletionFieldText.read(NSRange(location: 0, length: 2), truncatingAtEnd: true,
                                readRange: { _ in .outOfBounds }, fullValue: { "Тест" }) == nil,
       "Пустой хвост требует подтверждения корректной начальной позиции")
expect(CompletionFieldText.read(NSRange(location: 0, length: 2), readRange: { _ in .text("Т") }, fullValue: { "Тест" }) == nil,
       "Неполный успешный ответ не принимается за точный диапазон")
let unicode = "ёж😀" as NSString
let emoji = CompletionFieldText.read(NSRange(location: 2, length: 4), truncatingAtEnd: true,
    readRange: { r in
        guard r.location <= unicode.length, r.length <= unicode.length - r.location else { return .outOfBounds }
        return .text(unicode.substring(with: r))
    }, fullValue: { "ёж\n😀\n" })
expect(emoji == "😀", "Граница восстанавливается в UTF16 без потери emoji")
expect(!CompletionFieldText.allowsFallbackPreview(after: .unavailable, confirmsEnd: { true }),
       "Таймаут чтения справа скрывает подсказку")
expect(!CompletionFieldText.allowsFallbackPreview(after: .unsupported, confirmsEnd: { true }),
       "Недоступное чтение справа скрывает подсказку")
expect(!CompletionFieldText.allowsFallbackPreview(after: .outOfBounds, confirmsEnd: { false }),
       "Ошибка диапазона без подтверждённого конца поля скрывает подсказку")
expect(CompletionFieldText.allowsFallbackPreview(after: .outOfBounds, confirmsEnd: { true }),
       "Подтверждённый конец поля допускает подсказку")
expect(!CompletionFieldText.allowsFallbackPreview(after: .text(""), confirmsEnd: { false }),
       "Пустой ответ внутри поля скрывает подсказку")
expect(!CompletionFieldText.allowsFallbackPreview(after: .text("ё"), confirmsEnd: { true }),
       "Видимый текст справа важнее заявленной длины поля")
expect(CompletionFieldText.allowsFallbackPreview(after: .text("\r\n"), confirmsEnd: { false }),
       "Перевод строки подтверждает место для подсказки")
print("completion field text: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
