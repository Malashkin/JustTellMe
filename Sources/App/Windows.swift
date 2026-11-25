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

// MARK: - Dictionary page: personal words, replacements, built-in dictionary, recogniser prompt

/// A word as a glass capsule, with a remove button when it can be removed.
final class Chip: GlassView {
    let text: String
    init(_ text: String, small: Bool = false, onRemove: (() -> Void)? = nil) {
        self.text = text
        super.init(radius: small ? 11 : 13, raised: !small)
        capsule = true
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: small ? 12 : 13)
        l.textColor = small ? .secondaryLabelColor : .labelColor
        var views: [NSView] = [l]
        if let onRemove {
            let x = ClosureButton(symbol: "xmark", size: 9, action: onRemove)
            x.setAccessibilityLabel(tr("Remove \(text)", "Удалить \(text)"))
            x.toolTip = tr("Remove", "Удалить")
            views.append(x)
        }
        let row = NSStackView(views: views)
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: small ? 22 : 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: small ? 9 : 11),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: onRemove == nil ? (small ? -9 : -11) : -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A borderless SF Symbol button that runs a closure.
final class ClosureButton: NSButton {
    private let run: () -> Void
    init(symbol: String, size: CGFloat, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Lays its subviews out left to right and wraps them onto new lines, like words in a paragraph.
final class FlowView: NSView {
    var spacing: CGFloat = 6
    private var height: CGFloat = 0
    override var isFlipped: Bool { true }

    func set(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = true; addSubview($0) }
        needsLayout = true
        arrange()
    }

    override func layout() { super.layout(); arrange() }

    private func arrange() {
        let width = max(bounds.width, 100)
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let size = v.fittingSize
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            v.frame = NSRect(x: x, y: y, width: min(size.width, width), height: size.height)
            x += size.width + spacing
            line = max(line, size.height)
        }
        let h = subviews.isEmpty ? 0 : y + line
        if h != height { height = h; invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
}

/// A flipped document view, so a scrolling page starts at the top.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class VocabularyPane: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    private(set) lazy var view: NSView = build()
    private let wordField = NSTextField()
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private let words = FlowView()
    private let wordsEmpty = VocabularyPane.note("")
    private let rules = NSStackView()
    private let rulesEmpty = VocabularyPane.note("")
    private let builtinSwitch = NSSwitch()
    private let builtinInfo = VocabularyPane.note("")
    private let builtinToggle = CapsuleButton(tr("Show List", "Показать список"), style: .glass)
    private let builtinWords = FlowView()
    private let builtinRules = FlowView()
    private var builtinBox: NSView!
    private let promptToggle = NSButton()
    private var promptBox: NSView!
    private let promptView = NSTextView()
    private var promptSave: DispatchWorkItem?

    /// For tests: what the page shows.
    var wordTitles: [String] { words.subviews.compactMap { ($0 as? Chip)?.text } }
    var ruleTitles: [String] { rules.arrangedSubviews.compactMap { $0.identifier?.rawValue } }

    /// Re-read the files: corrections may have added words.
    func reload() {
        _ = view
        let v = Vocabulary.shared
        v.reload()
        words.set(v.personalTerms.map { t in Chip(t) { [weak self] in self?.removeWord(t) } })
        wordsEmpty.isHidden = !v.personalTerms.isEmpty
        rules.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in v.personalRules.sorted(by: { $0.from.lowercased() < $1.from.lowercased() }) { rules.addArrangedSubview(ruleRow(r.from, r.to)) }
        rulesEmpty.isHidden = !v.personalRules.isEmpty
        builtinSwitch.state = v.builtinEnabled ? .on : .off
        let terms = Self.unique(v.builtinTerms).count, n = v.builtinRules.count
        builtinInfo.stringValue = tr("\(terms) popular English terms and \(n) fixes for how they come out of Russian speech. Read-only.",
                                     "\(terms) популярных английских терминов и \(n) исправлений того, как они получаются из русской речи. Только чтение.")
        if !builtinBox.isHidden { fillBuiltin() }
        if promptView.window?.firstResponder !== promptView { promptView.string = v.basePrompt }
    }

    // MARK: actions (also used by tests)

    func addWord(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if Vocabulary.shared.personalTerms.contains(where: { $0.lowercased() == t.lowercased() }) { return }
        // Even a word the built-in dictionary knows is kept: the user wants it in the prompt first.
        let s = ((try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? Vocabulary.dictionaryHeader)
        try? (s + (s.isEmpty || s.hasSuffix("\n") ? "" : "\n") + t + "\n").write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        reload()
    }

    func removeWord(_ t: String) { Vocabulary.shared.removeTerm(t); reload() }

    func addRule(_ from: String, _ to: String) {
        let a = from.trimmingCharacters(in: .whitespacesAndNewlines), b = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty, a.lowercased() != b.lowercased() else { return }
        Vocabulary.shared.removeRule(from: a)   // a new right side replaces the old one
        let s = ((try? String(contentsOf: Paths.replacements, encoding: .utf8)) ?? Vocabulary.replacementsHeader)
        try? (s + (s.isEmpty || s.hasSuffix("\n") ? "" : "\n") + "\(a) => \(b)\n").write(to: Paths.replacements, atomically: true, encoding: .utf8)
        reload()
    }

    func removeRule(_ from: String) { Vocabulary.shared.removeRule(from: from); reload() }

    @objc private func addWordAction() { addWord(wordField.stringValue); wordField.stringValue = "" }

    @objc private func addRuleAction() {
        guard !fromField.stringValue.isEmpty, !toField.stringValue.isEmpty else { return }
        addRule(fromField.stringValue, toField.stringValue)
        fromField.stringValue = ""; toField.stringValue = ""
        view.window?.makeFirstResponder(fromField)
    }

    @objc private func builtinChanged() { Vocabulary.shared.builtinEnabled = builtinSwitch.state == .on }

    @objc private func toggleBuiltinList() {
        builtinBox.isHidden.toggle()
        builtinToggle.title = builtinBox.isHidden ? tr("Show List", "Показать список") : tr("Hide List", "Скрыть список")
        if !builtinBox.isHidden { fillBuiltin() }
    }

    @objc private func togglePrompt() {
        promptBox.isHidden.toggle()
        promptToggle.state = promptBox.isHidden ? .off : .on
    }

    /// Demo: open the built-in list and the prompt, to check their layout.
    func demoExpand() {
        if builtinBox.isHidden { toggleBuiltinList() }
        if promptBox.isHidden { togglePrompt() }
        view.layoutSubtreeIfNeeded()
        if let doc = (view as? NSScrollView)?.documentView { doc.scroll(NSPoint(x: 0, y: doc.bounds.maxY)) }
    }

    @objc private func resetPrompt() { promptView.string = Vocabulary.defaultPrompt; Vocabulary.shared.setPrompt(Vocabulary.defaultPrompt) }
    @objc private func openFolder() { NSWorkspace.shared.open(Paths.support) }

    func textDidChange(_ notification: Notification) {
        promptSave?.cancel()
        let w = DispatchWorkItem { [weak self] in Vocabulary.shared.setPrompt(self?.promptView.string ?? "") }
        promptSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Enter in "wrong" moves to "right"; Enter in "right" adds the pair.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        if control === wordField { addWordAction(); return true }
        if control === fromField { view.window?.makeFirstResponder(toField); return true }
        if control === toField { addRuleAction(); return true }
        return false
    }

    // MARK: building

    private static func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private static func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        return l
    }

    private func field(_ f: NSTextField, _ placeholder: String, width: CGFloat) -> NSView {
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = placeholder
        f.delegate = self
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        let box = GlassView(radius: 15, raised: true)
        box.capsule = true
        f.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(f)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 30),
            box.widthAnchor.constraint(equalToConstant: width),
            f.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            f.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            f.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private func ruleRow(_ from: String, _ to: String) -> NSView {
        let a = NSTextField(labelWithString: from)
        let arrow = NSTextField(labelWithString: "→")
        let b = NSTextField(labelWithString: to)
        a.font = .systemFont(ofSize: 13); b.font = .systemFont(ofSize: 13, weight: .medium)
        a.textColor = .secondaryLabelColor
        arrow.textColor = .tertiaryLabelColor
        for l in [a, b] { l.lineBreakMode = .byTruncatingTail; l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let x = ClosureButton(symbol: "xmark", size: 10) { [weak self] in self?.removeRule(from) }
        x.setAccessibilityLabel(tr("Remove \(from)", "Удалить \(from)"))
        x.toolTip = tr("Remove", "Удалить")
        let row = NSStackView(views: [a, arrow, b, NSView(), x])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.identifier = .init("\(from) → \(to)")
        a.widthAnchor.constraint(equalToConstant: 240).isActive = true
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return row
    }

    private func card(_ content: NSView) -> NSView {
        let c = GlassView(radius: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
        ])
        return c
    }

    /// The built-in file repeats some terms in several sections; show each once.
    static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    private func fillBuiltin() {
        let v = Vocabulary.shared
        builtinWords.set(Self.unique(v.builtinTerms).map { Chip($0, small: true) })
        builtinRules.set(v.builtinRules.sorted { $0.from < $1.from }.map { Chip("\($0.from) → \($0.to)", small: true) })
    }

    private func build() -> NSView {
        let intro = Self.note(tr("Teach the recogniser your words, and fix what it keeps getting wrong. Changes are saved at once.",
                                 "Научите распознавание вашим словам и исправьте то, что оно путает. Изменения сохраняются сразу."))
        let folder = CapsuleButton(tr("Open Folder", "Открыть папку"), style: .plain, target: self, action: #selector(openFolder))
        folder.fontSize = 12
        let introRow = NSStackView(views: [intro, NSView(), folder])

        // Your words
        let addWord = CapsuleButton(tr("Add", "Добавить"), style: .prominent, target: self, action: #selector(addWordAction))
        let wordsHead = NSStackView(views: [Self.heading(tr("Your Words", "Ваши слова")), NSView(),
                                            field(wordField, tr("Name, brand or term", "Имя, бренд или термин"), width: 220), addWord])
        wordsHead.spacing = 8
        wordsEmpty.stringValue = tr("No words yet. Add names, brands and terms you say often; “Correct and Remember…” adds them too.",
                                    "Пока пусто. Добавьте имена, бренды и термины, которые часто произносите; «Исправить и запомнить…» тоже добавляет их сюда.")
        let wordsBody = NSStackView(views: [words, wordsEmpty])
        wordsBody.orientation = .vertical
        wordsBody.alignment = .leading
        words.widthAnchor.constraint(equalTo: wordsBody.widthAnchor).isActive = true
        let wordsNote = Self.note(tr("They go into the recogniser’s prompt, and their spelling is kept (Figma, GitHub).",
                                     "Они попадают в подсказку распознаванию, и их написание сохраняется (Figma, GitHub)."))

        // Replacements
        let addRule = CapsuleButton(tr("Add", "Добавить"), style: .prominent, target: self, action: #selector(addRuleAction))
        let arrow = NSTextField(labelWithString: "→")
        arrow.textColor = .tertiaryLabelColor
        let rulesHead = NSStackView(views: [Self.heading(tr("Replacements", "Замены")), NSView(),
                                            field(fromField, tr("Recognised as", "Распозналось как"), width: 170), arrow,
                                            field(toField, tr("Write instead", "Писать вместо"), width: 170), addRule])
        rulesHead.spacing = 8
        rules.orientation = .vertical
        rules.alignment = .leading
        rules.spacing = 0
        rulesEmpty.stringValue = tr("No replacements yet. Example: “пул реквест” → “pull request”.",
                                    "Пока нет замен. Например: «пул реквест» → «pull request».")
        let rulesBody = NSStackView(views: [rules, rulesEmpty])
        rulesBody.orientation = .vertical
        rulesBody.alignment = .leading
        rules.widthAnchor.constraint(equalTo: rulesBody.widthAnchor).isActive = true

        // Built-in dictionary
        builtinSwitch.target = self
        builtinSwitch.action = #selector(builtinChanged)
        builtinSwitch.controlSize = .small
        builtinToggle.target = self
        builtinToggle.action = #selector(toggleBuiltinList)
        builtinToggle.fontSize = 12
        let builtinTitle = NSTextField(labelWithString: tr("Built-in Dictionary", "Встроенный словарь"))
        builtinTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let builtinText = NSStackView(views: [builtinTitle, builtinInfo])
        builtinText.orientation = .vertical
        builtinText.alignment = .leading
        builtinText.spacing = 2
        let builtinRow = NSStackView(views: [builtinSwitch, builtinText, NSView(), builtinToggle])
        builtinRow.spacing = 12
        let listTitle = Self.note(tr("Terms", "Термины")), fixTitle = Self.note(tr("Fixes", "Исправления"))
        for t in [listTitle, fixTitle] { t.font = .systemFont(ofSize: 12, weight: .semibold) }
        let builtinList = NSStackView(views: [listTitle, builtinWords, fixTitle, builtinRules])
        builtinList.orientation = .vertical
        builtinList.alignment = .leading
        builtinList.spacing = 8
        builtinList.setCustomSpacing(16, after: builtinWords)
        for v in [builtinWords, builtinRules] { v.widthAnchor.constraint(equalTo: builtinList.widthAnchor).isActive = true }
        builtinBox = builtinList
        builtinBox.isHidden = true
        let builtinBody = NSStackView(views: [builtinRow, builtinList])
        builtinBody.orientation = .vertical
        builtinBody.alignment = .leading
        builtinBody.spacing = 14
        for v in [builtinRow, builtinList] { v.widthAnchor.constraint(equalTo: builtinBody.widthAnchor).isActive = true }

        // Advanced: the recogniser prompt
        promptToggle.setButtonType(.pushOnPushOff)
        promptToggle.bezelStyle = .disclosure
        promptToggle.title = ""
        promptToggle.state = .off
        promptToggle.target = self
        promptToggle.action = #selector(togglePrompt)
        let promptTitle = NSButton(title: tr("Advanced: Recogniser Prompt", "Дополнительно: подсказка распознаванию"), target: self, action: #selector(togglePrompt))
        promptTitle.isBordered = false
        promptTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let promptHead = NSStackView(views: [promptToggle, promptTitle])
        promptHead.spacing = 4
        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: 13)
        promptView.drawsBackground = false
        promptView.delegate = self
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.isAutomaticSpellingCorrectionEnabled = false
        promptView.textContainerInset = NSSize(width: 0, height: 2)
        promptView.isVerticallyResizable = true
        promptView.textContainer?.widthTracksTextView = true
        let promptScroll = NSScrollView()
        promptScroll.drawsBackground = false
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.documentView = promptView
        promptView.autoresizingMask = [.width]
        promptScroll.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let reset = CapsuleButton(tr("Default Prompt", "Подсказка по умолчанию"), style: .glass, target: self, action: #selector(resetPrompt))
        reset.fontSize = 12
        let promptNote = Self.note(tr("A sentence that sets the style and how Russian and English mix. Your words are added after it.",
                                      "Фраза, которая задаёт стиль и то, как смешиваются русский и английский. Ваши слова добавляются после неё."))
        let promptCard = card(promptScroll)
        let promptFoot = NSStackView(views: [promptNote, NSView(), reset])
        let promptStack = NSStackView(views: [promptCard, promptFoot])
        promptStack.orientation = .vertical
        promptStack.spacing = 8
        for v in [promptCard, promptFoot] { v.widthAnchor.constraint(equalTo: promptStack.widthAnchor).isActive = true }
        promptBox = promptStack
        promptBox.isHidden = true

        let wordsCard = card(wordsBody), rulesCard = card(rulesBody), builtinCard = card(builtinBody)
        let stack = NSStackView(views: [introRow, wordsHead, wordsCard, wordsNote, rulesHead, rulesCard, builtinCard, promptHead, promptStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: introRow)
        stack.setCustomSpacing(22, after: wordsNote)
        stack.setCustomSpacing(22, after: rulesCard)
        stack.setCustomSpacing(18, after: builtinCard)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 20, right: 24)
        for v in [introRow, wordsHead, wordsCard, wordsNote, rulesHead, rulesCard, builtinCard, promptStack] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }

        let doc = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        return scroll
    }
}

// MARK: - "Fix last phrase" (learning from corrections)

final class CorrectionWindow: NSObject {
    private var window: NSWindow?
    private var original = ""
    private var editView: NSTextView!
    var onCorrected: ((String) -> Void)?

    func open(original: String) {
        self.original = original
        let w = window ?? makeWindow(tr("JustTellMe — Correct Last Phrase", "JustTellMe — Исправить последнюю фразу"), NSSize(width: 560, height: 320))
        window = w
        let orig = label(tr("Recognized: \(original)", "Распознано: \(original)"))
        orig.textColor = .secondaryLabelColor
        orig.isSelectable = true
        let (es, ev) = makeTextView(original)
        ev.font = NSFont.systemFont(ofSize: 15)
        editView = ev
        let save = NSButton(title: tr("Remember Correction", "Запомнить исправление"), target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: tr("Cancel", "Отмена"), target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        let hint = label(tr("Correct the text as needed. New words go to the dictionary and changed fragments go to replacements (you can edit them on the Dictionary page).",
                         "Исправьте текст как надо. Новые слова попадут в словарь, а изменённые фрагменты — в замены (их можно поправить в «Словарь…»)."))
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
        a.messageText = tr("Correction Remembered", "Исправление запомнено")
        var info: [String] = []
        if !terms.isEmpty { info.append(tr("Added to dictionary: ", "В словарь: ") + terms.joined(separator: ", ")) }
        if !rules.isEmpty { info.append(tr("Replacements:\n", "Замены:\n") + rules.map { "  \($0.0) → \($0.1)" }.joined(separator: "\n")) }
        if info.isEmpty { info.append(tr("No new words or replacements found (everything is already in the dictionary).", "Новых слов/замен не найдено (всё уже есть в словаре).")) }
        info.append(tr("\nThe corrected text was copied to the clipboard.", "\nИсправленный текст скопирован в буфер обмена."))
        a.informativeText = info.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// A table whose text can be selected with the mouse and copied with ⌘C, like in Notes or Mail.
/// NSTableView normally keeps clicks for row selection; here a click or drag on selectable text goes to the text.
/// ⌘C with no text selected copies the selected rows through `onCopy`.
final class SelectableTextTableView: NSTableView, NSMenuItemValidation {
    var onCopy: (() -> Void)?
    /// Return / Enter on the highlighted row (lists: edit the entry).
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if let onReturn, [36, 76].contains(event.keyCode), !selectedRowIndexes.isEmpty { onReturn(); return }
        super.keyDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isSelectable { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? onCopy != nil && !selectedRowIndexes.isEmpty : true
    }
}
