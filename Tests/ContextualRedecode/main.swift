import Foundation

var checks = 0, failures = 0
func check(_ name: String, _ value: Bool) {
    checks += 1
    if !value { failures += 1 }
    print("\(value ? "PASS" : "FAIL"): \(name)")
}

let c = [ContextCandidate(word: "DPR", replaces: "tpr", score: 1), ContextCandidate(word: "подборок", replaces: "подбора", score: 1)]
let t1 = "Посмотри на этой странице на мобилке, какое tpr у фоток подбора."
check("пример Ники", ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у фоток подборок.", candidates: c))
check("форма кандидата", ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у фоток подборки.", candidates: c))
check("не кандидат", !ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое TPR у фото подборок.", candidates: c))
check("вставка слова", !ContextualRedecode.accept(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у всех фоток подборок.", candidates: c))
check("больше 30%", !ContextualRedecode.accept(first: "tpr подбора", second: "DPR подборок", candidates: c)) // 2 изменения при лимите max(1, floor(0.6)) = 1
check("пустой T2", !ContextualRedecode.accept(first: t1, second: "", candidates: c))
check("регистр и точка", ContextualRedecode.accept(first: t1, second: t1.lowercased().replacingOccurrences(of: ".", with: ""), candidates: c))
check("нет кандидатов", !ContextualRedecode.shouldRunSecondPass(elapsedSeconds: 0.5, firstPassSeconds: 0.5, timeoutSeconds: 15, candidateCount: 0, waitingTranscriptions: 0))
check("бюджет ок", ContextualRedecode.shouldRunSecondPass(elapsedSeconds: 0.9, firstPassSeconds: 0.9, timeoutSeconds: 15, candidateCount: 2, waitingTranscriptions: 0))
check("бюджет превышен", !ContextualRedecode.shouldRunSecondPass(elapsedSeconds: 4.6, firstPassSeconds: 4.6, timeoutSeconds: 15, candidateCount: 2, waitingTranscriptions: 0))
// Сторож считает от начала транскрипции: ожидание очереди и загрузка модели входят в бюджет.
check("ожидание очереди съело бюджет", !ContextualRedecode.shouldRunSecondPass(elapsedSeconds: 8.5, firstPassSeconds: 1, timeoutSeconds: 15, candidateCount: 2, waitingTranscriptions: 0))
check("ровно на границе 60%", ContextualRedecode.shouldRunSecondPass(elapsedSeconds: 8, firstPassSeconds: 1, timeoutSeconds: 15, candidateCount: 2, waitingTranscriptions: 0))
check("прошедшее меньше T1 не делает бюджет щедрее", !ContextualRedecode.shouldRunSecondPass(elapsedSeconds: 0, firstPassSeconds: 4.6, timeoutSeconds: 15, candidateCount: 2, waitingTranscriptions: 0))
check("очередь ждёт — второго прохода нет", !ContextualRedecode.shouldRunSecondPass(elapsedSeconds: 0.5, firstPassSeconds: 0.5, timeoutSeconds: 15, candidateCount: 2, waitingTranscriptions: 1))
check("фото не форма фоток", !ContextualRedecode.accept(first: "tpr", second: "фото", candidates: [ContextCandidate(word: "фоток", replaces: "tpr", score: 1)]))
check("замена не на свой replaces", !ContextualRedecode.accept(first: "подбора", second: "DPR", candidates: c))


// Доставка: T2 заменяет T1, только если поменял хотя бы одно слово (оформление не трогаем).
check("изменённых слов: пример Ники", ContextualRedecode.changedWordCount(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у фоток подборок.") == 2)
check("регистр и пунктуация — не изменение", ContextualRedecode.changedWordCount(first: t1, second: t1.lowercased().replacingOccurrences(of: ".", with: "")) == 0)
check("разное число слов — не сравниваем", ContextualRedecode.changedWordCount(first: "a b", second: "a b c") == nil)
check("доставка: пример Ники", ContextualRedecode.shouldDeliver(first: t1, second: "Посмотри на этой странице на мобилке, какое DPR у фоток подборок.", candidates: c))
check("доставки нет: только оформление", !ContextualRedecode.shouldDeliver(first: t1, second: t1.lowercased().replacingOccurrences(of: ".", with: ""), candidates: c))
check("доставки нет: не принят", !ContextualRedecode.shouldDeliver(first: t1, second: "Посмотри на этой странице на мобилке, какое TPR у фото подборок.", candidates: c))

print("\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
