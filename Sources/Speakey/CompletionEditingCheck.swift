import AppKit

/// Настоящие AX-поля с синтетическим текстом. До AppDelegate, без записи корпуса и настроек.
enum CompletionEditingCheck {
    @MainActor static func run() async -> Int32 {
        setbuf(stdout, nil)
        var count = 0, failures = 0
        func check(_ name: String, _ value: Bool) {
            count += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL"): \(name)")
        }
        let directory = URL(fileURLWithPath: "/private/tmp/speakey-editing-\(getpid())")
        setenv("SPEAKEY_COMPLETE_TEST_DIR", directory.path, 1)
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 650, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Speakey · проверка редактирования"
        let first = NSTextView(frame: NSRect(x: 24, y: 160, width: 600, height: 130))
        let second = NSTextView(frame: NSRect(x: 24, y: 20, width: 600, height: 120))
        for view in [first, second] {
            view.font = .systemFont(ofSize: 20); view.isRichText = false
            window.contentView?.addSubview(view)
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func pause() async { try? await Task.sleep(nanoseconds: 180_000_000) }
        func fixture(_ text: String, _ range: NSRange, view: NSTextView? = nil) async {
            let view = view ?? first
            view.string = text; window.makeFirstResponder(view); view.setSelectedRange(range)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause()
        }
        func snapshot() async -> CompletionTarget? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let target = CompletionTarget.capture()
                    // Внешний фокус не является тестовой целью. В чужое окно стенд не пишет.
                    guard target?.pid == getpid() else {
                        print("SNAPSHOT: own PID=\(getpid()), focused PID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: target)
                }
            }
        }
        func commit(_ target: CompletionTarget?, _ text: String) async -> Bool {
            guard let target else { return false }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: target.commit(text)) }
            }
        }
        await fixture("This is a result.", NSRange(location: 10, length: 0))
        let gap = await snapshot()
        check("Снимок содержит обе стороны каретки", gap?.before == "This is a " && gap?.after == "result.")
        check("AX вставляет в середину строки", await commit(gap, "good "))
        check("Правый текст и пробел сохранены", first.string == "This is a good result.")

        await fixture("🙂 A good result.", NSRange(location: 5, length: 4))
        let selection = await snapshot()
        check("Выделение после emoji читается в UTF16", selection?.selected == "good")
        check("AX заменяет выделение", await commit(selection, "great"))
        check("Соседний текст при замене сохранён", first.string == "🙂 A great result.")

        await fixture("This is a result.", NSRange(location: 10, length: 0))
        let stale = await snapshot()
        first.setSelectedRange(NSRange(location: 0, length: 0)); await pause()
        check("Старая каретка отклоняет вставку", !(await commit(stale, "bad ")) && first.string == "This is a result.")

        await fixture("This is a result.", NSRange(location: 10, length: 0))
        let changed = await snapshot()
        first.string = "This is a sentence."; first.setSelectedRange(NSRange(location: 10, length: 0)); await pause()
        check("Изменённый правый текст отклоняет вставку", !(await commit(changed, "bad ")) && first.string == "This is a sentence.")

        await fixture("This is a result.", NSRange(location: 10, length: 0))
        let other = await snapshot()
        await fixture("This is a result.", NSRange(location: 10, length: 0), view: second)
        check("Другое поле с тем же текстом отклоняет вставку", !(await commit(other, "bad ")) && second.string == "This is a result.")

        if let caret = (await snapshot())?.caret {
            for light in [false, true] {
                NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                CompletionChoicePanel.shared.show(["good ", "excellent ", "great "], selected: 1, caret: caret, title: "Варианты продолжения")
                await pause()
                check("Список виден в \(light ? "светлой" : "тёмной") теме", CompletionChoicePanel.shared.isVisible && window.firstResponder === second)
            }
            CompletionChoicePanel.shared.hide()
        } else { check("Каретка для списка доступна", false) }

        let engine = CompletionEngine.shared
        let model = CompletionModels.localURL(CompletionModels.all[0])
        engine.ensureRunning(model: model)
        let deadline = Date().addingTimeInterval(30)
        while engine.state != .ready && Date() < deadline { await pause() }
        check("Изолированный помощник готов", engine.state == .ready)
        if engine.state == .ready {
            func complete(_ prompt: String) async -> String {
                await withCheckedContinuation { continuation in
                    engine.complete(prompt: prompt, maxTokens: 60, temperature: 0.35) { continuation.resume(returning: $0 ?? "") }
                }
            }
            let ru = await complete(CompletionEditing.synonymPrompt(before: "Это ", selected: "хороший", after: " результат."))
            let en = await complete(CompletionEditing.synonymPrompt(before: "This is a ", selected: "good", after: " result."))
            check("Локальная модель даёт русские синонимы", !CompletionEditing.synonyms(ru, original: "хороший").isEmpty)
            let synonyms = CompletionEditing.synonyms(en, original: "good")
            check("Локальная модель даёт английские синонимы", !synonyms.isEmpty)
            await fixture("This is a good result.", NSRange(location: 10, length: 4))
            let modelTarget = await snapshot()
            check("Вариант модели заменяет реальное выделение", await commit(modelTarget, synonyms.first ?? ""))
            check("Замена модели сохраняет соседние слова", first.string.hasPrefix("This is a ") && first.string.hasSuffix(" result.") && !first.string.contains("good"))
            let raw = await complete(CompletionEditing.insertionPrompt(before: "Завтра мы", after: " в парк."))
            let insertion = CompletionEditing.insertion(raw, before: "Завтра мы", after: " в парк.")
            check("Модель заполняет пропуск без склейки", !insertion.isEmpty && insertion.hasPrefix(" "))
        }
        engine.stop()
        try? FileManager.default.removeItem(at: directory)
        window.orderOut(nil)
        print("completion native editing: \(count) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
