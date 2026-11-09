import Cocoa

/// Local dictation history (~/Library/Application Support/JustTellMe/history.json). Never leaves the Mac.
struct HistoryEntry: Codable {
    let id: UUID
    let date: Date
    let text: String
    let lang: String
    let app: String?
    let seconds: Double
}

final class History {
    static let shared = History()
    static let limit = 2000

    private(set) var entries: [HistoryEntry] = []   // newest first
    var onChange: (() -> Void)?
    var onStatsChange: (() -> Void)?
    private var url: URL { Paths.support.appendingPathComponent("history.json") }

    private init() {
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([HistoryEntry].self, from: d)) ?? []
        }
    }

    func add(text: String, lang: String, app: String?, seconds: Double) {
        entries.insert(HistoryEntry(id: UUID(), date: Date(), text: text, lang: lang, app: app, seconds: seconds), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(ids: Set<UUID>) { entries.removeAll { ids.contains($0.id) }; save() }
    func clear() { entries.removeAll(); save() }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(entries) { try? d.write(to: url, options: .atomic) }
        onChange?()
        onStatsChange?()
    }
}

// MARK: - Window

final class HistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [HistoryEntry] = []

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM, HH:mm"; return f
    }()

    func open() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "JustTellMe — История"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 320)
        w.center()

        search.placeholderString = "Поиск по истории"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        for (id, title, width) in [("date", "Когда", 110.0), ("text", "Текст", 470.0), ("app", "Приложение", 120.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            if id == "text" { c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = true
        table.style = .inset
        table.doubleAction = #selector(copySelected)
        table.target = self
        let menu = NSMenu()
        menu.addItem(withTitle: "Скопировать", action: #selector(copySelected), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Удалить", action: #selector(deleteSelected), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let copy = NSButton(title: "Скопировать", target: self, action: #selector(copySelected))
        copy.keyEquivalent = "\r"
        let del = NSButton(title: "Удалить", target: self, action: #selector(deleteSelected))
        let clear = NSButton(title: "Очистить всё…", target: self, action: #selector(clearAll))
        let hint = NSTextField(labelWithString: "Двойной клик — скопировать")
        hint.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [countLabel, hint, NSView(), clear, del, copy])

        let stack = NSStackView(views: [search, scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        w.contentView = stack
        for v in [search, scroll, bar] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window = w
        History.shared.onChange = { [weak self] in if self?.window?.isVisible == true { self?.reload() } }
    }

    private func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = q.isEmpty ? History.shared.entries
            : History.shared.entries.filter { $0.text.lowercased().contains(q) || ($0.app ?? "").lowercased().contains(q) }
        table.reloadData()
        let total = History.shared.entries.count
        countLabel.stringValue = q.isEmpty ? "Записей: \(total)" : "Найдено: \(rows.count) из \(total)"
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let e = rows[row]
        let id = col?.identifier.rawValue ?? ""
        let cell = (tableView.makeView(withIdentifier: .init(id), owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = .init(id)
            let t = NSTextField(wrappingLabelWithString: "")
            t.translatesAutoresizingMaskIntoConstraints = false
            t.isSelectable = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.topAnchor.constraint(equalTo: c.topAnchor, constant: 4),
                t.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -4),
            ])
            return c
        }()
        switch id {
        case "date":
            cell.textField?.stringValue = Self.dateFmt.string(from: e.date)
            cell.textField?.textColor = .secondaryLabelColor
        case "app":
            cell.textField?.stringValue = e.app ?? "—"
            cell.textField?.textColor = .secondaryLabelColor
        default:
            cell.textField?.stringValue = e.text
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    private var selected: [HistoryEntry] {
        let idx = table.selectedRowIndexes.isEmpty && table.clickedRow >= 0 ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return idx.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    @objc private func copySelected() {
        let items = selected
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.text).joined(separator: "\n"), forType: .string)
    }

    @objc private func deleteSelected() {
        let ids = Set(selected.map(\.id))
        guard !ids.isEmpty else { return }
        History.shared.remove(ids: ids)
        reload()
    }

    @objc private func clearAll() {
        let a = NSAlert()
        a.messageText = "Очистить всю историю?"
        a.informativeText = "Будут удалены все \(History.shared.entries.count) записей. Это нельзя отменить."
        a.addButton(withTitle: "Очистить")
        a.addButton(withTitle: "Отмена")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        History.shared.clear()
        reload()
    }
}
