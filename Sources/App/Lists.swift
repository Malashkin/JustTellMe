import Cocoa

// MARK: - Model

/// A voice list: a page in the sidebar that collects dictations starting with one of its command words
/// (e.g. "Note …" → Notes). Notes lists are plain; tasks lists add a status, a deadline and date filters.
struct VoiceList: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case notes, tasks
        var title: String {
            self == .notes ? tr("Notes — plain entries", "Заметки — просто записи")
                           : tr("Tasks — Backlog/Done status, due date, date filters", "Задачи — статус Backlog/Done, срок, фильтры по датам")
        }
    }
    let id: UUID
    var name: String
    var keywords: [String]
    var kind: Kind
}

enum TaskStatus: String, Codable, CaseIterable {
    case backlog, done
    var title: String { self == .backlog ? "Backlog" : "Done" }
}

/// One entry of a list. Notes use id, date, text and lang; tasks also status, doneAt and due.
struct ListItem: Codable, Equatable {
    let id: UUID
    let date: Date
    var text: String
    let lang: String
    var status: TaskStatus
    var doneAt: Date?
    /// Deadline, stored as the start of its day.
    var due: Date?

    init(id: UUID = UUID(), date: Date, text: String, lang: String, status: TaskStatus = .backlog, doneAt: Date? = nil, due: Date? = nil) {
        self.id = id; self.date = date; self.text = text; self.lang = lang
        self.status = status; self.doneAt = doneAt; self.due = due
    }

    /// Also reads the older notes.json entries, which have no status, doneAt or due.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        text = try c.decode(String.self, forKey: .text)
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? ""
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .backlog
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        due = try c.decodeIfPresent(Date.self, forKey: .due)
    }
}

// MARK: - Store

/// All voice lists: lists.json (names, command words, kinds, order) and one list-<id>.json per list.
/// Never leaves the Mac.
final class VoiceLists {
    static let shared = VoiceLists()
    static let itemLimit = 5000

    /// Ordinary words one letter away from a built-in command word: a phrase starting with them is not a command.
    static let lookalikes: [String: Set<String>] = [
        "заметка": ["заметна", "заметкам", "заметках", "зачетка", "наметка"],
        "задача": ["задачам", "задачах"],
    ]
    /// Shorter command words must be heard exactly: one letter off «идея» is «идем», «идеи», «идет».
    static let fuzzyMinLength = 6

    private(set) var lists: [VoiceList] = []
    private var cache: [UUID: [ListItem]] = [:]
    /// Called after a change: the list whose items changed, or nil when the lists themselves changed.
    var onChange: ((UUID?) -> Void)?

