import Foundation

enum BufferTests: DiagnosticSuite {
    static let name = "buffer"
    static func run(_ tests: DiagnosticTests) {
        let buffer = KeystrokeBuffer()
        buffer.append("hello")
        let first = buffer.currentOccurrenceID
        buffer.applyConversion(converted: "руддщ")
        tests.check("Живая замена сохраняет идентичность слова", buffer.currentOccurrenceID == first)
        buffer.boundary(" ")
        tests.check("Граница переносит идентичность завершённому слову", buffer.lastOccurrenceID == first && buffer.currentOccurrenceID == nil)
        buffer.applyCompletedConversion(converted: "hello")
        tests.check("Замена завершённого слова сохраняет идентичность", buffer.lastOccurrenceID == first)
        buffer.backspace()
        buffer.backspace()
        tests.check("Возврат из завершённого слова сохраняет идентичность", buffer.currentOccurrenceID == first)
        for _ in 0..<4 { buffer.backspace() }
        tests.check("Полное стирание сохраняет связь для перенабора", buffer.retypingOccurrenceID == first && buffer.currentOccurrenceID == nil)
        buffer.append("other")
        tests.check("Новый физический токен получает отдельную идентичность", buffer.currentOccurrenceID != first && buffer.currentOccurrenceID != nil)
        tests.check("Перенабор хранит отдельную ссылку на старый токен", buffer.retypingOccurrenceID == first)
        buffer.boundary(" ")
        tests.check("Новая граница завершает связь перенабора", buffer.retypingOccurrenceID == nil && buffer.lastOccurrenceID != first)
        buffer.append("a")
        buffer.boundary(" ")
        let single = buffer.lastOccurrenceID
        buffer.backspace()
        buffer.backspace()
        tests.check("Стирание однобуквенного завершённого слова сохраняет связь", buffer.retypingOccurrenceID == single)
        var resets = 0
        buffer.onContextReset = { resets += 1 }
        buffer.clear()
        tests.check("Полный сброс удаляет все ссылки", buffer.currentOccurrenceID == nil && buffer.lastOccurrenceID == nil && buffer.retypingOccurrenceID == nil && resets == 1)
        buffer.append("word")
        let prior = buffer.currentOccurrenceID
        buffer.softContextReset()
        tests.check("Мягкий сброс сохраняет текст и меняет идентичность контекста", buffer.currentWord == "word" && buffer.currentOccurrenceID != prior && resets == 2)
    }
}
