import Cocoa

/// Aggregates over dictation history for the dashboard.
struct DictationStats {
    static let typingWPM = 40.0   // average keyboard speed used for "time saved"

    var dictations = 0
    var words = 0
    var chars = 0
    var seconds = 0.0
    var apps: [(name: String, words: Int)] = []
    var langs: [(code: String, words: Int)] = []

    var wpm: Double { seconds > 0 ? Double(words) / (seconds / 60) : 0 }
    var savedSeconds: Double { max(0, Double(words) / Self.typingWPM * 60 - seconds) }

    static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    init(_ entries: [HistoryEntry]) {
        var byApp: [String: Int] = [:], byLang: [String: Int] = [:]
        for e in entries {
            let w = Self.wordCount(e.text)
            dictations += 1
            words += w
            chars += e.text.count
            seconds += e.seconds
            byApp[e.app ?? "—", default: 0] += w
            byLang[e.lang, default: 0] += w
        }
        apps = byApp.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        langs = byLang.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Words per calendar day for the last `days` days, oldest first.
    static func daily(_ entries: [HistoryEntry], days: Int, now: Date = Date()) -> [(day: Date, words: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var buckets: [Date: Int] = [:]
        for e in entries { buckets[cal.startOfDay(for: e.date), default: 0] += wordCount(e.text) }
        return (0..<days).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.map { ($0, buckets[$0] ?? 0) }
    }

    /// Consecutive days with at least one dictation, ending today (or yesterday if nothing yet today).
    static func streak(_ entries: [HistoryEntry], now: Date = Date()) -> Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.date) })
        var d = cal.startOfDay(for: now)
        if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        var n = 0
        while days.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return n
    }
}

// MARK: - Window

final class StatsPane: NSObject {
    enum Period: Int, CaseIterable {
        case today, week, month, all
        var title: String { ["Сегодня", "7 дней", "30 дней", "Всё время"][rawValue] }
        func includes(_ d: Date, now: Date) -> Bool {
            let cal = Calendar.current
            switch self {
            case .today: return cal.isDate(d, inSameDayAs: now)
            case .week: return d >= cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
            case .month: return d >= cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!
            case .all: return true
            }
        }
    }

    private(set) lazy var view: NSView = build()
    private let periodControl = NSSegmentedControl(labels: Period.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private var cards: [StatCard] = []
    private let chart = BarChartView()
    private let chartTitle = NSTextField(labelWithString: "")
    private let appsList = NSStackView()
    private let langsList = NSStackView()
    private let streakLabel = NSTextField(labelWithString: "")

    private func build() -> NSView {
        periodControl.selectedSegment = UserDefaults.standard.object(forKey: "statsPeriod") as? Int ?? Period.week.rawValue
        periodControl.target = self
        periodControl.action = #selector(periodChanged)
        let top = NSStackView(views: [periodControl, NSView()])

        cards = ["Слов", "Символов", "Диктовок", "Время речи", "Скорость", "Сэкономлено"].map { StatCard(title: $0) }
        let grid = NSGridView(views: [Array(cards[0..<3]), Array(cards[3..<6])])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        for c in cards { c.widthAnchor.constraint(equalTo: cards[0].widthAnchor).isActive = true }

        chartTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        chartTitle.textColor = .secondaryLabelColor
        chart.heightAnchor.constraint(equalToConstant: 150).isActive = true

        for s in [appsList, langsList] { s.orientation = .vertical; s.alignment = .leading; s.spacing = 6 }
        streakLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let left = section("Где диктуешь", appsList)
        let right = section("Языки", langsList, extra: streakLabel)
        let bottom = NSStackView(views: [left, right])
        bottom.distribution = .fillEqually
        bottom.alignment = .top
        bottom.spacing = 24

        let foot = NSTextField(wrappingLabelWithString: "«Сэкономлено» — сколько времени заняло бы набрать эти слова на клавиатуре (\(Int(DictationStats.typingWPM)) слов/мин) минус время самой диктовки. Всё считается локально по истории диктовок.")
        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .tertiaryLabelColor
        foot.preferredMaxLayoutWidth = 700

        let stack = NSStackView(views: [top, grid, chartTitle, chart, bottom, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(4, after: chartTitle)
        stack.setCustomSpacing(18, after: chart)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        for v in [top, grid, chart, bottom, foot] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        return root
    }

    private func section(_ title: String, _ body: NSView, extra: NSView? = nil) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12, weight: .semibold)
        t.textColor = .secondaryLabelColor
        let s = NSStackView(views: [t, body] + (extra.map { [$0] } ?? []))
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        if extra != nil { s.setCustomSpacing(14, after: body) }
        return s
    }

    @objc private func periodChanged() {
        UserDefaults.standard.set(periodControl.selectedSegment, forKey: "statsPeriod")
        reload()
    }

    func reload() {
        _ = view
        let now = Date()
        let all = History.shared.entries
        let period = Period(rawValue: periodControl.selectedSegment) ?? .week
        let st = DictationStats(all.filter { period.includes($0.date, now: now) })

        let values = [
            Self.num(st.words), Self.num(st.chars), Self.num(st.dictations),
            Self.duration(st.seconds), st.words > 0 ? "\(Int(st.wpm.rounded())) слов/мин" : "—", Self.duration(st.savedSeconds),
        ]
        for (c, v) in zip(cards, values) { c.value = v }
        cards[5].accent = true

        let days = period == .month || period == .all ? 30 : 14
        chartTitle.stringValue = "СЛОВ ПО ДНЯМ — ПОСЛЕДНИЕ \(days) ДНЕЙ"
        chart.data = DictationStats.daily(all, days: days, now: now)

        fill(appsList, st.apps.prefix(6).map { ($0.name, $0.words) }, total: st.words)
        let langName = ["ru": "Русский", "en": "Английский"]
        fill(langsList, st.langs.map { (langName[$0.code] ?? $0.code, $0.words) }, total: st.words)

        let streak = DictationStats.streak(all, now: now)
        streakLabel.stringValue = streak > 0 ? "🔥 \(streak) \(Self.plural(streak, "день", "дня", "дней")) подряд с диктовкой" : ""
    }

    private func fill(_ list: NSStackView, _ rows: [(String, Int)], total: Int) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if rows.isEmpty {
            let e = NSTextField(labelWithString: "Нет данных за период")
            e.textColor = .tertiaryLabelColor
            list.addArrangedSubview(e)
            return
        }
        for (name, words) in rows {
            let row = ShareRow(name: name, detail: "\(Self.num(words)) сл.", share: total > 0 ? Double(words) / Double(total) : 0)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    // MARK: formatting

    private static let numFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "ru_RU"); return f
    }()
    static func num(_ n: Int) -> String { numFmt.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) с" }
        let m = t / 60
        if m < 60 { return "\(m) мин" }
        return "\(m / 60) ч \(m % 60) мин"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }
}