    private var listsURL: URL { Paths.support.appendingPathComponent("lists.json") }
    private func itemsURL(_ id: UUID) -> URL { Paths.support.appendingPathComponent("list-\(id.uuidString).json") }
    /// Where notes were kept before lists existed; moved into the notes list once.
    private var legacyNotesURL: URL { Paths.support.appendingPathComponent("notes.json") }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e
    }()

    private init() { load() }

    /// The lists created on the first run, named in the interface language.
    static func defaultLists() -> [VoiceList] {
        L10n.isRussian
            ? [VoiceList(id: UUID(), name: "Заметки", keywords: ["Заметка"], kind: .notes),
               VoiceList(id: UUID(), name: "Задачи", keywords: ["Задача"], kind: .tasks)]
            : [VoiceList(id: UUID(), name: "Notes", keywords: ["Note"], kind: .notes),
               VoiceList(id: UUID(), name: "Tasks", keywords: ["Task"], kind: .tasks)]
    }

    /// Re-read everything (tests point Paths.support at a temporary folder). On the first run creates
    /// the notes and tasks lists, and moves notes from notes.json into the notes list.
    func load() {
        cache = [:]
        if let d = try? Data(contentsOf: listsURL), let l = try? Self.decoder.decode([VoiceList].self, from: d) {
            lists = l
            return
        }
        lists = Self.defaultLists()
        if let d = try? Data(contentsOf: legacyNotesURL), let notes = try? Self.decoder.decode([ListItem].self, from: d), !notes.isEmpty {
            cache[lists[0].id] = notes
            saveItems(lists[0].id, notify: false)
        }
        saveLists(notify: false)
    }

    func list(_ id: UUID) -> VoiceList? { lists.first { $0.id == id } }

    func items(_ id: UUID) -> [ListItem] {
        if let c = cache[id] { return c }
        let loaded = (try? Data(contentsOf: itemsURL(id))).flatMap { try? Self.decoder.decode([ListItem].self, from: $0) } ?? []
        cache[id] = loaded
        return loaded
    }

    // MARK: lists

    @discardableResult
    func addList(name: String, keywords: [String], kind: VoiceList.Kind) -> VoiceList {
        let l = VoiceList(id: UUID(), name: name, keywords: keywords, kind: kind)
        lists.append(l)
        saveLists()
        return l
    }

    func updateList(_ l: VoiceList) {
        guard let i = lists.firstIndex(where: { $0.id == l.id }) else { return }
        lists[i] = l
        saveLists()
    }

    /// Deletes the list and every entry in it.
    func removeList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        cache[id] = nil
        try? FileManager.default.removeItem(at: itemsURL(id))
        saveLists()
    }

    // MARK: items

    @discardableResult
    func addItem(to list: UUID, text: String, lang: String, date: Date = Date()) -> ListItem {
        let item = ListItem(date: date, text: text, lang: lang)
        var all = items(list)
        all.insert(item, at: 0)
        if all.count > Self.itemLimit { all.removeLast(all.count - Self.itemLimit) }
        cache[list] = all
        saveItems(list)
        return item
    }

    func removeItems(_ ids: Set<UUID>, from list: UUID) {
        let all = items(list)
        guard all.contains(where: { ids.contains($0.id) }) else { return }
        cache[list] = all.filter { !ids.contains($0.id) }
        saveItems(list)
    }

    /// Done remembers when; back to Backlog forgets it.
    func setStatus(_ status: TaskStatus, ids: Set<UUID>, in list: UUID, now: Date = Date()) {
        update(ids, in: list) {
            guard $0.status != status else { return }
            $0.status = status
            $0.doneAt = status == .done ? now : nil
        }
    }

    func setDue(_ due: Date?, ids: Set<UUID>, in list: UUID) {
        let day = due.map { Calendar.current.startOfDay(for: $0) }
        update(ids, in: list) { $0.due = day }
    }

    private func update(_ ids: Set<UUID>, in list: UUID, _ change: (inout ListItem) -> Void) {
        var all = items(list)
        var changed = false
        for i in all.indices where ids.contains(all[i].id) {
            let before = all[i]
            change(&all[i])
            changed = changed || all[i] != before
        }
        guard changed else { return }
        cache[list] = all
        saveItems(list)
    }

    // MARK: matching a dictation

    static func spoken(_ keyword: String) -> SpokenKeyword {
        let k = SpokenKeyword.normalize(keyword)
        return SpokenKeyword(keyword: k, lookalikes: lookalikes[k] ?? [], fuzzy: k.count >= fuzzyMinLength)
    }

    /// The list a dictation belongs to and the text without the command word, or nil for an ordinary dictation.
    /// A word heard exactly wins over a near miss of another list's word; otherwise the first list wins.
    static func match(_ text: String, in lists: [VoiceList]) -> (list: VoiceList, body: String)? {
        var nearMiss: (VoiceList, String)?
        for l in lists {
            for k in l.keywords {
                guard let m = spoken(k).match(text) else { continue }
                if m.exact { return (l, m.body) }
                if nearMiss == nil { nearMiss = (l, m.body) }
            }
        }
        return nearMiss
    }

    func match(_ text: String) -> (list: VoiceList, body: String)? { Self.match(text, in: lists) }

    // MARK: editing a list

    /// «Заметка, Запись; Note» → ["Заметка", "Запись", "Note"]: split on commas, semicolons and new lines, no repeats.
    static func parseKeywords(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && seen.insert(SpokenKeyword.normalize($0)).inserted }
    }

    /// What is wrong with a list as typed, or nil when it can be saved.
    static func problem(name: String, keywords: [String], editing id: UUID?, among lists: [VoiceList]) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return tr("Enter a list name.", "Введите название списка.") }
        if keywords.isEmpty { return tr("Enter at least one command word.", "Введите хотя бы одно слово-команду.") }
        for k in keywords {
            if k.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
                return tr("“\(k)” — a command must be a single word. Separate several words with commas.",
                          "«\(k)» — команда должна быть одним словом. Несколько слов разделяйте запятой.")
            }
            let n = SpokenKeyword.normalize(k)
            if let other = lists.first(where: { $0.id != id && $0.keywords.contains { SpokenKeyword.normalize($0) == n } }) {
                return tr("The word “\(k)” already opens the list “\(other.name)”.", "Слово «\(k)» уже открывает список «\(other.name)».")
            }
        }
        return nil
    }

    // MARK: files

    private func saveLists(notify: Bool = true) {
        if let d = try? Self.encoder.encode(lists) { try? d.write(to: listsURL, options: .atomic) }
        if notify { onChange?(nil) }
    }

    private func saveItems(_ id: UUID, notify: Bool = true) {
        if let d = try? Self.encoder.encode(cache[id] ?? []) { try? d.write(to: itemsURL(id), options: .atomic) }
        if notify { onChange?(id) }
    }
}

// MARK: - Filters (tasks lists)

enum ListFilter {
    enum Status: Int, CaseIterable {
        case all, backlog, done
        var title: String { [tr("All", "Все"), "Backlog", "Done"][rawValue] }
    }

