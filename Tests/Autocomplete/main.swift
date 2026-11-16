import Foundation

// Логгер приложения не нужен чистой логике, но другие файлы харнесса могут его ждать.
func kbLog(_ message: String) {}

var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

// MARK: clean (тесты плана)
expect(CompletionText.clean(" в ветку\nещё", before: "потом", maxWords: 6) == " в ветку", "обрезка на строке")
expect(CompletionText.clean("   ", before: "x", maxWords: 6) == "", "пустой ответ")
expect(CompletionText.clean(" а б в г д е ж", before: "x", maxWords: 3) == " а б в", "лимит слов")

// MARK: clean (краевые)
expect(CompletionText.clean("", before: "привет", maxWords: 6) == "", "пустая строка")
expect(CompletionText.clean("\nещё", before: "привет", maxWords: 6) == "", "ответ начинается с перевода строки")
expect(CompletionText.clean(" дела", before: "", maxWords: 6) == " дела", "пустой before")
expect(CompletionText.clean(" дела\r\nещё", before: "как", maxWords: 6) == " дела", "CRLF")
expect(CompletionText.clean(" дела", before: "как", maxWords: 0) == "", "maxWords 0")
expect(CompletionText.clean("как дела", before: "Привет, как", maxWords: 6) == " дела", "повтор последнего слова")
expect(CompletionText.clean("Как дела", before: "привет, как", maxWords: 6) == " дела", "повтор без учёта регистра")
expect(CompletionText.clean("Привет, как дела", before: "Привет, как", maxWords: 6) == " дела", "повтор всей фразы")
expect(CompletionText.clean("как", before: "как", maxWords: 6) == "", "ответ целиком повтор")
expect(CompletionText.clean("рабль плывёт", before: "ко", maxWords: 6) == "рабль плывёт", "дописывание слова не ломается")
expect(CompletionText.clean("корабль плывёт", before: "ко", maxWords: 6) == "корабль плывёт", "слово-продолжение с общим началом не режется")
expect(CompletionText.clean(" и там", before: "и", maxWords: 6) == " и там", "односимвольное слово не считается повтором")
expect(CompletionText.clean("как дела", before: "привет, как ", maxWords: 6) == "дела", "повтор после пробела")
expect(CompletionText.clean(" дела", before: "как ", maxWords: 6) == "дела", "лишний ведущий пробел срезан")
expect(CompletionText.clean("   дела", before: "как\t", maxWords: 6) == "дела", "ведущие пробелы срезаны полностью")
expect(CompletionText.clean(" дела", before: "как", maxWords: 6) == " дела", "ведущий пробел нужен, если before без пробела")
expect(CompletionText.clean("дела", before: "как ", maxWords: 6) == "дела", "пробел не добавляется")
expect(CompletionText.clean(" дела<eos>", before: "как", maxWords: 6) == " дела", "служебный <eos>")
expect(CompletionText.clean(" дела<|im_end|> мусор", before: "как", maxWords: 6) == " дела", "служебный <|...|> и всё после")
expect(CompletionText.clean("<|endoftext|>", before: "как", maxWords: 6) == "", "только служебный токен")
expect(CompletionText.clean(" дела <|im_en", before: "как", maxWords: 6) == " дела", "обрезанный служебный токен")
expect(CompletionText.clean(" дела</s>", before: "как", maxWords: 6) == " дела", "служебный </s>")
expect(CompletionText.clean("\t \t", before: "x", maxWords: 6) == "", "только пробельные символы")
expect(CompletionText.clean(" a  b   c d", before: "x", maxWords: 2) == " a  b", "лимит слов сохраняет внутренние пробелы")
expect(CompletionText.clean(" дела,  ", before: "как", maxWords: 6) == " дела,", "хвостовые пробелы срезаны")
expect(CompletionText.clean(" hello world", before: "Say", maxWords: 6) == " hello world", "английский")
expect(CompletionText.clean(" 你好 世界", before: "我说", maxWords: 6) == " 你好 世界", "китайский")
expect(CompletionText.clean(" ça va très bien", before: "Salut", maxWords: 2) == " ça va", "французский с диакритикой")
expect(CompletionText.clean(" 😀 ок 👍", before: "привет", maxWords: 2) == " 😀 ок", "emoji как слово")
expect(CompletionText.clean("🙂", before: "ок ", maxWords: 6) == "🙂", "ответ из одного emoji")
expect(CompletionText.clean(" 😀", before: "привет 😀", maxWords: 6) == " 😀", "emoji в конце before не считается повтором слова")
let longBefore = String(repeating: "слово ", count: 100) + "как"
expect(CompletionText.clean("как дела", before: longBefore, maxWords: 6) == " дела", "повтор при длинном before")

