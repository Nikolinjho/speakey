import AppKit
import CryptoKit

/// Проверка источников контекста на синтетических данных, до запуска AppDelegate.
enum AutocompleteContextCheck {
    @MainActor static func run() async -> Int32 {
        setbuf(stdout, nil)
        var count = 0, failures = 0
        func check(_ name: String, _ value: Bool) {
            count += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL"): \(name)")
        }
        let defaults = UserDefaults.standard
        let bid = Bundle.main.bundleIdentifier ?? "dev.speakey.app.dev"
        let originalPersistent = defaults.persistentDomain(forName: bid) ?? [:]
        let originalClipboardChange = NSPasteboard.general.changeCount
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments: [String: Any] = [
            "ac.enabled": true, "ac.recordMode": "off", "ac.personalStrength": 0,
            "ac.useClipboard": false, "ac.useScreen": false, "ac.globalInstruction": "",
            "ac.apps": try! JSONSerialization.data(withJSONObject: [bid: ["instruction": "Пиши о тестовом проекте Сапфир."]]), "ac.onlyCurrentWord": false,
            "ac.autoAlternatives": false, "ac.autoSynonyms": false,
            "ac.typoFix": true, "ac.pauseMs": 50, "ac.tabEnabled": true
        ]
        for action in CompletionAction.allCases {
            arguments["ac.shortcut.\(action.rawValue)"] = action == .nextWord
                ? try! JSONEncoder().encode(CompletionShortcut(keyCode: 48, modifiers: 0))
                : Data("null".utf8)
        }
        func configure(_ values: [String: Any]) {
            arguments.merge(values) { _, new in new }
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        configure([:])
        let directory = URL(fileURLWithPath: "/private/tmp/speakey-context-\(getpid())")
        setenv("SPEAKEY_COMPLETE_TEST_DIR", directory.appendingPathComponent("engine").path, 1)
        let key = SymmetricKey(data: Data(repeating: 17, count: 32))
        let corpus = PersonalCorpus(directory: directory, keyProvider: { key })
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            CompletionEngine.shared.stop()
            defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        let sample = FieldSnapshot(bundleID: bid, appName: "Context check", before: "Завтра обсудим Сапфир",
                                   caretRect: .zero, pid: getpid())
        func context() -> CompletionContext { ContextHub.context(for: sample, corpus: corpus, pasteboard: pasteboard) }
        let baseline = context()
        check("Источники выключены: контекст пуст", baseline.clipboard == nil && baseline.screenText == nil && baseline.snippets.isEmpty && baseline.terms.isEmpty)

        pasteboard.setString("Синтетический план Сапфир", forType: .string)
        check("Выключенный буфер не читается", context().clipboard == nil)
        configure(["ac.useClipboard": true])
        check("Включённый буфер передаёт контекст", context().clipboard == "Синтетический план Сапфир")
        let clipboardPrompt = CompletionPrompt.build(context())
        check("Буфер доходит до запроса модели", clipboardPrompt.contains("#### Clipboard\nСинтетический план Сапфир"))
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            pasteboard.declareTypes([.string, NSPasteboard.PasteboardType(marker)], owner: nil)
            pasteboard.setString("Синтетический закрытый текст", forType: .string)
            check("Буфер \(marker) исключён", context().clipboard == nil)
        }
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "я", count: 501), forType: .string)
        check("Буфер длиннее 500 символов исключён", context().clipboard == nil)
        pasteboard.clearContents(); pasteboard.setString(" \n ", forType: .string)
        check("Пустой буфер исключён", context().clipboard == nil)
        configure(["ac.useClipboard": false, "ac.globalInstruction": "Пиши коротко, используй слово Сапфир."])
        check("Общая инструкция доходит до запроса", CompletionPrompt.build(context()).contains("#### Author instructions\nПиши коротко, используй слово Сапфир."))
        check("Инструкция приложения добавлена к общей", CompletionPrompt.build(context()).contains("Пиши о тестовом проекте Сапфир."))

        for text in [
            "Завтра обсудим Сапфир и согласуем синтетический план проекта",
            "Сапфир готов к проверке, синтетический план обсуждаем завтра",
            "Сапфир сегодня проходит проверку перед демонстрацией проекта"
        ] { check("Синтетическая запись сохранена", corpus.add(text, bundleID: bid)) }
        check("Сила 0 исключает сохранённую историю", context().snippets.isEmpty && context().terms.isEmpty)
        configure(["ac.personalStrength": 1])
        check("Сила 1: один пример из корпуса", context().snippets.count == 1)
        check("Выключенная запись сохраняет влияние накопленных терминов", context().terms.contains("Сапфир") || context().terms.contains("сапфир"))
        configure(["ac.personalStrength": 2])
        check("Сила 2: три примера из корпуса", context().snippets.count == 3)
        let personalized = CompletionPrompt.build(context())
        check("Примеры и термины включены в запрос", personalized.contains("#### Author text examples") && personalized.contains("#### Author vocabulary"))
        let raw = (try? Data(contentsOf: directory.appendingPathComponent("corpus.bin"))) ?? Data()
        check("На диске нет открытого синтетического текста", !raw.isEmpty && raw.range(of: Data("Сапфир".utf8)) == nil)
        let reloaded = PersonalCorpus(directory: directory, keyProvider: { key })
        check("Настоящий корпус перечитывается с ключом", reloaded.count == 3)
        check("Удаление истории убирает персонализацию", corpus.removeAll() && context().snippets.isEmpty && context().terms.isEmpty)
        configure(["ac.personalStrength": 0, "ac.globalInstruction": ""])

        let window = NSWindow(contentRect: NSRect(x: 180, y: 220, width: 700, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Speakey · синтетическая проверка контекста"
        let text = NSTextView(frame: NSRect(x: 20, y: 20, width: 660, height: 220))
        text.font = .systemFont(ofSize: 24); text.isRichText = false
        text.isAutomaticSpellingCorrectionEnabled = false
        window.contentView?.addSubview(text)
        text.string = "SAPPHIRE CONTEXT CHECK 7392"
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 250_000_000)
        if ScreenContextProvider.hasPermission {
            ScreenContextProvider.shared.refreshIfNeeded(pid: getpid())
            let deadline = Date().addingTimeInterval(12)
            while ScreenContextProvider.shared.text(for: getpid()) == nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let recognized = ScreenContextProvider.shared.text(for: getpid()) ?? ""
            check("OCR распознаёт собственное синтетическое окно", recognized.contains("CONTEXT CHECK") && recognized.localizedCaseInsensitiveContains("SAPPHIRE"))
            configure(["ac.useScreen": true])
            check("OCR доходит до запроса модели", CompletionPrompt.build(context()).contains("SAPPHIRE"))
            check("OCR другого процесса не используется", ScreenContextProvider.shared.text(for: -1) == nil)
            configure(["ac.useScreen": false])
            check("Выключенный OCR не передаёт кэш", context().screenText == nil)
        } else {
            print("SKIP: OCR окна: у Speakey нет разрешения записи экрана. Запрос разрешения не выполнялся.")
        }
        // Настоящий контроллер, два настоящих AX-поля и временный зашифрованный корпус.
        configure(["ac.recordMode": "accepted", "ac.useScreen": false])
        let controller = AutocompleteController(corpus: corpus)
        controller.suppressForWord = { _ in false }
        let second = NSTextView(frame: NSRect(x: 20, y: 20, width: 660, height: 90))
        second.font = .systemFont(ofSize: 24); second.isRichText = false
        second.isAutomaticSpellingCorrectionEnabled = false
        text.frame = NSRect(x: 20, y: 130, width: 660, height: 100)
        window.contentView?.addSubview(second)
        func waitForRecording(_ prefix: String) async {
            let deadline = Date().addingTimeInterval(3)
            while !corpus.snapshot().records.contains(where: { $0.text.hasPrefix(prefix) }) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        func fixture(_ view: NSTextView, _ value: String) async {
            controller.contextReset()
            view.string = value
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
            _ = controller.handleKey(keyCode: 49, characters: " ", flags: [], app: bid)
            let deadline = Date().addingTimeInterval(4)
            while !GhostSuggestionPanel.shared.isVisible && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await fixture(text, "SYNTHETIC FIRST FIELD спасиибо ")
        check("Контроллер показывает исправление опечатки", GhostSuggestionPanel.shared.isVisible)
        check("До принятия исходная опечатка сохранена", text.string == "SYNTHETIC FIRST FIELD спасиибо ")
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            _ = controller.handleKey(keyCode: 48, characters: "\t", flags: [], app: bid)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("Tab явно принимает исправление", text.string == "SYNTHETIC FIRST FIELD спасибо ")
        await fixture(second, "SYNTHETIC SECOND FIELD здравствуйтте ")
        check("Во втором поле показано отдельное исправление", GhostSuggestionPanel.shared.isVisible)
        controller.contextReset(appChanged: true)
        await waitForRecording("SYNTHETIC FIRST FIELD")
        let recorded = corpus.snapshot().records
        check("В корпус записан точный исправленный текст поля", recorded.contains { $0.text == "SYNTHETIC FIRST FIELD спасибо" })
        check("Второе поле без принятия не записано", !recorded.contains { $0.text.hasPrefix("SYNTHETIC SECOND FIELD") })
        _ = corpus.removeAll()
        configure(["ac.recordMode": "all"])
        await fixture(second, "SYNTHETIC ALL SESSIONS здравствуйтте ")
        controller.contextReset(appChanged: true)
        await waitForRecording("SYNTHETIC ALL SESSIONS")
        check("Режим всех сессий сохраняет поле без принятия", corpus.snapshot().records.contains { $0.text.hasPrefix("SYNTHETIC ALL SESSIONS") })
        _ = corpus.removeAll()
        configure(["ac.recordMode": "off"])
        await fixture(second, "SYNTHETIC RECORDING OFF здравствуйтте ")
        controller.contextReset(appChanged: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        PersonalCorpus.workQueue.sync {}
        check("Выключенная запись не сохраняет поле", corpus.count == 0)
        check("Личные настройки не изменены", NSDictionary(dictionary: originalPersistent).isEqual(to: defaults.persistentDomain(forName: bid) ?? [:]))
        check("Общий буфер обмена не изменён", NSPasteboard.general.changeCount == originalClipboardChange)
        window.orderOut(nil)
        print("autocomplete native context: \(count) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
