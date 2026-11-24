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

/// The app's only window: a sidebar with Home (feed + quick stats), the voice lists (Notes, Tasks and any
/// the user creates), "New List", Statistics, Dictionary, Settings.
/// Opened from the menu-bar icon or by launching the app again from Finder/Launchpad/Dock.
final class MainWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Page: Int, CaseIterable {
        case home, stats, vocabulary, settings
        var title: String {
            [tr("Home", "Главная"), tr("Statistics", "Статистика"), tr("Dictionary", "Словарь"), tr("Settings", "Настройки")][rawValue]
        }
        var symbol: String { ["house", "chart.bar.xaxis", "character.book.closed", "gearshape"][rawValue] }
    }

    /// One row of the sidebar.
    enum Item: Equatable {
        case page(Page), list(UUID), addList
    }

    /// Home, then the lists in their order, "New List", then the fixed pages.
    static func sidebarItems(_ lists: [VoiceList]) -> [Item] {
        [.page(.home)] + lists.map { .list($0.id) } + [.addList, .page(.stats), .page(.vocabulary), .page(.settings)]
    }

    let home = HomePane()
    let stats = StatsPane()
    let vocabulary = VocabularyPane()
    let settings = SettingsPane()
    private var listPanes: [UUID: ListPane] = [:]

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let content = NSView()
    /// The blurred desktop behind everything.
    private let backdrop = Glass.backdrop()
    /// Auto / Light / Dark at the bottom of the sidebar.
    private let themeControl = CapsuleSegments(Prefs.Theme.allCases.map(\.title), symbols: Prefs.Theme.allCases.map(\.symbol))

    /// Where the window buttons sit: inside the sidebar panel (10 pt from the window edge) with room around them.
    static let windowButtonsInset = NSPoint(x: 26, y: 24)
    private var timer: Timer?
    private var items: [Item] = []
    private(set) var current: Item = .page(.home)
    var page: Page? { if case .page(let p) = current { return p } else { return nil } }

    var isVisible: Bool { window?.isVisible ?? false }

    override init() {
        super.init()
        items = Self.sidebarItems(VoiceLists.shared.lists)
        home.onOpenStats = { [weak self] in self?.open(.stats) }
        History.shared.onChange = { [weak self] in self?.historyChanged() }
        VoiceLists.shared.onChange = { [weak self] id in self?.listsChanged(id) }
    }

    func open(_ p: Page? = nil) { present(p.map { .page($0) } ?? current) }

    func openList(_ id: UUID) { present(.list(id)) }

    /// Every row except "New List", for --demo-window.
    var demoItems: [Item] { items.filter { $0 != .addList } }

    func present(_ item: Item) {
        if window == nil { build() }
        show(item)
        // A Dock icon while the window is open, so it can be found with ⌘Tab like any other app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        placeWindowButtons()
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

    /// Move the close/minimise/zoom buttons into the sidebar panel. macOS lays them out again on resize,
    /// key changes and full screen, so this runs after each of those.
    func placeWindowButtons() {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton), let mini = w.standardWindowButton(.miniaturizeButton),
              let zoom = w.standardWindowButton(.zoomButton), let titlebar = close.superview?.superview else { return }
        let inset = Self.windowButtonsInset
        let spacing: CGFloat = 20
        let height = inset.y * 2
        // Only as wide as the buttons, so the rest of the top edge stays clickable for the page under it.
        titlebar.frame = NSRect(x: 0, y: w.frame.height - height, width: inset.x * 2 + spacing * 2, height: height)
        for (i, b) in [close, mini, zoom].enumerated() {
            b.setFrameOrigin(NSPoint(x: inset.x - b.frame.width / 2 + CGFloat(i) * spacing,
                                     y: (height - b.frame.height) / 2))
        }
    }

    func windowDidResize(_ notification: Notification) { placeWindowButtons() }
    func windowDidEndLiveResize(_ notification: Notification) { placeWindowButtons() }
    func windowDidExitFullScreen(_ notification: Notification) { placeWindowButtons() }
    func windowDidBecomeKey(_ notification: Notification) { placeWindowButtons() }
    func windowDidResignKey(_ notification: Notification) { placeWindowButtons() }

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

    /// A list's entries changed (id), or the lists themselves (nil: renamed, added, deleted).
    private func listsChanged(_ id: UUID?) {
        if id == nil {
            items = Self.sidebarItems(VoiceLists.shared.lists)
            listPanes = listPanes.filter { VoiceLists.shared.list($0.key) != nil }
            sidebar.reloadData()
            if case .list(let cur) = current, VoiceLists.shared.list(cur) == nil { current = .page(.home) }
            if isVisible { show(current, force: true) }
            return
        }
        guard isVisible, current == .list(id!) else { return }
        listPanes[id!]?.reload()
    }

    private func pane(for id: UUID) -> ListPane {
        if let p = listPanes[id] { return p }
        let p = ListPane(listID: id)
        p.onConfigure = { [weak self] id in self?.editList(id) }
        listPanes[id] = p
        return p
    }

    /// "New List" (nil) or "Edit List…" of a list.
    func editList(_ id: UUID?) {
        switch ListEditor.run(id.flatMap { VoiceLists.shared.list($0) }) {
        case .saved(let l): openList(l.id)
        case .deleted: open(.home)
        case .cancelled: show(current, force: true)
        }
    }

    private func show(_ item: Item, force: Bool = false) {
        guard item != .addList else { return }
        current = item
        if let row = items.firstIndex(of: item), sidebar.selectedRow != row {
            sidebar.selectRowIndexes([row], byExtendingSelection: false)
        }
        let pane: NSView
        var title = "JustTellMe"
        switch item {
        case .page(let p):
            switch p {
            case .home: home.reload(); home.refreshStatus(); pane = home.view
            case .stats: stats.reload(); pane = titled(p, stats.view)
            case .vocabulary: vocabulary.reload(); pane = titled(p, vocabulary.view)
            case .settings: settings.reload(); pane = titled(p, settings.view)
            }
            if p != .home { title = p.title }
        case .list(let id):
            let lp = self.pane(for: id)
            lp.reload()
            pane = lp.view
            title = VoiceLists.shared.list(id)?.name ?? title
        case .addList:
            return
        }
        window?.title = title
        placeWindowButtons()
        if pane.superview === content { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        pane.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pane.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private var titledPanes: [Page: NSView] = [:]

    /// A page with a large title on top, like Home and the lists.
    private func titled(_ p: Page, _ pane: NSView) -> NSView {
        if let v = titledPanes[p] { return v }
        let t = NSTextField(labelWithString: p.title)
        t.font = .systemFont(ofSize: 28, weight: .bold)
        let v = NSView()
        for x in [t, pane] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            t.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            pane.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            pane.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 2),
            pane.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        titledPanes[p] = v
        return v
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 860, height: 600)
        w.delegate = self
        // Liquid Glass: no title bar, the desktop shows through the whole window.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isOpaque = false
        w.backgroundColor = .clear
        // The title bar is only as wide as the window buttons: the window is dragged by its empty glass.
        w.isMovableByWindowBackground = true
        w.setFrameAutosaveName("JustTellMeMain")
        if !w.setFrameUsingName("JustTellMeMain") { w.center() }

        let col = NSTableColumn(identifier: .init("page"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .plain
        sidebar.backgroundColor = .clear
        sidebar.selectionHighlightStyle = .regular
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.rowHeight = 34
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        sideScroll.automaticallyAdjustsContentInsets = false
        // Room for the window buttons, which sit on the sidebar panel.
        sideScroll.contentInsets = NSEdgeInsets(top: 44, left: 0, bottom: 8, right: 0)

        let root = NSView()
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        let side = GlassView(radius: 20)
        for v in [side, content] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        themeControl.onChange = { Prefs.theme = Prefs.Theme.allCases[$0] }
        themeControl.selected = Prefs.Theme.allCases.firstIndex(of: Prefs.theme) ?? 0
        NotificationCenter.default.addObserver(forName: Prefs.themeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.themeControl.selected = Prefs.Theme.allCases.firstIndex(of: Prefs.theme) ?? 0
        }
        for v in [sideScroll, themeControl] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; side.addSubview(v) }
        NSLayoutConstraint.activate([
            themeControl.centerXAnchor.constraint(equalTo: side.centerXAnchor),
            themeControl.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -12),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            side.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            side.widthAnchor.constraint(equalToConstant: 210),
            sideScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 6),
            sideScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -6),
            sideScroll.topAnchor.constraint(equalTo: side.topAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: themeControl.topAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        w.contentView = root
        w.setContentSize(NSSize(width: 1000, height: 700))
        backdrop.frame = root.bounds
        window = w
    }

    // MARK: sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let title: String, symbol: String
        var dim = false
        switch items[row] {
        case .page(let p): title = p.title; symbol = p.symbol
        case .list(let id):
            let l = VoiceLists.shared.list(id)
            title = l?.name ?? "?"
            symbol = l?.kind == .tasks ? "checklist" : "note.text"
        case .addList: title = tr("New List", "Новый список"); symbol = "plus"; dim = true
        }
        let cell = NSTableCellView()
        let img = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        img.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 14)
        t.lineBreakMode = .byTruncatingTail
        if dim { t.textColor = .secondaryLabelColor; img.contentTintColor = .secondaryLabelColor }
        for v in [img, t] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.imageView = img
        cell.textField = t
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 18),
            t.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 8),
            t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CapsuleRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item == .addList {
            // Not a page: keep the current page selected and ask for the new list.
            DispatchQueue.main.async { self.editList(nil) }
            if let cur = items.firstIndex(of: current) { sidebar.selectRowIndexes([cur], byExtendingSelection: false) }
            return
        }
        guard item != current || content.subviews.isEmpty else { return }
        show(item)
    }

    /// Render the window content to PNG (used by --demo-window). The blurred desktop can't be captured
    /// this way, so the glass is drawn over a soft sample wallpaper instead.
    func snapshot(to url: URL) {
        guard let v = window?.contentView else { return }
        if let n = window?.windowNumber { FileHandle.standardError.write("window \(n)\n".data(using: .utf8)!) }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        backdrop.isHidden = true
        v.cacheDisplay(in: v.bounds, to: rep)
        backdrop.isHidden = false
        let size = v.bounds.size
        let out = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.97, green: 0.85, blue: 0.77, alpha: 1),
                                NSColor(calibratedRed: 0.84, green: 0.86, blue: 0.99, alpha: 1),
                                NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.93, alpha: 1)])?.draw(in: rect, angle: -35)
            NSColor.white.withAlphaComponent(0.35).setFill()
            rect.fill(using: .sourceOver)
            rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        guard let tiff = out.tiffRepresentation, let full = NSBitmapImageRep(data: tiff) else { return }
        try? full.representation(using: .png, properties: [:])?.write(to: url)
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
    private let table = SelectableTextTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []

    private static var timeFmt: DateFormatter { L10n.formatter(en: "HH:mm", ru: "HH:mm") }
    private static var dayFmt: DateFormatter { L10n.formatter(en: "EEEE, MMMM d", ru: "d MMMM, EEEE") }

    private func build() -> NSView {
        hint.textColor = .secondaryLabelColor
        problems.orientation = .vertical
        problems.alignment = .leading
        problems.spacing = 10

        cards = [tr("Today", "Сегодня"), tr("Speed", "Скорость"), tr("Streak", "Серия"), tr("Time Saved", "Сэкономлено")].map { StatCard(title: $0) }
        let more = CapsuleButton(tr("All Statistics →", "Вся статистика →"), target: self, action: #selector(statsAction))
        let cardRow = NSStackView(views: cards)
        cardRow.distribution = .fillEqually
        cardRow.spacing = 10

        search.placeholderString = tr("Search dictations", "Поиск по надиктованному")
        search.delegate = self
        let feedTitle = NSTextField(labelWithString: tr("Dictated", "Надиктовано"))
        feedTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let feedHead = NSStackView(views: [feedTitle, NSView(), more, Glass.searchCapsule(search, width: 240)])
        feedHead.spacing = 12

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
        table.onCopy = { [weak self] in self?.copySelected() }
        let menu = NSMenu()
        menu.addItem(withTitle: tr("Copy", "Скопировать"), action: #selector(copySelected), keyEquivalent: "c").target = self
        menu.addItem(withTitle: tr("Correct and Remember…", "Исправить и запомнить…"), action: #selector(fixSelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Delete", "Удалить"), action: #selector(deleteSelected), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        countLabel.textColor = .secondaryLabelColor
        let tip = NSTextField(labelWithString: tr(
            "Select text with the mouse and press ⌘C · double-click the time to copy an entry · right-click to correct or delete",
            "Выделите текст мышью и нажмите ⌘C · двойной клик по времени — скопировать запись · правый клик — исправить или удалить"))
        tip.textColor = .tertiaryLabelColor
        tip.font = .systemFont(ofSize: 11)
        let clear = CapsuleButton(tr("Clear All…", "Очистить всё…"), style: .destructive, target: self, action: #selector(clearAll))
        let bar = NSStackView(views: [countLabel, tip, NSView(), clear])

        let title = NSTextField(labelWithString: tr("Home", "Главная"))
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let feed = Glass.card(scroll)
        table.selectionHighlightStyle = .regular
        let stack = NSStackView(views: [title, hint, problems, cardRow, feedHead, feed, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: cardRow)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(10, after: feedHead)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 16, right: 24)
        for v in [title, hint, problems, cardRow, feedHead, feed, bar] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        feed.setContentHuggingPriority(.defaultLow, for: .vertical)
        feed.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return stack
    }

    // MARK: status

    func refreshStatus() {
        _ = view
        let s = status()
        guard s != lastStatus else { return }
        lastStatus = s
        let k = s.hotkey
        hint.stringValue = tr("Hold \(k), speak, release — the text is pasted where the cursor is. ",
                              "Зажмите \(k), говорите, отпустите — текст вставится туда, где стоит курсор. ")
            + (Prefs.trigger == .holdOrDoubleTap ? tr("Double-press \(k) for hands-free dictation; press once more when done. ",
                                                      "Дважды нажмите \(k) — диктовка без рук, ещё одно нажатие — готово. ") : "")
            + (Prefs.trigger == .holdOrTap ? tr("Tap \(k) for hands-free dictation until the next press. ",
                                                "Короткое нажатие \(k) — диктовка без рук до следующего нажатия. ") : "")
            + tr("Esc cancels.", "Esc — отмена.")
        problems.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !s.micOK {
            addProblem(tr("No microphone access", "Нет доступа к микрофону"), tr("dictation doesn’t work without it", "без него диктовка не работает"),
                       (tr("Allow…", "Разрешить…"), #selector(micAction)))
        }
        if !s.accessOK {
            addProblem(tr("No Accessibility access", "Нет доступа «Универсальный доступ»"),
                       tr("needed to hear the \(s.hotkey) key and paste text. If JustTellMe is already turned on in the list, remove it with the “−” button and add it again (this can happen after an update).",
                          "нужен, чтобы слышать клавишу \(s.hotkey) и вставлять текст. Если JustTellMe уже включён в списке, удалите его кнопкой «−» и добавьте заново (так бывает после обновления)."),
                       (tr("Open Settings…", "Открыть настройки…"), #selector(accessAction)))
        }
        if !s.modelReady {
            addProblem(tr("Loading the speech recognition model…", "Модель распознавания загружается…"),
                       tr("the first launch takes up to a minute", "первый запуск — до минуты"), nil, ok: true)
        }
        if let app = s.conflictingApp {
            addProblem(tr("\(app) is running", "Запущен \(app)"),
                       tr("it also listens to the dictation key — quit it", "он тоже слушает клавишу диктовки — закройте его"), nil)
        }
        if s.fnSwitchesInput {
            addProblem(tr("The 🌐 key switches the input source", "Клавиша 🌐 переключает раскладку"),
                       tr("in System Settings → Keyboard, set “Press 🌐 key to” to “Do Nothing”, or choose another key in JustTellMe settings",
                          "в «Настройки → Клавиатура» выберите «Нажатие 🌐: Ничего не делать» или смените клавишу в настройках JustTellMe"),
                       (tr("Keyboard Settings…", "Настройки клавиатуры…"), #selector(keyboardAction)))
        }
        if let v = s.update {
            addProblem(tr("Version \(v) is available", "Доступна версия \(v)"),
                       tr("installs in a couple of clicks; permissions are kept", "обновление ставится в пару кликов, разрешения сохранятся"),
                       (tr("Install…", "Установить…"), #selector(updateAction)), ok: true, mark: "⬆️")
        }
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
        cards[0].value = "\(StatsPane.num(today.words)) \(L10n.plural(today.words, en: ("word", "words"), ru: ("слово", "слова", "слов")))"
        cards[1].value = total.words > 0 ? "\(Int(total.wpm.rounded())) \(tr("wpm", "слов/мин"))" : "—"
        cards[2].value = "\(streak) \(L10n.plural(streak, en: ("day", "days"), ru: ("день", "дня", "дней")))"
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
                let name = cal.isDateInToday(d) ? tr("Today", "Сегодня") : cal.isDateInYesterday(d) ? tr("Yesterday", "Вчера") : Self.dayFmt.string(from: d)
                rows.append(.day(name))
            }
            rows.append(.entry(e))
        }
        table.reloadData()
        let key = lastStatus?.hotkey ?? "Fn"
        let entries = L10n.plural(all.count, en: ("entry", "entries"), ru: ("запись", "записи", "записей"))
        countLabel.stringValue = all.isEmpty ? tr("Nothing here yet — hold \(key) and say something", "Пока пусто — зажмите \(key) и скажите что-нибудь")
            : q.isEmpty ? tr("\(all.count) \(entries)", "Записей: \(all.count)")
            : tr("\(shown.count) of \(all.count)", "Найдено: \(shown.count) из \(all.count)")
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    /// Wrapped rows need new heights when the window (and so the text column) is resized.
    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CapsuleRowView() }

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
                t.isSelectable = true   // select part of the text with the mouse, ⌘C
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
        countLabel.stringValue = items.count == 1 ? tr("Copied", "Скопировано")
            : tr("Copied \(items.count) entries", "Скопировано: \(items.count)")
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
        let n = History.shared.entries.count
        a.messageText = tr("Clear the whole history?", "Очистить всю историю?")
        a.informativeText = tr("All \(n) \(L10n.plural(n, en: ("entry", "entries"), ru: ("запись", "записи", "записей"))) will be deleted, and the statistics will be reset. This can’t be undone.",
                               "Будут удалены все \(n) записей. Статистика тоже обнулится. Это нельзя отменить.")
        a.addButton(withTitle: tr("Clear", "Очистить"))
        a.addButton(withTitle: tr("Cancel", "Отмена"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        History.shared.clear()
    }
}