// MARK: Служебный текст в реальном ответе модели
expect(CompletionText.clean(" \"Серебряный сад\". Частые слова: \"Серебряный сад\".", before: "Название проекта", maxWords: 6, stopPhrases: ["Частые слова:"]) == " \"Серебряный сад\".", "служебные термины не попадают в продолжение")
expect(CompletionText.clean(" слова для текста. Use that value in the completion.", before: "Нужны", maxWords: 20, singleSentence: true) == " слова для текста.", "пояснение после законченного предложения не вставляется")
expect(CompletionText.clean(" Mr. Smith is ready. Next sentence.", before: "Ask", maxWords: 20, singleSentence: true) == " Mr. Smith is ready.", "сокращение имени не заканчивает предложение")
expect(CompletionText.clean(" version 0.4.11 is ready. Next sentence.", before: "The", maxWords: 20, singleSentence: true) == " version 0.4.11 is ready.", "точки версии не режут предложение")
expect(CompletionText.clean(" https://example.com/path is ready. Next sentence.", before: "Link", maxWords: 20, singleSentence: true) == " https://example.com/path is ready.", "точки URL не режут предложение")
expect(CompletionText.clean("Частые слова: это заголовок документа", before: "Объяснение: ", maxWords: 20) == "Частые слова: это заголовок документа", "обычный документ без служебных меток сохранён")
expect(CompletionText.clean("мир. Второе предложение.", before: "Привет ", maxWords: 20) == "мир. Второе предложение.", "без контекста длина предложения не ограничена")
expect(CompletionText.clean("Author vocabulary: noise", before: "Text", maxWords: 20, stopPhrases: ["Author vocabulary:"]) == "", "ответ из одной служебной секции отклонён")
expect(CompletionText.clean(" ProtoVocabulary: term", before: "Type", maxWords: 20, stopPhrases: ["Vocabulary:"]) == " ProtoVocabulary: term", "служебное слово внутри идентификатора не режется")

// MARK: nextChunk
expect(CompletionText.nextChunk(" в ветку, потом") == (" в", " ветку, потом"), "первое слово")
expect(CompletionText.nextChunk(" ветку, потом") == (" ветку,", " потом"), "пунктуация с словом")
expect(CompletionText.nextChunk("алить в") == ("алить", " в"), "дописывание слова")
expect(CompletionText.nextChunk("") == ("", ""), "пустая строка")
expect(CompletionText.nextChunk("   ") == ("   ", ""), "только пробелы")
expect(CompletionText.nextChunk(" ") == (" ", ""), "один пробел")
expect(CompletionText.nextChunk("слово") == ("слово", ""), "одно слово без остатка")
expect(CompletionText.nextChunk("  два  слова") == ("  два", "  слова"), "несколько пробелов")
expect(CompletionText.nextChunk(" 😀 ок") == (" 😀", " ок"), "emoji как слово")
expect(CompletionText.nextChunk("👨‍👩‍👧 дом") == ("👨‍👩‍👧", " дом"), "составной emoji не рвётся")
expect(CompletionText.nextChunk(" 你好 世界") == (" 你好", " 世界"), "китайский")
expect(CompletionText.nextChunk(" ça va") == (" ça", " va"), "диакритика")
expect(CompletionText.nextChunk("a\u{0301}b c") == ("a\u{0301}b", " c"), "комбинируемый символ")

