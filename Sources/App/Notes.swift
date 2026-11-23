import Cocoa

/// A voice note: a dictation that started with the word «Заметка».
/// Stored in ~/Library/Application Support/JustTellMe/notes.json. Never leaves the Mac.
struct Note: Codable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let lang: String
}

/// Recognises the spoken command «Заметка …» at the very start of a dictation.
/// The recogniser sometimes gets the word slightly wrong («Замевка», «Заметко», «За метка»), so the first word
/// may be one letter off; real words that are one letter off are listed in `lookalikes` and never count.
enum NoteCommand {
    static let keyword = "заметка"
    /// Ordinary words one letter away from the keyword: a phrase starting with them is not a note.
    static let lookalikes: Set<String> = ["заметна", "заметкам", "заметках", "зачетка", "наметка"]

    /// The note text when `text` starts with the keyword (or a near miss of it) as a whole word, else nil.
    /// «Заметка, купить молоко.» → «Купить молоко.»; «Замевка купить молоко» → «Купить молоко»;
    /// «Заметка.» → ""; «Заметками …», «Заметна …» and «Это заметка …» → nil.
    static func body(of text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = leadingWords(t, count: 2)
        guard let first = words.first else { return nil }
        var restStart: String.Index?
        if matches(first.word) {
            restStart = first.end
        } else if words.count == 2, first.word.count <= 3, matches(first.word + words[1].word) {
            restStart = words[1].end   // «За метка …»
        }
        guard let from = restStart else { return nil }
        let leading = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "—–-"))
        var body = String(t[from...]).trimmingCharacters(in: leading)
        if body.isEmpty { return "" }
        // Keep the closing punctuation the recogniser put after the note itself.
        if let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last, ".!?…".contains(last), !".!?…".contains(body.last!) {
            body.append(last)
        }
        return body.prefix(1).uppercased() + body.dropFirst()
    }

    /// Is `word` the keyword, or one letter off it (and not a real word that merely looks like it)?
    static func matches(_ word: String) -> Bool {
        let w = word.lowercased().replacingOccurrences(of: "ё", with: "е")
        if w == keyword { return true }
        guard !lookalikes.contains(w), abs(w.count - keyword.count) <= 1 else { return false }
        return editDistance(w, keyword, limit: 1) <= 1
    }

    /// The first `count` words (letters and digits) and where each ends.
    private static func leadingWords(_ s: String, count: Int) -> [(word: String, end: String.Index)] {
        var out: [(String, String.Index)] = []
        var i = s.startIndex
        while out.count < count, i < s.endIndex {
            while i < s.endIndex, !(s[i].isLetter || s[i].isNumber) {
                // Only spaces may separate the two halves of «За метка»; punctuation ends the search.
                if !out.isEmpty && !s[i].isWhitespace { return out }
                i = s.index(after: i)
            }
            let begin = i
            while i < s.endIndex, s[i].isLetter || s[i].isNumber { i = s.index(after: i) }
            if begin < i { out.append((String(s[begin..<i]), i)) }
        }
        return out
    }

    /// Levenshtein distance, giving up (returning limit + 1) once it exceeds `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if cur.min()! > limit { return limit + 1 }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }
}

final class Notes {
    static let shared = Notes()
    static let limit = 5000

    private(set) var entries: [Note] = []   // newest first
    var onChange: (() -> Void)?
    private var url: URL { Paths.support.appendingPathComponent("notes.json") }

    private init() { load() }

    /// Re-read the file (tests point Paths.support at a temporary folder).
    func load() {
        guard let d = try? Data(contentsOf: url) else { entries = []; return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([Note].self, from: d)) ?? []
    }

    @discardableResult
    func add(text: String, lang: String, date: Date = Date()) -> Note {
        let n = Note(id: UUID(), date: date, text: text, lang: lang)
        entries.insert(n, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
        return n
    }

    func remove(ids: Set<UUID>) {
        guard entries.contains(where: { ids.contains($0.id) }) else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Notes whose text contains `query` (case-insensitive); all notes for an empty query.
    static func filter(_ notes: [Note], query: String) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? notes : notes.filter { $0.text.lowercased().contains(q) }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(entries) { try? d.write(to: url, options: .atomic) }
        onChange?()
    }
}

// MARK: - Page «Заметки»: every note, newest first, grouped by day, with search

final class NotesPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row { case day(String), note(Note) }

