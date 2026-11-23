import AppKit

func kbLog(_ message: String) {}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
GhostSuggestionPanel.debugOnce = false
let presenter = GhostSuggestionPanel.shared
guard let screen = NSScreen.screens.first?.visibleFrame else {
    print("ERROR: Экран недоступен, запусти AppKit-проверку вне sandbox")
    exit(2)
}
var checks = 0, failures = 0
func check(_ name: String, _ value: Bool) {
    checks += 1
    if !value { failures += 1 }
    print("\(value ? "PASS" : "FAIL"): \(name)")
}
func window() -> NSWindow { app.windows.first { $0.isVisible }! }
let caret = NSRect(x: screen.midX, y: screen.midY, width: 1, height: 18)
presenter.show("его отключить.", caret: caret, isCorrection: false, belowLine: true)
let pill = window()
let layer = pill.contentView?.layer
check("Плашка внутри строки закрывает текст под собой", layer?.backgroundColor?.alpha == 1)
check("Плашка имеет скругление", (layer?.cornerRadius ?? 0) > 0)
check("Плашка отделена от документа рамкой и тенью", (layer?.borderWidth ?? 0) > 0 && pill.hasShadow)
check("Плашка привязана к каретке снизу", pill.frame.maxY < caret.minY && abs(pill.frame.minX - caret.minX) < 20)
check("Плашка не забирает фокус и мышь", !pill.canBecomeKey && !pill.canBecomeMain && pill.ignoresMouseEvents)
let anchor = pill.frame.origin
presenter.show(" отключить.", caret: caret, isCorrection: false, belowLine: true, typedPrefix: "его")
let label = pill.contentView!.subviews.compactMap { $0 as? NSTextField }.first!
check("Набранная часть остаётся в плашке", label.attributedStringValue.string == "его отключить.")
check("Набранная часть отличается от продолжения", !(label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor)
      .isEqual(label.attributedStringValue.attribute(.foregroundColor, at: 4, effectiveRange: nil)))
check("При наборе плашка остаётся у исходной каретки", pill.frame.origin == anchor)
if let directory = ProcessInfo.processInfo.environment["SPEAKEY_GHOST_PREVIEW_DIR"] {
    try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        pill.appearance = NSAppearance(named: appearance)
        presenter.show(" отключить.", caret: caret, isCorrection: false, belowLine: true, typedPrefix: "его")
        let content = pill.contentView!
        content.displayIfNeeded()
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("midline-\(name).png"))
    }
}
let edge = NSRect(x: screen.maxX - 4, y: screen.minY + 3, width: 1, height: 20)
presenter.show(String(repeating: "продолжение ", count: 40), caret: edge, isCorrection: false, belowLine: true)
check("Длинная плашка остаётся в пределах экрана", screen.contains(pill.frame))
check("У нижнего края плашка переносится над кареткой", pill.frame.minY >= edge.maxY)
presenter.show(" продолжение", caret: caret, isCorrection: false)
check("В конце текста фон остаётся прозрачным", (pill.contentView?.layer?.backgroundColor?.alpha ?? 0) == 0 && !pill.hasShadow)
check("В конце текста подсказка стоит на строке каретки", abs(pill.frame.midY - caret.midY) <= 1)
check("При выходе из середины старый префикс убирается", label.stringValue == " продолжение")
let editorFont = NSFont(name: "TimesNewRomanPSMT", size: 17.5)!
let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
editor.font = editorFont; editor.string = "Проверка"; editor.textContainerInset = .zero
let manager = editor.layoutManager!
manager.ensureLayout(for: editor.textContainer!)
let glyph = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil).location
let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
let editorCaret = NSRect(x: caret.minX + 0.5, y: caret.minY + 0.5, width: 0, height: line.height)
presenter.show("хочу, чтобы оно было", caret: editorCaret, isCorrection: false, textFont: editorFont)
let actualFont = label.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
let editorBaseline = editorCaret.maxY - manager.location(forGlyphAt: glyph).y
let previewBaseline = pill.frame.minY + label.frame.maxY - label.firstBaselineOffsetFromTop
print("baseline: editor=\(editorBaseline), preview=\(previewBaseline), nativeOffset=\(manager.location(forGlyphAt: glyph).y), defaultOffset=\(manager.defaultBaselineOffset(for: editorFont))")
check("Обычная подсказка использует шрифт и размер исходного редактора", actualFont?.fontName == editorFont.fontName && actualFont?.pointSize == 17.5)
check("Базовая линия подсказки совпадает с настоящей строкой NSTextView", abs(previewBaseline - editorBaseline) <= 0.5 / NSScreen.screens.first!.backingScaleFactor)
check("Текст начинается у каретки без двойного отступа NSTextField", abs(pill.frame.minX + label.frame.minX + label.alignmentRectInsets.left - editorCaret.minX) <= 0.5)
let field = NSRect(x: caret.minX - 250, y: caret.minY - 5, width: 300, height: 28)
let nearRight = NSRect(x: field.maxX - 6, y: caret.minY, width: 1, height: caret.height)
let overflow = " длинное продолжение"
presenter.show(overflow, caret: nearRight, isCorrection: false, fieldBounds: field)
check("У правого края поля подсказка остаётся в его горизонтальных границах",
      pill.frame.minX >= field.minX && pill.frame.maxX <= field.maxX)
check("У правого края поля продолжение опускается под строку", pill.frame.maxY < nearRight.minY)
check("В плашке у края сохраняется полное продолжение", label.stringValue == overflow)
presenter.show(" да", caret: caret, isCorrection: false, fieldBounds: field)
check("Короткое продолжение остаётся на строке", !pill.hasShadow && abs(pill.frame.midY - caret.midY) <= 1)
presenter.show(overflow, caret: edge, isCorrection: false)
check("Когда границы поля недоступны, подсказка остаётся на экране", screen.contains(pill.frame))
presenter.hide()
check("Отмена скрывает плашку", !presenter.isVisible)
print("ghost suggestion panel: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