// MARK: consume
expect(CompletionText.consume(" в ветку", typed: " в") == " ветку", "съедание")
expect(CompletionText.consume(" в ветку", typed: "x") == nil, "расхождение")
expect(CompletionText.consume(" в", typed: " в") == "", "съели целиком")
expect(CompletionText.consume(" в", typed: " вв") == nil, "напечатано больше подсказки")
expect(CompletionText.consume(" в ветку", typed: "") == " в ветку", "ничего не напечатано")
expect(CompletionText.consume("", typed: "") == "", "всё пусто")
expect(CompletionText.consume("", typed: "a") == nil, "пустая подсказка")
expect(CompletionText.consume(" В ветку", typed: " в") == nil, "регистр различается")
expect(CompletionText.consume(" 😀 ок", typed: " 😀") == " ок", "emoji съедается целиком")
expect(CompletionText.consume("éa", typed: "e") == nil, "e не съедает é")
expect(CompletionText.consume(" 你好吗", typed: " 你") == "好吗", "китайский")

// MARK: isFresh
expect(!CompletionText.isFresh(requestedBefore: "пот", currentBefore: "пото"), "устарело")
expect(CompletionText.isFresh(requestedBefore: "пот", currentBefore: "пот"), "свежо")
expect(CompletionText.isFresh(requestedBefore: "", currentBefore: ""), "пустой before свеж")
expect(!CompletionText.isFresh(requestedBefore: "пот", currentBefore: "пот "), "добавлен пробел")
expect(!CompletionText.isFresh(requestedBefore: "пот", currentBefore: ""), "поле очищено")

// MARK: redactSecrets
expect(!CompletionText.redactSecrets("ключ sk-abcdefghijklmnopqrstuv123").contains("sk-abc"), "секрет")
expect(CompletionText.redactSecrets("ключ sk-abcdefghijklmnopqrstuv123 тут") == "ключ ••• тут", "секрет sk- заменён, текст цел")
expect(!CompletionText.redactSecrets("ghp_abcdefghijklmnopqrstuvwxyz0123456789").contains("ghp_"), "ghp_")
expect(!CompletionText.redactSecrets("token xoxb-1234567890-abcdefghij").contains("xoxb"), "xox")
expect(CompletionText.redactSecrets("пароль: hunter2 дальше") == "пароль: ••• дальше", "пароль: ру")
expect(CompletionText.redactSecrets("Пароль = Qwerty!1") == "Пароль = •••", "Пароль с = и регистром")
expect(CompletionText.redactSecrets("my password: s3cret ok") == "my password: ••• ok", "password:")
expect(CompletionText.redactSecrets("a8Kd93LmQz02XvB7nRtY41") == "•••", "длинный токен букв и цифр")
expect(CompletionText.redactSecrets("abcdefghijklmnopqrstuvwxyz") == "abcdefghijklmnopqrstuvwxyz", "длинное слово без цифр цело")
expect(CompletionText.redactSecrets("12345678901234567890") == "12345678901234567890", "длинное число цело")
expect(CompletionText.redactSecrets("Привет, как дела 2024 года?") == "Привет, как дела 2024 года?", "обычный текст цел")
expect(CompletionText.redactSecrets("") == "", "пустая строка")
expect(CompletionText.redactSecrets("пароль 😀 ok") == "пароль 😀 ok", "слово «пароль» без двоеточия цело")
expect(CompletionText.redactSecrets(CompletionText.redactSecrets("пароль: abc")) == "пароль: •••", "повторная обработка идемпотентна")