    private(set) lazy var view: NSView = build()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(title: "Удалить", target: nil, action: nil)
    private let checkAllButton = NSButton(title: "Отметить все", target: nil, action: nil)
    private var rows: [Row] = []
    /// Notes ticked with the checkbox in front of them.
    private(set) var checked: Set<UUID> = []

    /// Ticks that still point at a visible note (a search or a deletion drops the rest,
    /// so «Удалить» never removes a note the user cannot see).
    static func visibleChecks(_ checked: Set<UUID>, shown: [Note]) -> Set<UUID> {
        checked.intersection(shown.map(\.id))
    }

    /// What «Удалить» removes: the ticked notes if any, otherwise the highlighted ones.
    static func toDelete(checked: Set<UUID>, highlighted: [Note], shown: [Note]) -> [Note] {
        checked.isEmpty ? highlighted : shown.filter { checked.contains($0.id) }
    }

    /// «Отметить все» ticks every visible note; when all are ticked already it clears the ticks.
    static func toggleAll(_ checked: Set<UUID>, shown: [Note]) -> Set<UUID> {
        let ids = Set(shown.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: checked) ? [] : ids
    }

    static func deleteTitle(_ n: Int) -> String {
        n == 0 ? "Удалить" : "Удалить \(n) \(StatsPane.plural(n, "заметку", "заметки", "заметок"))"
    }

    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = pattern; return f
    }
    private static let stampFmt = fmt("d MMM, HH:mm")
    private static let dayFmt = fmt("d MMMM yyyy, EEEE")
    private static let shortDayFmt = fmt("d MMMM")

    /// Day header: always shows the date, «Сегодня»/«Вчера» in front of it.
    static func dayTitle(_ day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(day, inSameDayAs: now) { return "Сегодня, " + shortDayFmt.string(from: day) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(day, inSameDayAs: y) { return "Вчера, " + shortDayFmt.string(from: day) }
        return dayFmt.string(from: day)
    }

    /// Date and time shown on every note, e.g. «23 нояб., 10:04».
    static func stamp(_ date: Date) -> String { stampFmt.string(from: date) }

    private func build() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: "Начните фразу со слова «Заметка» — например, «Заметка: позвонить в банк». "
            + "Текст не вставится в приложение, а сохранится здесь.")
        hint.textColor = .secondaryLabelColor

        search.placeholderString = "Поиск по заметкам"
        search.delegate = self

        for (id, width) in [("check", 22.0), ("time", 104.0), ("text", 540.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.width = width
            c.resizingMask = id == "text" ? .autoresizingMask : []
            table.addTableColumn(c)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        let menu = NSMenu()
        menu.addItem(withTitle: "Удалить", action: #selector(deleteClicked), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        countLabel.textColor = .secondaryLabelColor
        let tip = NSTextField(labelWithString: "Отметьте заметки галочками и нажмите «Удалить» · правый клик — удалить одну")
        tip.textColor = .tertiaryLabelColor
        tip.font = .systemFont(ofSize: 11)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.isEnabled = false
        checkAllButton.target = self
        checkAllButton.action = #selector(checkAllAction)
        let bar = NSStackView(views: [countLabel, tip, NSView(), checkAllButton, deleteButton])

        let stack = NSStackView(views: [hint, search, scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        for v in [hint, search, scroll, bar] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return stack
    }

    func reload() {
        _ = view
        let all = Notes.shared.entries
        let shown = Notes.filter(all, query: search.stringValue)
        rows = []
        let cal = Calendar.current
        var lastDay: Date?
        for n in shown {
            let d = cal.startOfDay(for: n.date)
            if d != lastDay {
                lastDay = d
                rows.append(.day(Self.dayTitle(d)))
            }
            rows.append(.note(n))
        }
        checked = Self.visibleChecks(checked, shown: shown)
        table.reloadData()
        updateButtons()
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        countLabel.stringValue = all.isEmpty ? "Пока нет заметок"
            : q.isEmpty ? "Заметок: \(all.count)" : "Найдено: \(shown.count) из \(all.count)"
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private var shownNotes: [Note] {
        rows.compactMap { if case .note(let n) = $0 { return n } else { return nil } }
    }

    private func updateButtons() {
        let shown = shownNotes
        let n = Self.toDelete(checked: checked, highlighted: selected, shown: shown).count
        deleteButton.title = Self.deleteTitle(checked.isEmpty ? 0 : n)
        deleteButton.isEnabled = n > 0
        checkAllButton.isEnabled = !shown.isEmpty
        checkAllButton.title = !shown.isEmpty && Set(shown.map(\.id)).isSubset(of: checked) ? "Снять отметки" : "Отметить все"
    }

    @objc private func checkAllAction() {
        checked = Self.toggleAll(checked, shown: shownNotes)
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: IndexSet(integer: 0))
        updateButtons()
    }

    @objc private func checkToggled(_ sender: NSButton) {
        guard sender.tag < rows.count, case .note(let n) = rows[sender.tag] else { return }
        if sender.state == .on { checked.insert(n.id) } else { checked.remove(n.id) }
        updateButtons()
    }

    /// The right-clicked note, or the selection when the click is inside it.
    private var selected: [Note] {
        let idx = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return idx.compactMap { i in
            guard i < rows.count, case .note(let n) = rows[i] else { return nil }
            return n
        }
    }

    /// Context menu: the right-clicked note (or the highlight it is part of).
    @objc private func deleteClicked() { confirmDelete(selected) }

    /// «Удалить» button: the ticked notes, or the highlighted ones when nothing is ticked.
    @objc private func deleteSelected() {
        confirmDelete(Self.toDelete(checked: checked, highlighted: selected, shown: shownNotes))
    }

    private func confirmDelete(_ notes: [Note]) {
        guard !notes.isEmpty else { return }
        let a = NSAlert()
        a.messageText = notes.count == 1 ? "Удалить заметку?"
            : "Удалить \(notes.count) \(StatsPane.plural(notes.count, "заметку", "заметки", "заметок"))?"
        a.informativeText = notes.count == 1 ? "«\(notes[0].text.prefix(120))»\n\nЭто нельзя отменить." : "Это нельзя отменить."
        a.addButton(withTitle: "Удалить")
        a.addButton(withTitle: "Отмена")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        checked.subtract(notes.map(\.id))
        Notes.shared.remove(ids: Set(notes.map(\.id)))
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if col?.identifier.rawValue == "check" {
            guard case .note(let n) = rows[row] else { return nil }
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
            box.tag = row
            box.state = checked.contains(n.id) ? .on : .off
            box.setAccessibilityLabel("Отметить заметку")
            let cell = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                box.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            ])
            return cell
        }
        let cell = NSTableCellView()
        let t = NSTextField(wrappingLabelWithString: "")
        t.translatesAutoresizingMaskIntoConstraints = false
        t.isSelectable = true
        cell.addSubview(t)
        cell.textField = t
        var top: CGFloat = 6
        switch rows[row] {
        case .day(let name):
            t.stringValue = name
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            t.textColor = .secondaryLabelColor
            top = 14
        case .note(let n):
            if col?.identifier.rawValue == "time" {
                t.stringValue = Self.stamp(n.date)
                t.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                t.textColor = .tertiaryLabelColor
                top = 7
            } else {
                t.stringValue = n.text
                t.font = Self.textFont
            }
        }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            t.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            t.topAnchor.constraint(equalTo: cell.topAnchor, constant: top),
            t.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
        ])
        return cell
    }

    private static let textFont = NSFont.systemFont(ofSize: 13)

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .day: return 36
        case .note(let n):
            let w = max(100, (tableView.tableColumns.last?.width ?? 600) - 8)
            let r = NSAttributedString(string: n.text, attributes: [.font: Self.textFont])
                .boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return ceil(r.height) + 14
        }
    }
}

// MARK: - «Заметка сохранена» card: confirms that nothing was pasted and the text went to Заметки

final class NoteSavedCard: NSObject {
    var onOpen: (() -> Void)?

    private var panel: NSPanel?
    private let body = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 380, height: 104)

    func show(_ text: String) {
        let p = panel ?? make()
        panel = p
        body.stringValue = text
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28)) }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        hide(after: 4)
    }

    private func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Debug: write the card as PNG (--demo-note-card).
    func snapshot(to url: URL) {
        guard let v = panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @objc private func openAction() { hide(after: 0); onOpen?() }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        let w = size.width - 28
        let title = NSTextField(labelWithString: "Заметка сохранена")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 14, y: size.height - 30, width: w, height: 18)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 2
        body.cell?.truncatesLastVisibleLine = true
        body.lineBreakMode = .byWordWrapping
        body.frame = NSRect(x: 14, y: 40, width: w, height: 32)
        let open = NSButton(title: "Открыть заметки", target: self, action: #selector(openAction))
        open.bezelStyle = .rounded
        open.frame = NSRect(x: size.width - 14 - 150, y: 6, width: 150, height: 30)
        for v in [title, body, open] as [NSView] { bg.addSubview(v) }
        p.contentView = bg
        return p
    }
}