    /// Which date of a task the period applies to.
    enum DateField: Int, CaseIterable {
        case created, due, done
        var title: String { [tr("Created", "Создана"), tr("Due", "Срок"), tr("Done", "Сделана")][rawValue] }
    }

    enum Period: Equatable {
        case today, week, month, all
        case custom(Date, Date)
        static var presets: [(String, Period)] {
            [(tr("Today", "Сегодня"), .today), (tr("7 days", "7 дней"), .week), (tr("30 days", "30 дней"), .month), (tr("All dates", "Все даты"), .all)]
        }
    }

    static func date(of item: ListItem, _ field: DateField) -> Date? {
        switch field {
        case .created: return item.date
        case .due: return item.due
        case .done: return item.doneAt
        }
    }

    static func isOverdue(_ item: ListItem, now: Date) -> Bool {
        guard item.status == .backlog, let due = item.due else { return false }
        return due < Calendar.current.startOfDay(for: now)
    }

    /// Created and done look back (today, the last 7 or 30 days); a deadline looks ahead (due within the next
    /// 1, 7 or 30 days), and an overdue task in Backlog always counts. A custom period includes both end days.
    static func inPeriod(_ item: ListItem, _ field: DateField, _ period: Period, now: Date) -> Bool {
        if period == .all { return true }
        guard let d = date(of: item, field) else { return false }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func days(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
        switch period {
        case .all: return true
        case .custom(let a, let b):
            let from = cal.startOfDay(for: min(a, b)), to = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(a, b)))!
            return d >= from && d < to
        case .today, .week, .month:
            let n = period == .today ? 1 : period == .week ? 7 : 30
            if field == .due { return (d >= today && d < days(n)) || isOverdue(item, now: now) }
            return d >= days(-(n - 1)) && d < days(1)
        }
    }

    static func apply(_ items: [ListItem], kind: VoiceList.Kind, query: String, status: Status = .all,
                      field: DateField = .created, period: Period = .all, now: Date = Date()) -> [ListItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { i in
            if !q.isEmpty && !i.text.lowercased().contains(q) { return false }
            guard kind == .tasks else { return true }
            if status == .backlog && i.status != .backlog { return false }
            if status == .done && i.status != .done { return false }
            return inPeriod(i, field, period, now: now)
        }
    }

    /// Day groups for the table: by the chosen date, newest first (a deadline: soonest first).
    /// Entries without that date go last, under "No due date" / "Not done".
    static func groups(_ items: [ListItem], field: DateField, now: Date) -> [(title: String, items: [ListItem])] {
        let cal = Calendar.current
        let dated = items.filter { date(of: $0, field) != nil }
        let undated = items.filter { date(of: $0, field) == nil }
        let sorted = dated.sorted {
            let a = date(of: $0, field)!, b = date(of: $1, field)!
            return field == .due ? (a, $1.date) < (b, $0.date) : a > b
        }
        var out: [(String, [ListItem])] = []
        var lastDay: Date?
        for i in sorted {
            let d = cal.startOfDay(for: date(of: i, field)!)
            if d != lastDay {
                lastDay = d
                out.append((dayTitle(d, now: now), []))
            }
            out[out.count - 1].1.append(i)
        }
        if !undated.isEmpty { out.append((field == .due ? tr("No due date", "Без срока") : tr("Not done", "Не сделаны"), undated.sorted { $0.date > $1.date })) }
        return out
    }

    private static var stampFmt: DateFormatter { L10n.formatter(en: "MMM d, HH:mm", ru: "d MMM, HH:mm") }
    private static var shortDateFmt: DateFormatter { L10n.formatter(en: "MMM d", ru: "d MMM") }
    private static var dayFmt: DateFormatter { L10n.formatter(en: "EEEE, MMMM d, yyyy", ru: "d MMMM yyyy, EEEE") }
    private static var shortDayFmt: DateFormatter { L10n.formatter(en: "MMMM d", ru: "d MMMM") }

    /// Day header: always shows the date, with "Today", "Yesterday" or "Tomorrow" in front of it.
    static func dayTitle(_ day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        for (offset, word) in [(0, tr("Today", "Сегодня")), (-1, tr("Yesterday", "Вчера")), (1, tr("Tomorrow", "Завтра"))] {
            if let d = cal.date(byAdding: .day, value: offset, to: now), cal.isDate(day, inSameDayAs: d) {
                return word + ", " + shortDayFmt.string(from: day)
            }
        }
        return dayFmt.string(from: day)
    }

    /// Date and time shown on every entry, e.g. "Nov 23, 10:04".
    static func stamp(_ date: Date) -> String { stampFmt.string(from: date) }

    /// The small line under a task: "Due Nov 25 — overdue · Done Nov 24, 10:04".
    static func detail(_ item: ListItem, now: Date) -> String? {
        var parts: [String] = []
        if let due = item.due { parts.append(tr("Due ", "Срок: ") + shortDateFmt.string(from: due) + (isOverdue(item, now: now) ? tr(" — overdue", " — просрочено") : "")) }
        if item.status == .done, let d = item.doneAt { parts.append(tr("Done ", "Сделано: ") + stamp(d)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Page of one list

final class ListPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row { case day(String), item(ListItem) }

    let listID: UUID
    var onConfigure: ((UUID) -> Void)?

    private(set) lazy var view: NSView = build()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let table = SelectableTextTableView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let deleteButton = CapsuleButton(tr("Delete", "Удалить"), style: .destructive)
    private let checkAllButton = CapsuleButton(tr("Check All", "Отметить все"))
    private let doneButton = CapsuleButton("Done", style: .prominent)
    private let backlogButton = CapsuleButton(tr("To Backlog", "В Backlog"))
    private let dueButton = CapsuleButton(tr("Due Date…", "Срок…"))
    private let statusControl = CapsuleSegments(ListFilter.Status.allCases.map(\.title))
    private let fieldPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let periodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fromPicker = NSDatePicker()
    private let toPicker = NSDatePicker()
    private let dash = NSTextField(labelWithString: "—")
    private var filterRow = NSStackView()
    private var taskOnly: [NSView] = []
    private var rows: [Row] = []
    /// Entries ticked with the checkbox in front of them.
    private(set) var checked: Set<UUID> = []

    init(listID: UUID) {
        self.listID = listID
        super.init()
    }

    private var list: VoiceList? { VoiceLists.shared.list(listID) }
    private var kind: VoiceList.Kind { list?.kind ?? .notes }

    // MARK: pure helpers (tested)

    /// Ticks that still point at a visible entry (a search, a filter or a deletion drops the rest,
    /// so "Delete" never touches an entry the user cannot see).
    static func visibleChecks(_ checked: Set<UUID>, shown: [ListItem]) -> Set<UUID> {
        checked.intersection(shown.map(\.id))
    }

    /// What the buttons act on: the ticked entries if any, otherwise the highlighted ones.
    static func targets(checked: Set<UUID>, highlighted: [ListItem], shown: [ListItem]) -> [ListItem] {
        checked.isEmpty ? highlighted : shown.filter { checked.contains($0.id) }
    }

    /// "Check All" ticks every visible entry; when all are ticked already it clears the ticks.
    static func toggleAll(_ checked: Set<UUID>, shown: [ListItem]) -> Set<UUID> {
        let ids = Set(shown.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: checked) ? [] : ids
    }

    static func deleteTitle(_ n: Int, kind: VoiceList.Kind) -> String {
        guard n > 0 else { return tr("Delete", "Удалить") }
        return tr("Delete \(n) \(noun(n, kind: kind))", "Удалить \(n) \(noun(n, kind: kind))")
    }

    /// "task"/"entry" for a count, in the accusative form Russian needs after «Удалить».
    static func noun(_ n: Int, kind: VoiceList.Kind) -> String {
        kind == .tasks ? L10n.plural(n, en: ("task", "tasks"), ru: ("задачу", "задачи", "задач"))
                       : L10n.plural(n, en: ("entry", "entries"), ru: ("запись", "записи", "записей"))
    }

    /// Several entries are copied one per line, in the order shown.
    static func copyText(_ items: [ListItem]) -> String { items.map(\.text).joined(separator: "\n") }

    static func keywordHint(_ l: VoiceList) -> String {
        let words = l.keywords.map { tr("“\($0)”", "«\($0)»") }.joined(separator: ", ")
        return tr("Start a phrase with \(words) and the text is saved here instead of being pasted into the app. "
                  + "Select text with the mouse and press ⌘C; tick entries to delete several at once.",
                  "Начните фразу со слова \(words) — текст не вставится в приложение, а сохранится здесь. "
                  + "Выделите текст мышью и нажмите ⌘C; отметьте галочками, чтобы удалить несколько.")
    }

    // MARK: building

    private func build() -> NSView {
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        let configure = CapsuleButton(tr("Edit List…", "Настроить…"), target: self, action: #selector(configureAction))
        search.placeholderString = tr("Search", "Поиск")
        search.delegate = self
        let head = NSStackView(views: [titleLabel, NSView(), Glass.searchCapsule(search, width: 220), configure])
        head.spacing = 10
        hint.textColor = .secondaryLabelColor

        statusControl.onChange = { [weak self] _ in self?.reload() }
        fieldPopup.addItems(withTitles: ListFilter.DateField.allCases.map(\.title))
        fieldPopup.target = self
        fieldPopup.action = #selector(filterChanged)
        periodPopup.addItems(withTitles: ListFilter.Period.presets.map(\.0) + [tr("Custom range…", "Свой период…")])
        periodPopup.selectItem(at: 3)
                periodPopup.target = self
        periodPopup.action = #selector(filterChanged)
        for p in [fromPicker, toPicker] {
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = .yearMonthDay
            p.locale = L10n.locale
            p.dateValue = Date()
            p.target = self
            p.action = #selector(filterChanged)
        }
        fromPicker.dateValue = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
        let dateLabel = NSTextField(labelWithString: tr("Date:", "Дата:"))
        dateLabel.textColor = .secondaryLabelColor
        filterRow = NSStackView(views: [statusControl, NSView(), dateLabel, glassPopup(fieldPopup), glassPopup(periodPopup), fromPicker, dash, toPicker])
        filterRow.spacing = 8
        filterRow.setCustomSpacing(4, after: dateLabel)

        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.selectionHighlightStyle = .regular
        table.onCopy = { [weak self] in self?.copyClicked() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        countLabel.textColor = .secondaryLabelColor
        for (b, sel) in [(deleteButton, #selector(deleteSelected)), (checkAllButton, #selector(checkAllAction)),
                         (doneButton, #selector(markDone)), (backlogButton, #selector(markBacklog)), (dueButton, #selector(setDueAction))] {
            b.target = self
            b.action = sel
        }
        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let buttons = NSStackView(views: [countLabel, NSView(), doneButton, backlogButton, dueButton, checkAllButton, deleteButton])
        buttons.spacing = 6
        buttons.setCustomSpacing(14, after: countLabel)
        // The action bar floats under the list as one glass capsule.
        let bar = GlassView(radius: 22, raised: true)
        bar.capsule = true
        buttons.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(buttons)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 44),
            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -7),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        taskOnly = [filterRow, doneButton, backlogButton, dueButton]

        let card = Glass.card(scroll)
        let stack = NSStackView(views: [head, hint, filterRow, card, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: head)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 16, right: 24)
        for v in [head, hint, filterRow, card, bar] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        card.setContentHuggingPriority(.defaultLow, for: .vertical)
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return stack
    }

    /// Columns depend on the kind, which can be changed in "Edit List…".
    private func rebuildColumns() {
        let ids = kind == .tasks ? [("check", 22.0 + ListPane.rowPad), ("status", 86.0), ("time", 104.0), ("text", 480.0)]
                                 : [("check", 22.0 + ListPane.rowPad), ("time", 104.0), ("text", 540.0)]
        guard table.tableColumns.map(\.identifier.rawValue) != ids.map(\.0) else { return }
        table.tableColumns.forEach { table.removeTableColumn($0) }
        for (id, width) in ids {
            let c = NSTableColumn(identifier: .init(id))
            c.width = width
            c.resizingMask = id == "text" ? .autoresizingMask : []
            table.addTableColumn(c)
        }
    }

    // MARK: filters

    private var period: ListFilter.Period {
        let i = periodPopup.indexOfSelectedItem
        if i >= 0 && i < ListFilter.Period.presets.count { return ListFilter.Period.presets[i].1 }
        return .custom(fromPicker.dateValue, toPicker.dateValue)
    }
    private var field: ListFilter.DateField { ListFilter.DateField(rawValue: max(0, fieldPopup.indexOfSelectedItem)) ?? .created }
    private var statusFilter: ListFilter.Status { ListFilter.Status(rawValue: max(0, statusControl.selected)) ?? .all }

    @objc private func filterChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: data

    func reload() {
        _ = view
        guard let l = list else { return }
        titleLabel.stringValue = l.name
        hint.stringValue = Self.keywordHint(l)
        rebuildColumns()
        taskOnly.forEach { $0.isHidden = l.kind != .tasks }
        let custom = l.kind == .tasks && period != .all && ListFilter.Period.presets.allSatisfy { $0.1 != period }
        [fromPicker, dash, toPicker].forEach { $0.isHidden = !custom }

        let all = VoiceLists.shared.items(listID)
        let now = Date()
        let shown = ListFilter.apply(all, kind: l.kind, query: search.stringValue, status: statusFilter,
                                     field: l.kind == .tasks ? field : .created, period: l.kind == .tasks ? period : .all, now: now)
        rows = []
        for g in ListFilter.groups(shown, field: l.kind == .tasks ? field : .created, now: now) {
            rows.append(.day(g.title))
            rows += g.items.map { .item($0) }
        }
        checked = Self.visibleChecks(checked, shown: shown)
        table.reloadData()
        updateButtons()
        let filtered = shown.count != all.count
        if all.isEmpty {
            countLabel.stringValue = tr("Nothing here yet", "Пока пусто")
        } else if l.kind == .tasks {
            let open = all.filter { $0.status == .backlog }.count
            let tasks = L10n.plural(all.count, en: ("task", "tasks"), ru: ("задача", "задачи", "задач"))
            countLabel.stringValue = filtered
                ? tr("\(shown.count) of \(all.count) · \(open) in Backlog", "Показано: \(shown.count) из \(all.count) · в Backlog: \(open)")
                : tr("\(all.count) \(tasks) · \(open) in Backlog", "Задач: \(all.count) · в Backlog: \(open)")
        } else {
            let entries = L10n.plural(all.count, en: ("entry", "entries"), ru: ("запись", "записи", "записей"))
            countLabel.stringValue = filtered ? tr("\(shown.count) of \(all.count)", "Найдено: \(shown.count) из \(all.count)")
                                              : tr("\(all.count) \(entries)", "Записей: \(all.count)")
        }
    }

    private var shownItems: [ListItem] {
        rows.compactMap { if case .item(let i) = $0 { return i } else { return nil } }
    }

    /// The right-clicked entry, or the highlight when the click is inside it.
    private var selected: [ListItem] {
        let idx = table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow)
            ? IndexSet(integer: table.clickedRow) : table.selectedRowIndexes
        return idx.compactMap { i in
            guard i < rows.count, case .item(let it) = rows[i] else { return nil }
            return it
        }
    }

    private var buttonTargets: [ListItem] { Self.targets(checked: checked, highlighted: selected, shown: shownItems) }

    private func updateButtons() {
        let shown = shownItems
        let n = buttonTargets.count
        deleteButton.title = Self.deleteTitle(checked.isEmpty ? 0 : n, kind: kind)
        deleteButton.isEnabled = n > 0
        doneButton.isEnabled = n > 0
        backlogButton.isEnabled = n > 0
        dueButton.isEnabled = n > 0
        checkAllButton.isEnabled = !shown.isEmpty
        checkAllButton.title = !shown.isEmpty && Set(shown.map(\.id)).isSubset(of: checked) ? tr("Uncheck All", "Снять отметки") : tr("Check All", "Отметить все")
    }

    // MARK: actions

    @objc private func configureAction() { onConfigure?(listID) }

    @objc private func checkAllAction() {
        checked = Self.toggleAll(checked, shown: shownItems)
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: IndexSet(integer: 0))
        updateButtons()
    }

    @objc private func checkToggled(_ sender: NSButton) {
        guard sender.tag < rows.count, case .item(let i) = rows[sender.tag] else { return }
        if sender.state == .on { checked.insert(i.id) } else { checked.remove(i.id) }
        updateButtons()
    }

    /// The status capsule in front of a task opens a menu with Backlog / Done.
    @objc private func statusClicked(_ sender: NSButton) {
        guard sender.tag < rows.count, case .item(let i) = rows[sender.tag] else { return }
        let menu = NSMenu()
        for s in TaskStatus.allCases {
            let m = menu.addItem(withTitle: s.title, action: #selector(statusChosen(_:)), keyEquivalent: "")
            m.target = self
            m.state = s == i.status ? .on : .off
            m.representedObject = [i.id.uuidString, s.rawValue]
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func statusChosen(_ m: NSMenuItem) {
        guard let a = m.representedObject as? [String], a.count == 2,
              let id = UUID(uuidString: a[0]), let s = TaskStatus(rawValue: a[1]) else { return }
        VoiceLists.shared.setStatus(s, ids: [id], in: listID)
    }

    @objc private func markDone() { VoiceLists.shared.setStatus(.done, ids: Set(buttonTargets.map(\.id)), in: listID) }
    @objc private func markBacklog() { VoiceLists.shared.setStatus(.backlog, ids: Set(buttonTargets.map(\.id)), in: listID) }
    @objc private func setDueAction() { askDue(buttonTargets) }
    @objc private func deleteSelected() { confirmDelete(buttonTargets) }

    @objc private func copyClicked() {
        let items = selected
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.copyText(items), forType: .string)
        countLabel.stringValue = items.count == 1 ? tr("Copied", "Скопировано")
            : tr("Copied \(items.count) \(Self.noun(items.count, kind: kind))", "Скопировано: \(items.count)")
    }

    @objc private func menuDone() { VoiceLists.shared.setStatus(.done, ids: Set(selected.map(\.id)), in: listID) }
    @objc private func menuBacklog() { VoiceLists.shared.setStatus(.backlog, ids: Set(selected.map(\.id)), in: listID) }
    @objc private func menuDue() { askDue(selected) }
    @objc private func menuClearDue() { VoiceLists.shared.setDue(nil, ids: Set(selected.map(\.id)), in: listID) }
    @objc private func menuDelete() { confirmDelete(selected) }

    private func askDue(_ items: [ListItem]) {
        guard !items.isEmpty else { return }
        let a = NSAlert()
        a.messageText = items.count == 1 ? tr("Due date", "Срок задачи")
            : tr("Due date for \(items.count) tasks", "Срок для \(items.count) \(L10n.plural(items.count, en: ("task", "tasks"), ru: ("задачи", "задач", "задач")))")
        a.informativeText = items.count == 1 ? tr("“\(items[0].text.prefix(120))”", "«\(items[0].text.prefix(120))»") : ""
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.locale = L10n.locale
        picker.dateValue = items.compactMap(\.due).first ?? Date()
        picker.sizeToFit()
        a.accessoryView = picker
        a.addButton(withTitle: tr("Set Due Date", "Поставить срок"))
        a.addButton(withTitle: tr("Cancel", "Отмена"))
        let hasDue = items.contains { $0.due != nil }
        if hasDue { a.addButton(withTitle: tr("Clear Due Date", "Убрать срок")) }
        let r = a.runModal()
        let ids = Set(items.map(\.id))
        if r == .alertFirstButtonReturn { VoiceLists.shared.setDue(picker.dateValue, ids: ids, in: listID) }
        if hasDue && r == .alertThirdButtonReturn { VoiceLists.shared.setDue(nil, ids: ids, in: listID) }
    }

    private func confirmDelete(_ items: [ListItem]) {
        guard !items.isEmpty else { return }
        let a = NSAlert()
        let noun = Self.noun(items.count, kind: kind)
        a.messageText = items.count == 1 ? tr("Delete this \(noun)?", "Удалить \(noun)?") : tr("Delete \(items.count) \(noun)?", "Удалить \(items.count) \(noun)?")
        let undo = tr("This can’t be undone.", "Это нельзя отменить.")
        a.informativeText = items.count == 1 ? tr("“\(items[0].text.prefix(120))”", "«\(items[0].text.prefix(120))»") + "\n\n" + undo : undo
        a.addButton(withTitle: tr("Delete", "Удалить"))
        a.addButton(withTitle: tr("Cancel", "Отмена"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        checked.subtract(items.map(\.id))
        VoiceLists.shared.removeItems(Set(items.map(\.id)), from: listID)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CapsuleRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    private static let textFont = NSFont.systemFont(ofSize: 13)
    /// Top inset of the entry text in its cell.
    private static let textTop: CGFloat = 6
    /// Height of one line of entry text: controls in front of an entry are centred on it.
    /// Room between the row highlight capsule and the checkbox / day header.
    static let rowPad: CGFloat = 10
    static let firstLineHeight: CGFloat = {
        let probe = NSTextField(labelWithString: "Ag")
        probe.font = textFont
        return probe.fittingSize.height
    }()

    private func itemText(_ i: ListItem) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.paragraphSpacing = 2
        let done = kind == .tasks && i.status == .done
        var attrs: [NSAttributedString.Key: Any] = [.font: Self.textFont, .paragraphStyle: para,
                                                     .foregroundColor: done ? NSColor.secondaryLabelColor : NSColor.labelColor]
        if done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let s = NSMutableAttributedString(string: i.text, attributes: attrs)
        if kind == .tasks, let d = ListFilter.detail(i, now: Date()) {
            let color: NSColor = ListFilter.isOverdue(i, now: Date()) ? Brick.orangeText : .tertiaryLabelColor
            s.append(NSAttributedString(string: "\n" + d, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: para]))
        }
        return s
    }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = col?.identifier.rawValue
        if case .item(let i) = rows[row], id == "check" || id == "status" {
            let cell = NSView()
            let control: NSControl
            if id == "check" {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
                box.state = checked.contains(i.id) ? .on : .off
                box.setAccessibilityLabel(tr("Select", "Отметить"))
                control = box
            } else {
                let pill = CapsuleButton(i.status.title, style: i.status == .done ? .done : .glass,
                                         target: self, action: #selector(statusClicked(_:)))
                pill.height = 22
                pill.fontSize = 12
                pill.padding = 10
                pill.widthAnchor.constraint(equalToConstant: 78).isActive = true
                pill.setAccessibilityLabel(tr("Status: \(i.status.title)", "Статус: \(i.status.title)"))
                control = pill
            }
            control.tag = row
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: id == "check" ? Self.rowPad : 0),
                // The checkbox and the status capsule are centred on the first line of the entry text.
                control.centerYAnchor.constraint(equalTo: cell.topAnchor, constant: Self.textTop + Self.firstLineHeight / 2),
            ])
            return cell
        }
        let cell = NSTableCellView()
        let t = NSTextField(wrappingLabelWithString: "")
        t.translatesAutoresizingMaskIntoConstraints = false
        t.isSelectable = false
        cell.addSubview(t)
        cell.textField = t
        var top: CGFloat = Self.textTop
        var lead: CGFloat = 2
        switch rows[row] {
        case .day(let name):
            t.stringValue = name
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            t.textColor = .secondaryLabelColor
            top = 14
            lead = Self.rowPad + 2
        case .item(let i):
            if id == "time" {
                t.stringValue = ListFilter.stamp(i.date)
                t.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                t.textColor = .tertiaryLabelColor
                top = 7
            } else {
                t.attributedStringValue = itemText(i)
                t.isSelectable = true   // select part of the text with the mouse, ⌘C
            }
        }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: lead),
            t.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            t.topAnchor.constraint(equalTo: cell.topAnchor, constant: top),
            t.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .day: return 36
        case .item(let i):
            let w = max(100, (tableView.tableColumns.last?.width ?? 600) - 8)
            let r = itemText(i).boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return max(ceil(r.height) + 14, kind == .tasks ? 30 : 0)
        }
    }
}