// MARK: lastWord
expect(CompletionText.lastWord("Привет, как") == "как", "последнее слово")
expect(CompletionText.lastWord("Привет, как ") == "", "после пробела слова нет")
expect(CompletionText.lastWord("") == "", "пусто")
expect(CompletionText.lastWord("слово") == "слово", "одно слово")
expect(CompletionText.lastWord("что-то") == "что-то", "дефис внутри слова")
expect(CompletionText.lastWord("it's") == "it's", "апостроф")
expect(CompletionText.lastWord("итог: abc123") == "abc123", "цифры")
expect(CompletionText.lastWord("привет 😀") == "", "emoji в конце")
expect(CompletionText.lastWord("привет😀мир") == "мир", "слово после emoji")
expect(CompletionText.lastWord("好 你好") == "你好", "китайский")
expect(CompletionText.lastWord("a\nслово") == "слово", "после перевода строки")
expect(CompletionText.lastWord("конец.") == "", "точка в конце")

// MARK: CompletionPrompt.build
let p = CompletionPrompt.build(CompletionContext(appName: "Telegram", before: "Привет, как"))
expect(p.hasSuffix("Привет, как"), "before в конце дословно")
expect(p.contains("Telegram"), "имя приложения в шапке")
let long = CompletionPrompt.build(CompletionContext(appName: "X", before: String(repeating: "а", count: 5000), screenText: "экран"), budget: 3000)
expect(long.count <= 3000, "бюджет")
let bare = CompletionPrompt.build(CompletionContext(appName: "Notes", before: "Привет"))
expect(bare == "Notes, черновик:\nПривет", "пустые секции не выводятся")
expect(!bare.contains("Заметки автора") && !bare.contains("Текст на экране") && !bare.contains("Частые слова"), "заголовков пустых секций нет")
let noName = CompletionPrompt.build(CompletionContext(appName: "  ", before: "x"))
expect(noName == "Черновик:\nx", "пустое имя приложения")
let emptyBefore = CompletionPrompt.build(CompletionContext(appName: "Notes", before: ""))
expect(emptyBefore == "Notes, черновик:\n", "пустой before")
let spaces = CompletionPrompt.build(CompletionContext(appName: "Notes", before: "Привет, как "))
expect(spaces.hasSuffix("Привет, как "), "хвостовой пробел before сохранён")
let mid = CompletionPrompt.build(CompletionContext(appName: "Notes", before: "пишу за"))
expect(mid.hasSuffix("пишу за"), "слово в середине набора сохраняется")

let full = CompletionContext(
    appName: "Slack", before: "Коллеги, пушу в",
    screenText: "Деплой Speakey в GitLab завершён", clipboard: "https://example.com/x",
    globalInstruction: "Пиши кратко", appInstruction: "Деловой тон",
    snippets: ["Пример один.", "Пример два."], terms: ["GitLab", "Speakey"])
let fp = CompletionPrompt.build(full)
expect(fp.hasSuffix("Коллеги, пушу в"), "before в конце при полном контексте")
for part in ["#### Author instructions\nПиши кратко", "#### Application instructions\nДеловой тон", "#### Screen text\nДеплой Speakey",
             "#### Clipboard\nhttps://", "#### Author text examples\nПример один.\nПример два.", "#### Author vocabulary\nGitLab, Speakey",
             "### Document in Slack\nКоллеги"] {
    expect(fp.contains(part), "секция есть: \(part.prefix(20))")
}
expect((fp.range(of: "#### Screen text")?.lowerBound ?? fp.endIndex) < (fp.range(of: "#### Author text examples")?.lowerBound ?? fp.startIndex), "порядок секций")
expect(fp.contains("### Background") && fp.contains("### Document in Slack"), "фон отделён от дописываемого документа")
let replyContext = CompletionContext(appName: "X", before: "Название проекта", terms: ["Серебряный сад"])
expect(CompletionPrompt.cleanContinuation(" \"Серебряный сад\". Частые слова: xx", before: replyContext.before, context: replyContext, maxWords: 6) == " \"Серебряный сад\".", "производственная очистка останавливает фоновые пояснения")
expect(CompletionPrompt.cleanContinuation(" good. Use that value in the completion.", before: "This is", context: full, maxWords: 20) == " good.", "скопированная инструкция после ответа не принимается")
expect(CompletionPrompt.cleanContinuation("#### Clipboard\nnoise", before: full.before, context: full, maxWords: 6) == "", "новый служебный заголовок не принимается")

