import Cocoa

/// Lists can be archived (hidden, no longer catch dictation, entries kept) and restored; entries can be
/// typed in and edited, not only dictated.
enum ListArchiveTests {
    static func run() {
        T.test("lists: a done or due task is as tall as a plain one, so status capsules are evenly spaced") {
            let now = Date()
            let plain = ListItem(date: now, text: "Prepare the report.", lang: "en")
            let done = ListItem(date: now, text: "Prepare the report.", lang: "en", status: .done, doneAt: now)
            let due = ListItem(date: now, text: "Prepare the report.", lang: "en", due: now.addingTimeInterval(86400))
            let h = ListPane.rowHeight(plain, kind: .tasks, width: 700, now: now)
            T.eq(ListPane.rowHeight(done, kind: .tasks, width: 700, now: now), h, "done")
            T.eq(ListPane.rowHeight(due, kind: .tasks, width: 700, now: now), h, "due")
            let text = ListPane.itemText(done, kind: .tasks, now: now).string
            T.ok(!text.contains("\n") && text.hasPrefix("Prepare the report.") && text.contains(ListFilter.stamp(now)), text)
        }
        T.test("lists: an archived list leaves the sidebar and stops catching dictation, entries kept") {
            let store = VoiceLists.shared
            let l = store.addList(name: "Archive me", keywords: ["Архивка"], kind: .notes)
            defer { store.removeList(l.id) }
            store.addItem(to: l.id, text: "Keep me.", lang: "en")
            T.ok(store.match("Архивка: проверка") != nil, "matches while active")
            store.archive(l.id)
            T.ok(store.list(l.id)?.isArchived == true, "archived")
            T.ok(!store.active.contains { $0.id == l.id } && store.archived.contains { $0.id == l.id }, "moved to the archive")
            T.ok(store.match("Архивка: проверка") == nil, "no longer catches dictation")
            T.eq(store.items(l.id).map(\.text), ["Keep me."], "entries kept")
            let items = MainWindow.sidebarItems(store.lists)
            T.ok(!items.contains(.list(l.id)), "not in the sidebar")
            T.ok(items.contains(.archive), "an Archive row appears")
            T.eq(store.restore(l.id), [])
            T.ok(store.active.contains { $0.id == l.id }, "restored")
            T.ok(store.match("Архивка: проверка") != nil, "catches dictation again")
        }
        T.test("lists: restoring drops command words another list took meanwhile") {
            let store = VoiceLists.shared
            let a = store.addList(name: "Old ideas", keywords: ["Задумка", "Мысль"], kind: .notes)
            defer { store.removeList(a.id) }
            store.archive(a.id)
            T.ok(VoiceLists.problem(name: "New ideas", keywords: ["Задумка"], editing: nil, among: store.active) == nil,
                 "an archived list's words are free")
            let b = store.addList(name: "New ideas", keywords: ["Задумка"], kind: .notes)
            defer { store.removeList(b.id) }
            T.eq(store.restore(a.id), ["Задумка"])
            T.eq(store.list(a.id)?.keywords, ["Мысль"])
            T.ok(!MainWindow.sidebarItems(store.lists).contains(.archive), "no Archive row when nothing is archived")
        }
        T.test("lists: an entry's text can be edited; empty text is ignored") {
            let store = VoiceLists.shared
            let l = store.addList(name: "Edit me", keywords: ["Правка"], kind: .tasks)
            defer { store.removeList(l.id) }
            let item = store.addItem(to: l.id, text: "Draft", lang: "en")
            store.setText("  Final text.  ", id: item.id, in: l.id)
            T.eq(store.items(l.id).first?.text, "Final text.")
            store.setText("   ", id: item.id, in: l.id)
            T.eq(store.items(l.id).first?.text, "Final text.")
            T.eq(store.items(l.id).first?.date, item.date, "keeps its date")
        }
        T.test("lists: typing an entry adds it on top, as Backlog in tasks") {
            let store = VoiceLists.shared
            let l = store.addList(name: "Typed", keywords: ["Набор"], kind: .tasks)
            defer { store.removeList(l.id) }
            store.addItem(to: l.id, text: "Dictated", lang: "ru")
            let pane = ListPane(listID: l.id)
            pane.reload()
            pane.addTyped("  Typed task \n")
            pane.addTyped("   ")
            T.eq(store.items(l.id).map(\.text), ["Typed task", "Dictated"])
            T.eq(store.items(l.id).first?.status, .backlog)
            T.eq(ListPane.composerPlaceholder(.tasks), tr("New task — type and press Enter", "Новая задача — введите и нажмите Enter"))
        }
    }
}
