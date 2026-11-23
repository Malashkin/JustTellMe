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
enum NoteCommand {
    static let keyword = "заметка"

    /// The note text when `text` starts with the keyword as a whole word, else nil.
    /// «Заметка, купить молоко.» → «Купить молоко.»; «Заметка.» → ""; «Заметками …» and «Это заметка …» → nil.
    static func body(of text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard t.count >= keyword.count,
              t.prefix(keyword.count).lowercased() == keyword else { return nil }
        let rest = t.dropFirst(keyword.count)
        if let next = rest.first, next.isLetter || next.isNumber { return nil }
        let leading = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "—–-"))
        var body = String(rest).trimmingCharacters(in: leading)
        // Keep the closing punctuation the recogniser put after the note itself.
        if body.isEmpty { return "" }
        if let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last, ".!?…".contains(last), !".!?…".contains(body.last!) {
            body.append(last)
        }
        return body.prefix(1).uppercased() + body.dropFirst()
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
    private var rows: [Row] = []

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy, EEEE"; return f
    }()

    private func build() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: "Начните фразу со слова «Заметка» — например, «Заметка: позвонить в банк». "
            + "Текст не вставится в приложение, а сохранится здесь.")
        hint.textColor = .secondaryLabelColor

        search.placeholderString = "Поиск по заметкам"
        search.delegate = self

        for (id, width) in [("time", 48.0), ("text", 600.0)] {
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

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        countLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [hint, search, scroll, countLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        for v in [hint, search, scroll, countLabel] as [NSView] {
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
                rows.append(.day(cal.isDateInToday(d) ? "Сегодня" : cal.isDateInYesterday(d) ? "Вчера" : Self.dayFmt.string(from: d)))
            }
            rows.append(.note(n))
        }
        table.reloadData()
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        countLabel.stringValue = all.isEmpty ? "Пока нет заметок"
            : q.isEmpty ? "Заметок: \(all.count)" : "Найдено: \(shown.count) из \(all.count)"
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
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
                t.stringValue = Self.timeFmt.string(from: n.date)
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