let hugeCtx = CompletionContext(
    appName: "Slack", before: String(repeating: "слово ", count: 300) + "как",
    screenText: String(repeating: "экран ", count: 1000), clipboard: String(repeating: "буфер ", count: 500),
    globalInstruction: String(repeating: "заметка ", count: 500), appInstruction: String(repeating: "правило ", count: 500),
    snippets: Array(repeating: String(repeating: "пример ", count: 100), count: 30), terms: (0..<500).map { "термин\($0)" })
for budget in [3000, 1500, 800, 300, 100, 40, 10, 0] {
    let r = CompletionPrompt.build(hugeCtx, budget: budget)
    expect(r.count <= budget, "строгий бюджет \(budget): \(r.count)")
}
let big = CompletionPrompt.build(hugeCtx, budget: 3000)
expect(big.hasSuffix("слово как"), "before сохранён в конце при переполнении")
let tightPrio = CompletionContext(appName: "A", before: String(repeating: "б", count: 100),
                                  screenText: String(repeating: "э", count: 400), globalInstruction: "ВАЖНО")
let tp = CompletionPrompt.build(tightPrio, budget: 160)
expect(tp.count <= 160 && tp.contains("ВАЖНО") && tp.hasSuffix(String(repeating: "б", count: 100)), "инструкции важнее экрана")
let cut = CompletionPrompt.build(CompletionContext(appName: "A", before: String(repeating: "слово ", count: 400) + "ко"), budget: 3000)
let tailPart = cut.components(separatedBy: "черновик:\n").last ?? ""
expect(tailPart.count <= 1200 && tailPart.hasPrefix("слово") && tailPart.hasSuffix("слово ко"), "before ≤1200 и режется по границе слова")
let mixed = CompletionPrompt.build(CompletionContext(appName: "Чат", before: "Hello мир 😀 你好 как"))
expect(mixed.hasSuffix("Hello мир 😀 你好 как"), "многоязычный before дословно")
let emoji = String(repeating: "😀", count: 2000)
let em = CompletionPrompt.build(CompletionContext(appName: "A", before: emoji), budget: 1500)
expect(em.count <= 1500 && em.hasSuffix("😀"), "emoji без разрыва и в бюджете")
expect(CompletionPrompt.build(CompletionContext(appName: "A", before: "x", terms: ["один", "два"]), budget: 3000).contains("#### Author vocabulary\nодин, два"), "термины через запятую")

// MARK: dictationHint
expect((CompletionPrompt.dictationHint(dictionary: ["Speakey"], screenTerms: ["GitLab", "Speakey"], corpusTerms: [], maxChars: 240) ?? "") == "Speakey, GitLab", "затравка без повторов")
expect(CompletionPrompt.dictationHint(dictionary: [], screenTerms: [], corpusTerms: []) == nil, "пустая затравка")
expect(CompletionPrompt.dictationHint(dictionary: ["  ", ""], screenTerms: [], corpusTerms: []) == nil, "только пустые слова")
expect(CompletionPrompt.dictationHint(dictionary: ["speakey"], screenTerms: ["Speakey"], corpusTerms: ["SPEAKEY"]) == "speakey", "повторы без учёта регистра")
expect(CompletionPrompt.dictationHint(dictionary: ["a"], screenTerms: ["b"], corpusTerms: ["c"]) == "a, b, c", "порядок: словарь, экран, корпус")
let hint = CompletionPrompt.dictationHint(dictionary: (0..<100).map { "слово\($0)" }, screenTerms: [], corpusTerms: [], maxChars: 50) ?? ""
expect(hint.count <= 50 && hint.hasPrefix("слово0, слово1"), "лимит символов")
expect(!hint.hasSuffix(",") && !hint.hasSuffix(" "), "затравка не обрывается на разделителе")
expect(CompletionPrompt.dictationHint(dictionary: ["очень-длинное-слово-за-лимитом", "ок"], screenTerms: [], corpusTerms: [], maxChars: 5) == "ок", "слишком длинное слово пропускается")
expect(CompletionPrompt.dictationHint(dictionary: ["a"], screenTerms: [], corpusTerms: [], maxChars: 0) == nil, "maxChars 0")
expect(CompletionPrompt.dictationHint(dictionary: ["Привет", "你好", "😀"], screenTerms: [], corpusTerms: []) == "Привет, 你好, 😀", "многоязычная затравка")

