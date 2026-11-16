import AppKit

/// Проверка реальных полей без изменения пользовательских настроек и корпуса.
enum AutocompleteRecordingCheck {
    @MainActor static func run() async -> Int32 {
        setbuf(stdout, nil)
        var count = 0, failures = 0
        func check(_ name: String, _ value: Bool) {
            count += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL"): \(name)")
        }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 650, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Speakey · проверка финального текста"
        let first = NSTextView(frame: NSRect(x: 24, y: 160, width: 600, height: 130))
        let second = NSTextView(frame: NSRect(x: 24, y: 20, width: 600, height: 120))
        for view in [first, second] {
            view.font = .systemFont(ofSize: 20); view.isRichText = false
            window.contentView?.addSubview(view)
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func pause() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        func fixture(_ text: String, caret: Int, view: NSTextView? = nil) async {
            let view = view ?? first
            view.string = text; window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: caret, length: 0))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause()
        }
        func snapshot() async -> CompletionTarget? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let target = CompletionTarget.capture()
                    continuation.resume(returning: target?.pid == getpid() ? target : nil)
                }
            }
        }
        func read(_ identity: CompletionFieldIdentity?) async -> String? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: identity?.readText()) }
            }
        }
        func replace(_ count: Int, _ text: String) async -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
                  NSApp.keyWindow === window else { return false }
            return await withCheckedContinuation { continuation in
                TextReplacer.replace(deleteCount: count, with: text, onSubmission: { continuation.resume(returning: $0) })
            }
        }
        await fixture("Првиет мир справа", caret: 7)
        let original = await snapshot()
        var session = AutocompleteRecordingSession<CompletionFieldIdentity>()
        _ = session.note(field: original?.fieldIdentity, bundleID: "recording-fixture", text: await read(original?.fieldIdentity))
        check("Снимок до исправления содержит текст справа", await read(original?.fieldIdentity) == "Првиет мир справа")
        let submitted = await replace(7, "Привет ")
        let corrected = await snapshot()
        let verified = original.flatMap { source in corrected.map { source.verifies("Привет ", updated: $0, deletingBefore: 7) } } ?? false
        if submitted, verified, let original { session.confirmInsertion(field: original.fieldIdentity, text: await read(original.fieldIdentity)) }
        check("Исправление подтверждено чтением результата", submitted && verified && first.string == "Привет мир справа")
        first.string = "Привет, окончательная редакция справа"
        await fixture("Чужое поле", caret: 10, view: second)
        let completed = session.finish(finalText: await read(original?.fieldIdentity))
        check("При завершении прочитано исходное поле после потери фокуса", completed?.text == "Привет, окончательная редакция справа" && completed?.accepted == true)
        check("Чужое поле не попало в запись", completed?.text != second.string)

        await fixture("Начало справа", caret: 7)
        let consumed = await snapshot()
        _ = await replace(0, "текста ")
        let afterTyping = await snapshot()
        check("Набранная часть подсказки обновляет ожидаемый снимок", consumed.flatMap { source in afterTyping.map { source.expectingInsertion("текста ").matches($0) } } ?? false)

        await fixture("До вставки справа", caret: 3)
        let stale = await snapshot()
        var refused = AutocompleteRecordingSession<CompletionFieldIdentity>()
        _ = refused.note(field: stale?.fieldIdentity, bundleID: "recording-fixture", text: await read(stale?.fieldIdentity))
        await fixture("До вставки справа", caret: 3, view: second)
        let didCommit = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: stale?.commit("Ошибка ") ?? false) }
        }
        if didCommit, let stale { refused.confirmInsertion(field: stale.fieldIdentity, text: await read(stale.fieldIdentity)) }
        check("Устаревшая вставка не записана как принятие", !didCommit && refused.finish()?.accepted == false)

        if let identity = stale?.fieldIdentity {
            await fixture(String(repeating: "я", count: 32_001) + " ", caret: 32_002)
            check("Большое поле пропускается целиком", await read(identity) == nil)
            let longTarget = await snapshot()
            _ = await replace(0, "первое ")
            let longFirst = await snapshot()
            check("Часть подсказки подтверждается без полного чтения большого поля", longTarget.flatMap { source in longFirst.map { source.verifies("первое ", updated: $0) } } ?? false)
            _ = await replace(0, "второе ")
            let longSecond = await snapshot()
            check("Следующая часть использует обновлённую цель без записи корпуса", longFirst.flatMap { source in longSecond.map { source.verifies("второе ", updated: $0) } } ?? false)
            let longRead = await read(identity)
            check("Последовательные вставки сохранили большой текст", first.string.hasSuffix(" первое второе ") && longRead == nil)
            first.string = ""
            check("Пустое исходное поле читается без чужого текста", await read(identity) == "")
            first.removeFromSuperview()
            check("Закрытое поле пропускается", await read(identity) == nil)
        } else { check("Идентичность для проверки ограничения доступна", false) }
        window.orderOut(nil)
        print("autocomplete recording native: \(count) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
