import Cocoa

/// Small helpers for building plain AppKit windows without nibs.
private func makeTextView(_ text: String, editable: Bool = true) -> (NSScrollView, NSTextView) {
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

private func label(_ s: String, bold: Bool = false) -> NSTextField {
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

// MARK: - Dictionary / prompt / replacements editor

final class VocabularyWindow: NSObject {
    private var window: NSWindow?
    private var promptView: NSTextView!
    private var dictView: NSTextView!
    private var rulesView: NSTextView!
    private var builtinToggle: NSButton!

    func open() {
        let v = Vocabulary.shared
        v.reload()
        let w = window ?? makeWindow("JustTellMe — Словарь и замены", NSSize(width: 700, height: 760))
        window = w

        let (ps, pv) = makeTextView(v.basePrompt)
        let (ds, dv) = makeTextView((try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? Vocabulary.dictionaryHeader)
        let (rs, rv) = makeTextView((try? String(contentsOf: Paths.replacements, encoding: .utf8)) ?? Vocabulary.replacementsHeader)
        promptView = pv; dictView = dv; rulesView = rv

        let builtinText = "СЛОВА (\(v.builtinTerms.count); * = в подсказке):\n"
            + v.builtinTerms.map { v.builtinPromptTerms.contains($0) ? "* " + $0 : $0 }.joined(separator: ", ")
            + "\n\nЗАМЕНЫ (\(v.builtinRules.count)):\n"
            + v.builtinRules.sorted { $0.from < $1.from }.map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
        let (bs, bv) = makeTextView(builtinText, editable: false)
        bv.font = NSFont.systemFont(ofSize: 11)
        bv.textColor = .secondaryLabelColor

        builtinToggle = NSButton(checkboxWithTitle: "Использовать встроенный словарь (\(v.builtinTerms.count) слов, \(v.builtinRules.count) замен) — только чтение",
                                 target: self, action: #selector(toggleBuiltin))
        builtinToggle.state = v.builtinEnabled ? .on : .off

        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        let folder = NSButton(title: "Открыть папку", target: self, action: #selector(openFolder))
        let reset = NSButton(title: "Подсказка по умолчанию", target: self, action: #selector(resetPrompt))
        let buttons = NSStackView(views: [reset, folder, NSView(), save])
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
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [ps, ds, rs, bs, buttons] { v.translatesAutoresizingMaskIntoConstraints = false }
        w.contentView = stack
        NSLayoutConstraint.activate([
            ps.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            ds.widthAnchor.constraint(equalTo: ps.widthAnchor),
            rs.widthAnchor.constraint(equalTo: ps.widthAnchor),
            bs.widthAnchor.constraint(equalTo: ps.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: ps.widthAnchor),
            ps.heightAnchor.constraint(equalToConstant: 56),
            ds.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
            rs.heightAnchor.constraint(equalTo: ds.heightAnchor),
            bs.heightAnchor.constraint(equalToConstant: 150),
        ])
        show(w)
    }

    @objc private func toggleBuiltin() { Vocabulary.shared.builtinEnabled = builtinToggle.state == .on }

    @objc private func saveAction() {
        Vocabulary.shared.save(prompt: promptView.string, dictionary: dictView.string, replacements: rulesView.string)
        window?.close()
    }

    @objc private func resetPrompt() { promptView.string = Vocabulary.defaultPrompt }
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

// MARK: - Welcome / status window

/// Shown on first launch, whenever something is missing, and when the app is opened again
/// from Finder/Launchpad — a menu-bar-only app otherwise looks like "nothing happened".
final class WelcomeWindow: NSObject {
    struct Status {
        var hotkey: String
        var micOK: Bool
        var accessOK: Bool
        var modelReady: Bool
        var conflictingApp: String?
        var fnSwitchesInput: Bool
    }

    var onOpenAccessibility: (() -> Void)?
    var onOpenMic: (() -> Void)?

    private var window: NSWindow?
    private var timer: Timer?
    private var provider: (() -> Status)?
    private var stack: NSStackView!

    var isVisible: Bool { window?.isVisible ?? false }

    func open(status: @escaping () -> Status) {
        provider = status
        let w = window ?? makeWindow("JustTellMe", NSSize(width: 520, height: 420))
        w.styleMask.remove(.resizable)
        window = w
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        w.contentView = stack
        render()
        show(w)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { self?.timer?.invalidate(); return }
            self.render()
        }
    }

    private func render() {
        guard let s = provider?() else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let title = label("JustTellMe работает в строке меню", bold: true)
        title.font = NSFont.boldSystemFont(ofSize: 17)
        let how = label("Зажмите \(s.hotkey), говорите, отпустите — текст вставится туда, где стоит курсор. Значок 🎙 в строке меню вверху справа.")
        let head = NSStackView(views: [icon, NSStackView(views: [title, how])])
        (head.arrangedSubviews[1] as! NSStackView).orientation = .vertical
        (head.arrangedSubviews[1] as! NSStackView).alignment = .leading
        head.alignment = .top
        head.spacing = 14
        stack.addArrangedSubview(head)
        stack.addArrangedSubview(NSBox.separator())
        stack.arrangedSubviews.last?.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true

        stack.addArrangedSubview(row(ok: s.micOK, "Микрофон", s.micOK ? "разрешён" : "нет доступа",
                                     button: s.micOK ? nil : ("Разрешить…", #selector(micAction))))
        stack.addArrangedSubview(row(ok: s.accessOK, "Универсальный доступ", s.accessOK ? "разрешён" : "нужен для клавиши и вставки текста",
                                     button: s.accessOK ? nil : ("Открыть настройки…", #selector(accessAction))))
        stack.addArrangedSubview(row(ok: s.modelReady, "Модель распознавания", s.modelReady ? "загружена" : "загружается (первый запуск до минуты)…", button: nil))
        if !s.accessOK {
            stack.addArrangedSubview(label("Если JustTellMe уже включён в списке, но здесь всё ещё ✗ — удалите его кнопкой «−» и добавьте заново (так бывает после обновления приложения)."))
        }
        if let app = s.conflictingApp {
            stack.addArrangedSubview(row(ok: false, "Запущен \(app)", "он тоже слушает клавишу диктовки — закройте его", button: nil))
        }
        if s.fnSwitchesInput {
            stack.addArrangedSubview(row(ok: false, "Клавиша 🌐 переключает раскладку",
                                         "в «Настройки → Клавиатура» выберите «Нажатие 🌐: Ничего не делать» или смените клавишу в меню JustTellMe",
                                         button: ("Настройки клавиатуры…", #selector(keyboardAction))))
        }
        let close = NSButton(title: "Готово", target: self, action: #selector(closeAction))
        close.keyEquivalent = "\r"
        stack.addArrangedSubview(NSStackView(views: [NSView(), close]))
        stack.arrangedSubviews.last?.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
    }

    private func row(ok: Bool, _ name: String, _ detail: String, button: (String, Selector)?) -> NSView {
        let mark = label(ok ? "✅" : "⚠️")
        let text = NSStackView(views: [label(name, bold: true), label(detail)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var views: [NSView] = [mark, text]
        if let (t, sel) = button { views.append(NSButton(title: t, target: self, action: sel)) }
        let r = NSStackView(views: views)
        r.alignment = .top
        r.spacing = 10
        text.widthAnchor.constraint(lessThanOrEqualToConstant: button == nil ? 430 : 270).isActive = true
        return r
    }

    @objc private func micAction() { onOpenMic?() }
    @objc private func accessAction() { onOpenAccessibility?() }
    @objc private func keyboardAction() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
    @objc private func closeAction() { window?.close() }
}

private extension NSBox {
    static func separator() -> NSBox { let b = NSBox(); b.boxType = .separator; return b }
}