extension ListPane: NSMenuDelegate {
    /// The right-click menu is rebuilt each time: task actions only in tasks lists, "Clear Due Date" only with a deadline.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = selected
        guard !items.isEmpty else { return }
        func add(_ title: String, _ sel: Selector) { menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        add(tr("Copy", "Скопировать"), #selector(copyClicked))
        if kind == .tasks {
            menu.addItem(.separator())
            if items.contains(where: { $0.status == .backlog }) { add("Done", #selector(menuDone)) }
            if items.contains(where: { $0.status == .done }) { add(tr("To Backlog", "В Backlog"), #selector(menuBacklog)) }
            add(tr("Due Date…", "Срок…"), #selector(menuDue))
            if items.contains(where: { $0.due != nil }) { add(tr("Clear Due Date", "Убрать срок"), #selector(menuClearDue)) }
        }
        menu.addItem(.separator())
        add(tr("Delete", "Удалить"), #selector(menuDelete))
    }
}

// MARK: - "New List" / "Edit List…" dialog

enum ListEditor {
    enum Result { case saved(VoiceList), deleted, cancelled }

    /// Asks for the name, command words and kind; validates and saves. `existing` nil creates a list.
    static func run(_ existing: VoiceList?) -> Result {
        let store = VoiceLists.shared
        let name = NSTextField(string: existing?.name ?? "")
        name.placeholderString = tr("For example, Ideas", "Например, Идеи")
        let words = NSTextField(string: existing?.keywords.joined(separator: ", ") ?? "")
        words.placeholderString = tr("For example, Idea, Thought", "Например, Идея, Мысль")
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: VoiceList.Kind.allCases.map(\.title))
        kind.selectItem(at: existing?.kind == .tasks ? 1 : 0)
        let note = NSTextField(wrappingLabelWithString: tr(
            "Say one of these words at the start of a phrase and the text goes to this list. Separate several words with commas. Words of 6 letters or more work even if one letter is misheard.",
            "Скажите одно из этих слов в начале фразы — текст попадёт в этот список. Несколько слов разделяйте запятой. Слова от 6 букв срабатывают, даже если распознались с ошибкой в одну букву."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("Name:", "Название:")), name],
            [NSTextField(labelWithString: tr("Command words:", "Слова-команды:")), words],
            [NSTextField(labelWithString: ""), note],
            [NSTextField(labelWithString: tr("Type:", "Тип:")), kind],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        for f in [name, words, note] { f.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 150)

        var error = ""
        while true {
            let a = NSAlert()
            a.messageText = existing == nil ? tr("New List", "Новый список") : tr("Edit “\(existing!.name)”", "Настроить «\(existing!.name)»")
            a.informativeText = error
            a.accessoryView = grid
            a.addButton(withTitle: existing == nil ? tr("Create", "Создать") : tr("Save", "Сохранить"))
            a.addButton(withTitle: tr("Cancel", "Отмена"))
            if existing != nil { a.addButton(withTitle: tr("Delete List…", "Удалить список…")) }
            a.window.initialFirstResponder = name
            let r = a.runModal()
            if r == .alertSecondButtonReturn { return .cancelled }
            if r == .alertThirdButtonReturn, let l = existing {
                return confirmDelete(l) ? .deleted : .cancelled
            }
            let n = name.stringValue.trimmingCharacters(in: .whitespaces)
            let k = VoiceLists.parseKeywords(words.stringValue)
            if let p = VoiceLists.problem(name: n, keywords: k, editing: existing?.id, among: store.lists) {
                error = p
                continue
            }
            let kd: VoiceList.Kind = kind.indexOfSelectedItem == 1 ? .tasks : .notes
            if var l = existing {
                l.name = n; l.keywords = k; l.kind = kd
                store.updateList(l)
                return .saved(l)
            }
            return .saved(store.addList(name: n, keywords: k, kind: kd))
        }
    }

    private static func confirmDelete(_ l: VoiceList) -> Bool {
        let n = VoiceLists.shared.items(l.id).count
        let a = NSAlert()
        let entries = L10n.plural(n, en: ("entry", "entries"), ru: ("запись", "записи", "записей"))
        a.messageText = tr("Delete the list “\(l.name)”?", "Удалить список «\(l.name)»?")
        a.informativeText = n == 0 ? tr("The list is empty.", "Список пуст.")
            : tr("Its \(n) \(entries) will be deleted too. This can’t be undone.", "Вместе с ним удалятся \(n) \(entries). Это нельзя отменить.")
        a.addButton(withTitle: tr("Delete", "Удалить"))
        a.addButton(withTitle: tr("Cancel", "Отмена"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        VoiceLists.shared.removeList(l.id)
        return true
    }
}
