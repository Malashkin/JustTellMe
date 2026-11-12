import Cocoa

/// What the home page needs to know about permissions and readiness.
struct AppStatus: Equatable {
    var hotkey = ""
    var micOK = false
    var accessOK = false
    var modelReady = false
    var conflictingApp: String?
    var fnSwitchesInput = false
    /// A newer version is available on GitHub.
    var update: String?
}

/// The app's only window: a sidebar with Главная (feed + quick stats), Статистика, Словарь, Настройки.
/// Opened from the menu-bar icon or by launching the app again from Finder/Launchpad/Dock.
final class MainWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Page: Int, CaseIterable {
        case home, stats, vocabulary, settings
        var title: String { ["Главная", "Статистика", "Словарь", "Настройки"][rawValue] }
        var symbol: String { ["house", "chart.bar.xaxis", "character.book.closed", "gearshape"][rawValue] }
    }

    let home = HomePane()
    let stats = StatsPane()
    let vocabulary = VocabularyPane()
    let settings = SettingsPane()

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let content = NSView()
    private var timer: Timer?
    private(set) var page: Page = .home

    var isVisible: Bool { window?.isVisible ?? false }

    override init() {
        super.init()
        home.onOpenStats = { [weak self] in self?.open(.stats) }
        History.shared.onChange = { [weak self] in self?.historyChanged() }
    }

    func open(_ p: Page? = nil) {
        if window == nil { build() }
        show(p ?? page)
        // A Dock icon while the window is open, so it can be found with ⌘Tab like any other app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Re-read app state (permissions, model, Neural Engine) into the visible page.
    func refresh() {
        guard isVisible else { return }
        switch page {
        case .home: home.refreshStatus()
        case .settings: settings.reload()
        default: break
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func historyChanged() {
        guard isVisible else { return }
        home.reload()
        if page == .stats { stats.reload() }
    }

    private func show(_ p: Page) {
        page = p
        if sidebar.selectedRow != p.rawValue { sidebar.selectRowIndexes([p.rawValue], byExtendingSelection: false) }
        let pane: NSView
        switch p {
        case .home: home.reload(); home.refreshStatus(); pane = home.view
        case .stats: stats.reload(); pane = stats.view
        case .vocabulary: vocabulary.reload(); pane = vocabulary.view
        case .settings: settings.reload(); pane = settings.view
        }
        guard pane.superview !== content else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        pane.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pane.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.title = p == .home ? "JustTellMe" : p.title
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 820, height: 600)
        w.delegate = self
        w.setFrameAutosaveName("JustTellMeMain")
        if !w.setFrameUsingName("JustTellMeMain") { w.center() }

        let col = NSTableColumn(identifier: .init("page"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 30
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        let sideVC = NSViewController()
        sideVC.view = sideScroll

        let contentVC = NSViewController()
        contentVC.view = content

        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sideVC)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 220
        sideItem.canCollapse = false
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        w.contentViewController = split
        w.setContentSize(NSSize(width: 960, height: 700))
        window = w
    }

    // MARK: sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { Page.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let p = Page(rawValue: row)!
        let cell = NSTableCellView()
        let img = NSImageView(image: NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title) ?? NSImage())
        let t = NSTextField(labelWithString: p.title)
        t.font = .systemFont(ofSize: 13)
        for v in [img, t] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.imageView = img
        cell.textField = t
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 18),
            t.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 8),
            t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let p = Page(rawValue: sidebar.selectedRow), p != page || content.subviews.isEmpty else { return }
        show(p)
    }

    /// Render the window content to PNG (used by --demo-window).
    func snapshot(to url: URL) {
        guard let v = window?.contentView else { return }
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: - Home: how-to, problems, quick stats, feed of everything dictated

final class HomePane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row { case day(String), entry(HistoryEntry) }

    var status: () -> AppStatus = { AppStatus() }
    var onOpenAccessibility: (() -> Void)?
    var onOpenMic: (() -> Void)?
    var onOpenStats: (() -> Void)?
    var onFix: ((String) -> Void)?
    var onInstallUpdate: (() -> Void)?

    private(set) lazy var view: NSView = build()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let problems = NSStackView()
    private var lastStatus: AppStatus?
    private var cards: [StatCard] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM, EEEE"; return f
    }()

    private func build() -> NSView {
        hint.textColor = .secondaryLabelColor
        problems.orientation = .vertical
        problems.alignment = .leading
        problems.spacing = 10

        cards = ["Сегодня", "Скорость", "Серия", "Сэкономлено"].map { StatCard(title: $0) }
        let more = NSButton(title: "Вся статистика →", target: self, action: #selector(statsAction))
        more.bezelStyle = .inline
        let cardRow = NSStackView(views: cards)
        cardRow.distribution = .fillEqually
        cardRow.spacing = 10

        search.placeholderString = "Поиск по надиктованному"
        search.delegate = self
        let feedTitle = NSTextField(labelWithString: "НАДИКТОВАНО")
        feedTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        feedTitle.textColor = .secondaryLabelColor
        let feedHead = NSStackView(views: [feedTitle, NSView(), more])

        for (id, width) in [("time", 48.0), ("text", 600.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.width = width
            if id == "text" { c.resizingMask = .autoresizingMask } else { c.resizingMask = [] }
            table.addTableColumn(c)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(copySelected)
        table.target = self
        let menu = NSMenu()
        menu.addItem(withTitle: "Скопировать", action: #selector(copySelected), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Исправить и запомнить…", action: #selector(fixSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Удалить", action: #selector(deleteSelected), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        countLabel.textColor = .secondaryLabelColor
        let tip = NSTextField(labelWithString: "Двойной клик — скопировать · правый клик — исправить или удалить")
        tip.textColor = .tertiaryLabelColor
        tip.font = .systemFont(ofSize: 11)
        let clear = NSButton(title: "Очистить всё…", target: self, action: #selector(clearAll))
        let bar = NSStackView(views: [countLabel, tip, NSView(), clear])

        let stack = NSStackView(views: [hint, problems, cardRow, feedHead, search, scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: cardRow)
        stack.setCustomSpacing(6, after: feedHead)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        for v in [hint, problems, cardRow, feedHead, search, scroll, bar] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return stack
    }

    // MARK: status

    func refreshStatus() {
        _ = view
        let s = status()
        guard s != lastStatus else { return }
        lastStatus = s
        hint.stringValue = "Зажмите \(s.hotkey), говорите, отпустите — текст вставится туда, где стоит курсор. "
            + (Prefs.trigger == .holdOrDoubleTap ? "Дважды нажмите \(s.hotkey) — диктовка без рук, ещё одно нажатие — готово. " : "")
            + (Prefs.trigger == .holdOrTap ? "Короткое нажатие \(s.hotkey) — диктовка без рук до следующего нажатия. " : "")
            + "Esc — отмена."
        problems.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !s.micOK { addProblem("Нет доступа к микрофону", "без него диктовка не работает", ("Разрешить…", #selector(micAction))) }
        if !s.accessOK {
            addProblem("Нет доступа «Универсальный доступ»",
                       "нужен, чтобы слышать клавишу \(s.hotkey) и вставлять текст. Если JustTellMe уже включён в списке, удалите его кнопкой «−» и добавьте заново (так бывает после обновления).",
                       ("Открыть настройки…", #selector(accessAction)))
        }
        if !s.modelReady { addProblem("Модель распознавания загружается…", "первый запуск — до минуты", nil, ok: true) }
        if let app = s.conflictingApp { addProblem("Запущен \(app)", "он тоже слушает клавишу диктовки — закройте его", nil) }
        if s.fnSwitchesInput {
            addProblem("Клавиша 🌐 переключает раскладку",
                       "в «Настройки → Клавиатура» выберите «Нажатие 🌐: Ничего не делать» или смените клавишу в настройках JustTellMe",
                       ("Настройки клавиатуры…", #selector(keyboardAction)))
        }
        if let v = s.update { addProblem("Доступна версия \(v)", "обновление ставится в пару кликов, разрешения сохранятся", ("Установить…", #selector(updateAction)), ok: true, mark: "⬆️") }
        problems.isHidden = problems.arrangedSubviews.isEmpty
    }

    private func addProblem(_ title: String, _ detail: String, _ button: (String, Selector)?, ok: Bool = false, mark: String? = nil) {
        let mark = NSTextField(labelWithString: mark ?? (ok ? "⏳" : "⚠️"))
        let t = label(title, bold: true)
        let d = label(detail)
        d.textColor = .secondaryLabelColor
        let text = NSStackView(views: [t, d])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var views: [NSView] = [mark, text]
        if let (bt, sel) = button { views.append(NSButton(title: bt, target: self, action: sel)) }
        let r = NSStackView(views: views)
        r.alignment = .top
        r.spacing = 10
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        problems.addArrangedSubview(r)
        r.widthAnchor.constraint(lessThanOrEqualTo: problems.widthAnchor).isActive = true
    }

    @objc private func micAction() { onOpenMic?() }
    @objc private func accessAction() { onOpenAccessibility?() }
    @objc private func keyboardAction() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
    @objc private func statsAction() { onOpenStats?() }
    @objc private func updateAction() { onInstallUpdate?() }

    // MARK: feed

    func reload() {
        _ = view
        let all = History.shared.entries
        let now = Date()
        let today = DictationStats(all.filter { Calendar.current.isDate($0.date, inSameDayAs: now) })
        let total = DictationStats(all)
        let streak = DictationStats.streak(all, now: now)
        cards[0].value = "\(StatsPane.num(today.words)) \(StatsPane.plural(today.words, "слово", "слова", "слов"))"
        cards[1].value = total.words > 0 ? "\(Int(total.wpm.rounded())) слов/мин" : "—"
        cards[2].value = "\(streak) \(StatsPane.plural(streak, "день", "дня", "дней"))"
        cards[3].value = StatsPane.duration(total.savedSeconds)
        cards[3].accent = true

        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? all : all.filter { $0.text.lowercased().contains(q) || ($0.app ?? "").lowercased().contains(q) }
        rows = []
        let cal = Calendar.current
        var lastDay: Date?
        for e in shown {
            let d = cal.startOfDay(for: e.date)
            if d != lastDay {
                lastDay = d
                let name = cal.isDateInToday(d) ? "Сегодня" : cal.isDateInYesterday(d) ? "Вчера" : Self.dayFmt.string(from: d)
                rows.append(.day(name))
            }
            rows.append(.entry(e))
        }
        table.reloadData()
        countLabel.stringValue = all.isEmpty ? "Пока пусто — зажмите \(lastStatus?.hotkey ?? "Fn") и скажите что-нибудь"
            : q.isEmpty ? "Записей: \(all.count)" : "Найдено: \(shown.count) из \(all.count)"
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    /// Wrapped rows need new heights when the window (and so the text column) is resized.
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
        t.isSelectable = false
        cell.addSubview(t)
        cell.textField = t
        var top: CGFloat = 6
        switch rows[row] {
        case .day(let name):
            t.stringValue = name
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            t.textColor = .secondaryLabelColor
            top = 14
        case .entry(let e):
            if col?.identifier.rawValue == "time" {
                t.stringValue = Self.timeFmt.string(from: e.date)
                t.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                t.textColor = .tertiaryLabelColor
                top = 7
            } else {
                t.attributedStringValue = Self.entryText(e)
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

    private static func entryText(_ e: HistoryEntry) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.paragraphSpacing = 2
        let s = NSMutableAttributedString(string: e.text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        if let app = e.app {
            s.append(NSAttributedString(string: "\n" + app, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]))
        }
        return s
    }

    /// Rows are measured by hand: wrapped text needs the current width of the text column.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .day: return 36
        case .entry(let e):
            let w = max(100, (tableView.tableColumns.last?.width ?? 600) - 8)
            let r = Self.entryText(e).boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return ceil(r.height) + 14
        }
    }

    private var selected: [HistoryEntry] {
        let idx = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return idx.compactMap { i in
            guard i < rows.count, case .entry(let e) = rows[i] else { return nil }
            return e
        }
    }

    @objc private func copySelected() {
        let items = selected
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.text).joined(separator: "\n"), forType: .string)
        countLabel.stringValue = items.count == 1 ? "Скопировано" : "Скопировано: \(items.count)"
    }

    @objc private func fixSelected() {
        guard let e = selected.first else { return }
        onFix?(e.text)
    }

    @objc private func deleteSelected() {
        let ids = Set(selected.map(\.id))
        guard !ids.isEmpty else { return }
        History.shared.remove(ids: ids)
    }

    @objc private func clearAll() {
        let a = NSAlert()
        a.messageText = "Очистить всю историю?"
        a.informativeText = "Будут удалены все \(History.shared.entries.count) записей. Статистика тоже обнулится. Это нельзя отменить."
        a.addButton(withTitle: "Очистить")
        a.addButton(withTitle: "Отмена")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        History.shared.clear()
    }
}