// MARK: - Views

final class StatCard: NSView {
    private let valueLabel = NSTextField(labelWithString: "—")
    var value: String { get { valueLabel.stringValue } set { valueLabel.stringValue = newValue } }
    var accent = false { didSet { valueLabel.textColor = accent ? .systemOrange : .labelColor } }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        let t = NSTextField(labelWithString: title.uppercased())
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .secondaryLabelColor
        valueLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        let s = NSStackView(views: [t, valueLabel])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor }
    override var wantsUpdateLayer: Bool { true }
}

/// "Name ········ 1 234 сл." with a thin proportional bar underneath.
private final class ShareRow: NSView {
    private let share: Double
    init(name: String, detail: String, share: Double) {
        self.share = share
        super.init(frame: .zero)
        let n = NSTextField(labelWithString: name)
        n.lineBreakMode = .byTruncatingTail
        n.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let d = NSTextField(labelWithString: "\(detail)  \(Int((share * 100).rounded()))%")
        d.textColor = .secondaryLabelColor
        d.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let s = NSStackView(views: [n, NSView(), d])
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let track = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        var fill = track
        fill.size.width = max(3, bounds.width * share)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

private final class BarChartView: NSView {
    var data: [(day: Date, words: Int)] = [] { didSet { needsDisplay = true } }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM"; return f
    }()

    override func draw(_ dirty: NSRect) {
        guard !data.isEmpty else { return }
        let labelH: CGFloat = 16, topPad: CGFloat = 16
        let plotH = bounds.height - labelH - topPad
        let maxV = max(1, data.map(\.words).max() ?? 1)
        let gap: CGFloat = data.count > 20 ? 3 : 6
        let barW = (bounds.width - gap * CGFloat(data.count - 1)) / CGFloat(data.count)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let cal = Calendar.current
        let labelEvery = data.count > 20 ? 5 : 2

        for (i, d) in data.enumerated() {
            let x = CGFloat(i) * (barW + gap)
            let h = d.words == 0 ? 2 : max(4, plotH * CGFloat(d.words) / CGFloat(maxV))
            let r = NSRect(x: x, y: labelH, width: barW, height: h)
            let isToday = cal.isDateInToday(d.day)
            (d.words == 0 ? NSColor.quaternaryLabelColor : isToday ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: r, xRadius: min(3, barW / 2), yRadius: min(3, barW / 2)).fill()

            if d.words == maxV && d.words > 0 {
                let s = NSAttributedString(string: StatsPane.num(d.words), attributes: small)
                s.draw(at: NSPoint(x: min(x + barW / 2 - s.size().width / 2, bounds.width - s.size().width), y: labelH + h + 2))
            }
            let fromEnd = data.count - 1 - i
            if fromEnd % labelEvery == 0 {
                let s = NSAttributedString(string: isToday ? "сегодня" : Self.dayFmt.string(from: d.day), attributes: small)
                let lx = min(max(0, x + barW / 2 - s.size().width / 2), bounds.width - s.size().width)
                s.draw(at: NSPoint(x: lx, y: 0))
            }
        }
    }
}