// MARK: terms(from:)
let screen = "Мы деплоим Speakey в GitLab. Вчера Ника открыла MR-123 и запушила в origin. Потом Ника ушла."
let t = CompletionPrompt.terms(from: screen, max: 10)
expect(t.contains("Speakey") && t.contains("GitLab"), "латиница")
expect(t.contains("MR-123"), "слово с цифрами")
expect(t.contains("origin"), "латиница в нижнем регистре")
expect(t.contains("Ника"), "слово с заглавной не после точки")
expect(!t.contains("Вчера") && !t.contains("Потом"), "начало предложения не термин")
expect(!t.contains("Мы"), "начало текста не термин")
expect(!t.contains("деплоим") && !t.contains("запушила"), "обычные русские слова не термины")
expect(CompletionPrompt.terms(from: "Привет. Слово! Тест? Мир", max: 10) == [], "после .!? не термин")
expect(CompletionPrompt.terms(from: "Привет. Слово Привет", max: 10) == ["Привет"], "та же заглавная в середине предложения — термин")
expect(CompletionPrompt.terms(from: "", max: 5) == [], "пустой текст")
expect(CompletionPrompt.terms(from: "GitLab", max: 0) == [], "max 0")
expect(CompletionPrompt.terms(from: "a b ab 12 x1", max: 5) == [], "короче трёх символов")
expect(CompletionPrompt.terms(from: "see the and for with", max: 5) == [], "английские стоп-слова")
expect(CompletionPrompt.terms(from: "и вот Что-то для Как", max: 5) == ["Что-то"], "русские стоп-слова, дефисное слово")
expect(CompletionPrompt.terms(from: "ok. Alpha beta Alpha gamma Beta2 Alpha", max: 3) == ["Alpha", "beta", "gamma"], "частота, затем порядок появления")
expect(CompletionPrompt.terms(from: "xx. gitlab GitLab GITLAB", max: 5) == ["gitlab"], "регистры слиты, форма первого появления")
expect(CompletionPrompt.terms(from: "foo bar baz foo", max: 2) == ["foo", "bar"], "max ограничивает выдачу")
expect(CompletionPrompt.terms(from: "Тест. Hello😀GitLab", max: 5).contains("Hello"), "emoji разделяет слова")
expect(CompletionPrompt.terms(from: "Тест. 2024 12345", max: 5) == [], "чистые числа не термины")
expect(CompletionPrompt.terms(from: "про 你好世界 и Москву", max: 5) == ["Москву"], "CJK без регистра термином не считается")
expect(CompletionPrompt.terms(from: "Тест. Едем в Москву и Казань", max: 5) == ["Москву", "Казань"], "заглавные после первой позиции")
expect(CompletionPrompt.terms(from: "первая\nВторая строка Токио", max: 5) == ["Вторая", "Токио"], "перенос строки не начало предложения")

if failures == 0 {
    print("autocomplete: \(checks) checks OK")
    exit(0)
} else {
    print("autocomplete: \(failures) of \(checks) checks FAILED")
    exit(1)
}
