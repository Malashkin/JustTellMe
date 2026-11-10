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
    }
}
