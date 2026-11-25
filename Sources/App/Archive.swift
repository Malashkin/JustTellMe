import Cocoa

/// The Archive page: lists moved out of the sidebar. Each can be opened, restored or deleted.
final class ArchivePane: NSObject {
    private(set) lazy var view: NSView = build()
    var onOpen: ((UUID) -> Void)?
    private let rows = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: tr("The archive is empty.", "Архив пуст."))

    /// For tests: the names shown.
    var names: [String] { rows.arrangedSubviews.compactMap { $0.identifier?.rawValue } }

    static func summary(_ l: VoiceList, entries: Int) -> String {
        let kind = l.kind == .tasks ? tr("Tasks", "Задачи") : tr("Notes", "Заметки")
        let count = "\(entries) " + L10n.plural(entries, en: ("entry", "entries"), ru: ("запись", "записи", "записей"))
        let words = l.keywords.isEmpty ? tr("no command words", "без слов-команд") : l.keywords.joined(separator: ", ")
        let date = l.archivedAt.map { ListFilter.dayTitle(Calendar.current.startOfDay(for: $0)) } ?? ""
        return [kind, count, words, tr("archived \(date)", "в архиве с \(date)")].joined(separator: " · ")
    }

    func reload() {
        _ = view
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let store = VoiceLists.shared
        for l in store.archived {
            let r = row(l, entries: store.items(l.id).count)
            rows.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        empty.isHidden = !store.archived.isEmpty
    }

    private func row(_ l: VoiceList, entries: Int) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: l.kind == .tasks ? "checklist" : "note.text", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: l.name)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        let info = NSTextField(labelWithString: Self.summary(l, entries: entries))
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [name, info])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = CapsuleButton(tr("Open", "Открыть"), style: .glass, target: self, action: #selector(openAction(_:)))
        let restore = CapsuleButton(tr("Restore", "Вернуть"), style: .prominent, target: self, action: #selector(restoreAction(_:)))
        let delete = CapsuleButton(tr("Delete…", "Удалить…"), style: .destructive, target: self, action: #selector(deleteAction(_:)))
        for b in [open, restore, delete] { b.identifier = .init(l.id.uuidString) }
        let line = NSStackView(views: [icon, text, NSView(), open, restore, delete])
        line.spacing = 10
        line.setCustomSpacing(16, after: text)
        let card = GlassView(radius: 18)
        line.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(line)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 62),
            line.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        card.identifier = .init(l.name)
        return card
    }

    private func id(_ b: NSButton) -> UUID? { b.identifier.flatMap { UUID(uuidString: $0.rawValue) } }

    @objc private func openAction(_ b: NSButton) { id(b).map { onOpen?($0) } }

    @objc private func restoreAction(_ b: NSButton) {
        guard let id = id(b) else { return }
        let dropped = VoiceLists.shared.restore(id)
        guard !dropped.isEmpty, let l = VoiceLists.shared.list(id) else { return }
        let a = NSAlert()
        a.messageText = tr("“\(l.name)” is back", "Список «\(l.name)» возвращён")
        let words = dropped.map { tr("“\($0)”", "«\($0)»") }.joined(separator: ", ")
        a.informativeText = tr("Another list now uses \(words), so it was removed from this one. Give it new words in “Edit List…”.",
                               "Слова \(words) теперь у другого списка, поэтому из этого они убраны. Задайте новые слова в «Настроить…».")
        a.runModal()
    }

    @objc private func deleteAction(_ b: NSButton) {
        guard let id = id(b), let l = VoiceLists.shared.list(id) else { return }
        _ = ListEditor.confirmDelete(l)
    }

    private func build() -> NSView {
        let title = NSTextField(labelWithString: tr("Archive", "Архив"))
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let hint = NSTextField(wrappingLabelWithString: tr(
            "Lists you no longer use. They are hidden from the sidebar and their command words don’t work; the entries are kept.",
            "Списки, которыми вы больше не пользуетесь. Их нет в боковой панели и их слова-команды не работают; записи сохранены."))
        hint.textColor = .secondaryLabelColor
        empty.textColor = .secondaryLabelColor
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        let stack = NSStackView(views: [title, hint, rows, empty])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: hint)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 16, right: 24)
        for v in [hint, rows] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return root
    }
}
