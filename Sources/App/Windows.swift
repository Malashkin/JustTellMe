import Cocoa

/// Small helpers for building plain AppKit windows without nibs.
func makeTextView(_ text: String, editable: Bool = true) -> (NSScrollView, NSTextView) {
    let sv = NSTextView.scrollableTextView()
    let tv = sv.documentView as! NSTextView
    tv.string = text
    tv.isEditable = editable
    tv.isRichText = false
    tv.allowsUndo = true
    tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    sv.borderType = .bezelBorder
    return (sv, tv)
}

func label(_ s: String, bold: Bool = false) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    if bold { l.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
    return l
}

private func makeWindow(_ title: String, _ size: NSSize) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.center()
    return w
}

private func show(_ w: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
}

// MARK: - Dictionary / prompt / replacements editor (page of the main window)

final class VocabularyPane: NSObject, NSTextViewDelegate {
    private(set) lazy var view: NSView = build()
    private var promptView: NSTextView!
    private var dictView: NSTextView!
    private var rulesView: NSTextView!
    private var builtinView: NSTextView!
    private var builtinToggle: NSButton!
    private let savedLabel = NSTextField(labelWithString: "")
    private var dirty = false

    /// Re-read the files (corrections may have added words) unless there are unsaved edits.
    func reload() {
        _ = view
        guard !dirty else { return }
        let v = Vocabulary.shared
        v.reload()
        promptView.string = v.basePrompt
        dictView.string = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? Vocabulary.dictionaryHeader
        rulesView.string = (try? String(contentsOf: Paths.replacements, encoding: .utf8)) ?? Vocabulary.replacementsHeader
        builtinView.string = "СЛОВА (\(v.builtinTerms.count); * = в подсказке):\n"
            + v.builtinTerms.map { v.builtinPromptTerms.contains($0) ? "* " + $0 : $0 }.joined(separator: ", ")
            + "\n\nЗАМЕНЫ (\(v.builtinRules.count)):\n"
            + v.builtinRules.sorted { $0.from < $1.from }.map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
        builtinToggle.title = "Использовать встроенный словарь (\(v.builtinTerms.count) слов, \(v.builtinRules.count) замен) — только чтение"
        builtinToggle.state = v.builtinEnabled ? .on : .off
    }

    private func build() -> NSView {
        let (ps, pv) = makeTextView("")
        let (ds, dv) = makeTextView("")
        let (rs, rv) = makeTextView("")
        let (bs, bv) = makeTextView("", editable: false)
        promptView = pv; dictView = dv; rulesView = rv; builtinView = bv
        for t in [pv, dv, rv] { t.delegate = self }
        bv.font = NSFont.systemFont(ofSize: 11)
        bv.textColor = .secondaryLabelColor

        builtinToggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleBuiltin))

        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        let folder = NSButton(title: "Открыть папку", target: self, action: #selector(openFolder))
        let reset = NSButton(title: "Подсказка по умолчанию", target: self, action: #selector(resetPrompt))
        savedLabel.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [reset, folder, NSView(), savedLabel, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [
            label("Подсказка (initial prompt) — задаёт стиль и смешение языков:", bold: true), ps,
            label("Личный словарь — ваши термины, имена, бренды (по одному на строку):", bold: true), ds,
            label("Личные замены после распознавания: «неправильно => правильно»:", bold: true), rs,
            builtinToggle, bs,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 16, right: 20)
        for v in [ps, ds, rs, bs, buttons] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            ps.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            ds.widthAnchor.constraint(equalTo: ps.widthAnchor),
            rs.widthAnchor.constraint(equalTo: ps.widthAnchor),
            bs.widthAnchor.constraint(equalTo: ps.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: ps.widthAnchor),
            ps.heightAnchor.constraint(equalToConstant: 56),
            ds.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            rs.heightAnchor.constraint(equalTo: ds.heightAnchor),
            bs.heightAnchor.constraint(equalToConstant: 110),
        ])
        return stack
    }

    func textDidChange(_ notification: Notification) { dirty = true; savedLabel.stringValue = "" }

    @objc private func toggleBuiltin() { Vocabulary.shared.builtinEnabled = builtinToggle.state == .on }

    @objc private func saveAction() {
        Vocabulary.shared.save(prompt: promptView.string, dictionary: dictView.string, replacements: rulesView.string)
        dirty = false
        reload()
        savedLabel.stringValue = "Сохранено ✓"
    }

    @objc private func resetPrompt() { promptView.string = Vocabulary.defaultPrompt; dirty = true }
    @objc private func openFolder() { NSWorkspace.shared.open(Paths.support) }
}

// MARK: - "Fix last phrase" (learning from corrections)

final class CorrectionWindow: NSObject {
    private var window: NSWindow?
    private var original = ""
    private var editView: NSTextView!
    var onCorrected: ((String) -> Void)?

    func open(original: String) {
        self.original = original
        let w = window ?? makeWindow("JustTellMe — Исправить последнюю фразу", NSSize(width: 560, height: 320))
        window = w
        let orig = label("Распознано: \(original)")
        orig.textColor = .secondaryLabelColor
        orig.isSelectable = true
        let (es, ev) = makeTextView(original)
        ev.font = NSFont.systemFont(ofSize: 15)
        editView = ev
        let save = NSButton(title: "Запомнить исправление", target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        let hint = label("Исправьте текст как надо. Новые слова попадут в словарь, а изменённые фрагменты — в замены (их можно поправить в «Словарь…»).")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [orig, es, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [es, buttons, hint, orig] { v.translatesAutoresizingMaskIntoConstraints = false }
        w.contentView = stack
        NSLayoutConstraint.activate([
            es.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: es.widthAnchor),
            hint.widthAnchor.constraint(equalTo: es.widthAnchor),
            orig.widthAnchor.constraint(equalTo: es.widthAnchor),
            es.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        show(w)
        w.makeFirstResponder(ev)
        ev.selectAll(nil)
    }

    @objc private func cancelAction() { window?.close() }

    @objc private func saveAction() {
        let corrected = editView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.close()
        guard !corrected.isEmpty, corrected != original else { return }
        let r = CorrectionLearner.learn(original: original, corrected: corrected)
        let rules = Vocabulary.shared.addRules(r.rules)
        let terms = Vocabulary.shared.addTerms(r.terms)
        onCorrected?(corrected)

        let a = NSAlert()
        a.messageText = "Исправление запомнено"
        var info: [String] = []
        if !terms.isEmpty { info.append("В словарь: " + terms.joined(separator: ", ")) }
        if !rules.isEmpty { info.append("Замены:\n" + rules.map { "  \($0.0) → \($0.1)" }.joined(separator: "\n")) }
        if info.isEmpty { info.append("Новых слов/замен не найдено (всё уже есть в словаре).") }
        info.append("\nИсправленный текст скопирован в буфер обмена.")
        a.informativeText = info.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
