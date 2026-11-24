import Cocoa

/// Version 1.1: idle unload by default, lighter recording pill, ⌃⌥V paste-again, the
/// "no text field" card, updates from GitHub Releases. Pure logic only; the binary-level
/// checks are in IntegrationTests.
enum FeatureTests {
    static func run() {
        unloadDefault()
        pasteAgain()
        focusedField()
        updateVersions()
        releaseParsing()
        waveform()
        doubleTap()
        voiceNotes()
    }

    // MARK: Voice lists: a command word at the start saves the phrase to a list instead of pasting

    static func voiceNotes() {
        let defaults = VoiceLists.defaultLists()
        /// The text saved to the notes list, or nil when the phrase is not a note.
        func note(_ s: String) -> String? {
            guard let m = VoiceLists.match(s, in: defaults), m.list.name == "Заметки" else { return nil }
            return m.body
        }
        func task(_ s: String) -> String? {
            guard let m = VoiceLists.match(s, in: defaults), m.list.name == "Задачи" else { return nil }
            return m.body
        }
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        func day(_ offset: Int, hour: Int = 10) -> Date {
            cal.date(byAdding: .day, value: offset, to: cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: hour))!)!
        }

        T.test("notes: a dictation starting with «Заметка» becomes a note without the keyword") {
            T.eq(note("Заметка купить молоко."), "Купить молоко.")
            T.eq(note("Заметка, позвонить в банк"), "Позвонить в банк")
            T.eq(note("Заметка: созвон в 15:00."), "Созвон в 15:00.")
            T.eq(note("Заметка. Забрать посылку."), "Забрать посылку.")
            T.eq(note("  заметка — идея для статьи"), "Идея для статьи")
            T.eq(note("ЗАМЕТКА deploy в пятницу"), "Deploy в пятницу")
        }
        T.test("notes: only the keyword at the very start counts, as a whole word") {
            T.eq(note("Это заметка про отпуск."), nil)
            T.eq(note("Заметками займусь завтра."), nil)
            T.eq(note("Заметкам нужен поиск"), nil)
            T.eq(note("Купить молоко"), nil)
            T.eq(note(""), nil)
        }
        T.test("notes: a slightly misheard keyword still makes a note (one letter off, or split in two)") {
            T.eq(note("Замевка купить молоко."), "Купить молоко.")
            T.eq(note("Заметко, позвонить в банк"), "Позвонить в банк")
            T.eq(note("Саметка: созвон в 15:00."), "Созвон в 15:00.")
            T.eq(note("Заметька. Идея для статьи"), "Идея для статьи")
            T.eq(note("Замтка забрать посылку"), "Забрать посылку")
            T.eq(note("Заметку купить хлеб"), "Купить хлеб")
            T.eq(note("За метка, купить сыр"), "Купить сыр")
            T.eq(note("За мефка купить молоко."), "Купить молоко.", "real whisper output for a TTS «Замевка»")
        }
        T.test("notes: ordinary words that only look like the keyword are pasted as usual") {
            for s in ["Заметна разница в скорости.", "Заметно быстрее стало.", "Заметил ошибку в отчёте.", "Замечательно, договорились.",
                      "Монетка упала.", "За меткой следи.", "За", "Заметках этого нет.", "Зачётка осталась дома.", "Намётка плана готова."] {
                T.eq(VoiceLists.match(s, in: defaults)?.body, nil, s)
            }
        }
        T.test("notes: the keyword alone gives an empty entry, which is not pasted either") {
            T.eq(note("Заметка."), "")
            T.eq(note("Заметка"), "")
        }
        T.test("tasks: «Задача …» goes to Задачи, also slightly misheard; lookalikes are pasted") {
            T.eq(task("Задача, позвонить в банк до пятницы."), "Позвонить в банк до пятницы.")
            T.eq(task("Задачу: обновить отчёт"), "Обновить отчёт")
            T.eq(task("Зодача купить билеты"), "Купить билеты")
            T.eq(task("За дача, полить цветы"), "Полить цветы")
            T.eq(VoiceLists.match("Задачам нужен приоритет.", in: defaults)?.body, nil)
            T.eq(VoiceLists.match("Задачах это есть.", in: defaults)?.body, nil)
            T.eq(VoiceLists.match("Удача на нашей стороне.", in: defaults)?.body, nil)
        }
        T.test("lists: own command words, several per list; short words must be heard exactly") {
            let ideas = VoiceList(id: UUID(), name: "Идеи", keywords: ["Идея", "Мысль"], kind: .notes)
            let all = defaults + [ideas]
            T.eq(VoiceLists.match("Идея: голосовые списки", in: all)?.list.name, "Идеи")
            T.eq(VoiceLists.match("Идея: голосовые списки", in: all)?.body, "Голосовые списки")
            T.eq(VoiceLists.match("мысль. Позвонить маме", in: all)?.body, "Позвонить маме")
            T.eq(VoiceLists.match("Идеи у нас есть.", in: all)?.body, nil, "4 letters: no near misses")
            T.eq(VoiceLists.match("Заметка про идею", in: all)?.list.name, "Заметки", "built-in words keep working")
        }
        T.test("lists: a word heard exactly beats a near miss of another list; otherwise the first list wins") {
            let odd = VoiceList(id: UUID(), name: "Странный", keywords: ["Замевка"], kind: .notes)
            T.eq(VoiceLists.match("Замевка: текст", in: defaults + [odd])?.list.name, "Странный")
            T.eq(VoiceLists.match("Заметка: текст", in: defaults + [odd])?.list.name, "Заметки")
        }
        T.test("lists: command words typed with commas, checked before saving") {
            T.eq(VoiceLists.parseKeywords(" Идея, Мысль; идея\nNote, "), ["Идея", "Мысль", "Note"])
            T.eq(VoiceLists.problem(name: "Идеи", keywords: ["Идея"], editing: nil, among: defaults), nil)
            T.ok(VoiceLists.problem(name: " ", keywords: ["Идея"], editing: nil, among: defaults) != nil, "a name is needed")
            T.ok(VoiceLists.problem(name: "Идеи", keywords: [], editing: nil, among: defaults) != nil, "a word is needed")
            T.ok(VoiceLists.problem(name: "Идеи", keywords: ["список покупок"], editing: nil, among: defaults)?.contains("одним словом") == true, "one word per command")
            T.ok(VoiceLists.problem(name: "Идеи", keywords: ["заметка"], editing: nil, among: defaults)?.contains("Заметки") == true, "a word of another list")
            T.eq(VoiceLists.problem(name: "Заметки", keywords: ["Заметка", "Запись"], editing: defaults[0].id, among: defaults), nil, "a list may keep its own words")
        }
        T.test("lists: first run creates Заметки and Задачи and moves notes from notes.json") {
            let fm = FileManager.default
            try? fm.removeItem(at: Paths.support.appendingPathComponent("lists.json"))
            let legacy = #"[{"id":"\#(UUID().uuidString)","date":"2026-11-22T10:00:00Z","text":"Старая заметка","lang":"ru"}]"#
            try legacy.write(to: Paths.support.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
            let store = VoiceLists.shared
            store.load()
            T.eq(store.lists.map(\.name), ["Заметки", "Задачи"])
            T.eq(store.lists.map(\.kind), [.notes, .tasks])
            T.eq(store.items(store.lists[0].id).map(\.text), ["Старая заметка"])
            T.eq(store.items(store.lists[0].id).first?.status, .backlog, "older entries read without the task fields")
            store.load()
            T.eq(store.items(store.lists[0].id).count, 1, "moved once, not again on the next start")
        }
        T.test("lists: entries saved newest first, survive a reload, deleted exactly") {
            let store = VoiceLists.shared
            let id = store.lists[0].id
            let before = store.items(id).count
            store.addItem(to: id, text: "Купить молоко", lang: "ru", date: Date(timeIntervalSinceNow: -60))
            let keep = store.addItem(to: id, text: "Позвонить в Банк", lang: "ru")
            let a = store.addItem(to: id, text: "Удалить", lang: "ru")
            store.load()
            T.eq(store.items(id).count, before + 3)
            T.eq(store.items(id).first?.text, "Удалить", "newest first")
            T.eq(ListFilter.apply(store.items(id), kind: .notes, query: " банк ").map(\.text), ["Позвонить в Банк"])
            store.removeItems([a.id], from: id)
            store.load()
            T.ok(!store.items(id).contains { $0.id == a.id } && store.items(id).contains { $0.id == keep.id }, "only the chosen entry is gone")
            var changed = false
            store.onChange = { _ in changed = true }
            defer { store.onChange = nil }
            store.removeItems([UUID()], from: id)
            T.ok(!changed, "nothing to delete, nothing rewritten")
        }
        T.test("lists: create, rename, change words, delete a list with its entries") {
            let store = VoiceLists.shared
            var l = store.addList(name: "Идеи", keywords: ["Идея"], kind: .notes)
            store.addItem(to: l.id, text: "Голосовые списки", lang: "ru")
            l.name = "Мысли"; l.keywords = ["Мысль", "Идея"]; l.kind = .tasks
            store.updateList(l)
            store.load()
            T.eq(store.list(l.id)?.name, "Мысли")
            T.eq(store.list(l.id)?.keywords, ["Мысль", "Идея"])
            T.eq(store.list(l.id)?.kind, .tasks)
            T.eq(store.match("Мысль: проверить")?.list.id, l.id)
            let file = Paths.support.appendingPathComponent("list-\(l.id.uuidString).json")
            T.ok(FileManager.default.fileExists(atPath: file.path), "entries in their own file")
            store.removeList(l.id)
            store.load()
            T.eq(store.list(l.id), nil)
            T.ok(!FileManager.default.fileExists(atPath: file.path), "entries deleted with the list")
            T.eq(store.match("Мысль: проверить")?.list.id, nil, "its words no longer catch anything")
        }
        T.test("tasks: Done remembers when, back to Backlog forgets; a deadline is a day") {
            let store = VoiceLists.shared
            let id = store.lists[1].id
            let t = store.addItem(to: id, text: "Отправить отчёт", lang: "ru")
            T.eq(t.status, .backlog, "a new task is in Backlog")
            store.setStatus(.done, ids: [t.id], in: id, now: now)
            store.load()
            T.eq(store.items(id).first { $0.id == t.id }?.status, .done)
            T.eq(store.items(id).first { $0.id == t.id }?.doneAt, now)
            store.setStatus(.backlog, ids: [t.id], in: id, now: now)
            T.eq(store.items(id).first { $0.id == t.id }?.doneAt, nil)
            store.setDue(day(2, hour: 17), ids: [t.id], in: id)
            store.load()
            T.eq(store.items(id).first { $0.id == t.id }?.due, cal.startOfDay(for: day(2)))
            store.setDue(nil, ids: [t.id], in: id)
            T.eq(store.items(id).first { $0.id == t.id }?.due, nil)
        }
        T.test("tasks: filter by status, by created/due/done date over a period, and by a custom range") {
            let old = ListItem(date: day(-10), text: "Старая", lang: "ru")
            let today = ListItem(date: day(0), text: "Сегодняшняя", lang: "ru", due: cal.startOfDay(for: day(3)))
            let overdue = ListItem(date: day(-5), text: "Просроченная", lang: "ru", due: cal.startOfDay(for: day(-1)))
            let done = ListItem(date: day(-40), text: "Сделанная", lang: "ru", status: .done, doneAt: day(-1), due: cal.startOfDay(for: day(-2)))
            let all = [old, today, overdue, done]
            func f(_ st: ListFilter.Status = .all, _ field: ListFilter.DateField = .created, _ p: ListFilter.Period = .all, _ q: String = "") -> [String] {
                ListFilter.apply(all, kind: .tasks, query: q, status: st, field: field, period: p, now: now).map(\.text)
            }
            T.eq(f(.backlog), ["Старая", "Сегодняшняя", "Просроченная"])
            T.eq(f(.done), ["Сделанная"])
            T.eq(f(.all, .created, .today), ["Сегодняшняя"])
            T.eq(f(.all, .created, .week), ["Сегодняшняя", "Просроченная"])
            T.eq(f(.all, .created, .month), ["Старая", "Сегодняшняя", "Просроченная"])
            T.eq(f(.all, .due, .today), ["Просроченная"], "overdue in Backlog always counts; a done task does not")
            T.eq(f(.all, .due, .week), ["Сегодняшняя", "Просроченная"], "due within the next 7 days")
            T.eq(f(.all, .done, .week), ["Сделанная"])
            T.eq(f(.all, .done, .all).count, 4, "all dates: tasks without that date stay")
            T.eq(f(.all, .created, .custom(day(-5), day(-10))), ["Старая", "Просроченная"], "both end days count, in any order")
            T.eq(f(.all, .created, .all, "сделан"), ["Сделанная"])
            T.eq(ListFilter.apply(all, kind: .notes, query: "", status: .done, field: .due, period: .today, now: now).count, 4, "notes lists ignore task filters")
        }
        T.test("tasks: grouped by the chosen date; deadlines soonest first, undated last") {
            let a = ListItem(date: day(-1), text: "A", lang: "ru", due: cal.startOfDay(for: day(1)))
            let b = ListItem(date: day(0), text: "B", lang: "ru")
            let c = ListItem(date: day(-3), text: "C", lang: "ru", due: cal.startOfDay(for: day(0)))
            let byCreated = ListFilter.groups([a, b, c], field: .created, now: now)
            T.eq(byCreated.map(\.title), ["Сегодня, 23 ноября", "Вчера, 22 ноября", "20 ноября 2026, пятница"])
            let byDue = ListFilter.groups([a, b, c], field: .due, now: now)
            T.eq(byDue.map(\.title), ["Сегодня, 23 ноября", "Завтра, 24 ноября", "Без срока"])
            T.eq(byDue.flatMap(\.items).map(\.text), ["C", "A", "B"])
            T.eq(ListFilter.groups([b], field: .done, now: now).map(\.title), ["Не сделаны"])
        }
        T.test("tasks: the line under a task shows the deadline, overdue, and when it was done") {
            let late = ListItem(date: day(-5), text: "x", lang: "ru", due: cal.startOfDay(for: day(-1)))
            T.ok(ListFilter.isOverdue(late, now: now), "past deadline in Backlog")
            T.ok(ListFilter.detail(late, now: now)?.hasSuffix("— просрочено") == true, ListFilter.detail(late, now: now) ?? "nil")
            var done = late; done.status = .done; done.doneAt = day(0, hour: 9)
            T.ok(!ListFilter.isOverdue(done, now: now), "done is never overdue")
            T.ok(ListFilter.detail(done, now: now)?.contains("Сделано: 23 ") == true, ListFilter.detail(done, now: now) ?? "nil")
            T.eq(ListFilter.detail(ListItem(date: now, text: "x", lang: "ru"), now: now), nil)
        }
        T.test("lists: every header and every entry shows the date") {
            T.eq(ListFilter.dayTitle(now, now: now), "Сегодня, 23 ноября")
            T.eq(ListFilter.dayTitle(day(-1), now: now), "Вчера, 22 ноября")
            T.eq(ListFilter.dayTitle(day(1), now: now), "Завтра, 24 ноября")
            T.eq(ListFilter.dayTitle(day(-3), now: now), "20 ноября 2026, пятница")
            let s = ListFilter.stamp(cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9, minute: 5))!)
            T.ok(s.hasPrefix("23 ") && s.hasSuffix(", 09:05"), "date and time on the entry, got \(s)")
        }
        T.test("lists: tick several entries and act on them at once") {
            let a = ListItem(date: now, text: "Первая", lang: "ru")
            let b = ListItem(date: now, text: "Вторая", lang: "ru")
            let c = ListItem(date: now, text: "Третья", lang: "ru")
            let shown = [a, b, c]
            T.eq(ListPane.targets(checked: [a.id, c.id], highlighted: [b], shown: shown), [a, c], "ticks win over the highlight")
            T.eq(ListPane.targets(checked: [], highlighted: [b], shown: shown), [b], "no ticks: the highlighted entries")
            T.eq(ListPane.toggleAll([], shown: shown), Set([a.id, b.id, c.id]), "«Отметить все» ticks every visible entry")
            T.eq(ListPane.toggleAll([a.id], shown: shown), Set([a.id, b.id, c.id]), "some ticked: tick the rest")
            T.eq(ListPane.toggleAll([a.id, b.id, c.id], shown: shown), [], "all ticked: «Снять отметки» clears")
            T.eq(ListPane.toggleAll([], shown: []), [], "nothing to tick")
            T.eq(ListPane.visibleChecks([a.id, c.id], shown: [a, b]), [a.id], "a ticked entry hidden by a filter is not touched")
            T.eq(ListPane.deleteTitle(0, kind: .notes), "Удалить")
            T.eq(ListPane.deleteTitle(1, kind: .notes), "Удалить 1 запись")
            T.eq(ListPane.deleteTitle(3, kind: .tasks), "Удалить 3 задачи")
            T.eq(ListPane.deleteTitle(5, kind: .tasks), "Удалить 5 задач")
            T.ok(ListPane.keywordHint(VoiceList(id: UUID(), name: "Идеи", keywords: ["Идея", "Мысль"], kind: .notes)).contains("«Идея», «Мысль»"), "the page says its words")
        }
        T.test("feed and lists: text can be selected with the mouse, ⌘C copies the selected rows") {
            let table = SelectableTextTableView()
            let text = NSTextField(wrappingLabelWithString: "Купить молоко")
            text.isSelectable = true
            T.ok(table.validateProposedFirstResponder(text, for: nil), "a click on selectable text goes to the text, not the row")
            let time = NSTextField(labelWithString: "10:04")
            time.isSelectable = false
            T.ok(!time.acceptsFirstResponder, "the time label cannot take the click, so it still selects the row")
            var copied = 0
            table.onCopy = { copied += 1 }
            table.copy(nil)
            T.eq(copied, 1, "⌘C with no text selected copies the rows")
            T.eq(ListPane.copyText([ListItem(date: now, text: "Первая", lang: "ru"), ListItem(date: now, text: "Вторая", lang: "ru")]), "Первая\nВторая")
        }
        T.test("lists: the sidebar shows Главная, the lists in order, «Новый список», then the other pages") {
            let items = MainWindow.sidebarItems(defaults)
            T.eq(items, [.page(.home), .list(defaults[0].id), .list(defaults[1].id), .addList, .page(.stats), .page(.vocabulary), .page(.settings)])
        }
    }

    // MARK: Double tap for hands-free (like Wispr Flow)

    static func doubleTap() {
        T.test("key: by default a double tap starts hands-free dictation, holding is push-to-talk") {
            let d = UserDefaults.standard
            let saved = d.object(forKey: "trigger")
            defer { d.set(saved, forKey: "trigger") }
            d.removeObject(forKey: "trigger")
            T.eq(Prefs.trigger, .holdOrDoubleTap)
            T.eq(KeyRelease.classify(held: 0.12, trigger: Prefs.trigger), .awaitSecondTap, "first short press waits for the second")
            T.eq(KeyRelease.classify(held: 1.5, trigger: Prefs.trigger), .finish, "holding still works as before")
        }
        T.test("key: a single short tap means what the chosen mode says") {
            T.eq(KeyRelease.classify(held: 0.1, trigger: .holdOrTap), .lockHandsFree)
            T.eq(KeyRelease.classify(held: 0.1, trigger: .holdOnly), .cancel, "hold-only: a tap is a stray touch")
        }
        T.test("key: an explicit choice of the old single-tap mode is kept") {
            let d = UserDefaults.standard
            let saved = d.object(forKey: "trigger")
            defer { d.set(saved, forKey: "trigger") }
            Prefs.trigger = .holdOrTap
            T.eq(Prefs.trigger, .holdOrTap)
        }
        T.test("key: property — any press of at least 0.3 s is push-to-talk in every mode") {
            var rng = SeededRandom(21)
            for _ in 0..<300 {
                let held = Double.random(in: 0...3, using: &rng)
                for t in Prefs.Trigger.allCases {
                    let r = KeyRelease.classify(held: held, trigger: t)
                    T.ok((held >= KeyRelease.minHold) == (r == .finish), "held \(held) in \(t) → \(r)")
                }
            }
        }
        T.test("key: the double-tap window is short enough to feel instant and long enough for a normal double tap") {
            T.ok(KeyRelease.doubleTapWindow >= 0.3 && KeyRelease.doubleTapWindow <= 0.5, "\(KeyRelease.doubleTapWindow)")
        }
    }

    // MARK: 1. Unload after idle by default

    static func unloadDefault() {
        T.test("unload: by default the model is freed after 15 minutes idle") {
            let d = UserDefaults.standard
            let saved = d.object(forKey: "unloadAfterMinutes")
            defer { d.set(saved, forKey: "unloadAfterMinutes") }
            d.removeObject(forKey: "unloadAfterMinutes")
            T.eq(Prefs.unloadAfterMinutes, 15)
            Prefs.unloadAfterMinutes = 0
            T.eq(Prefs.unloadAfterMinutes, 0, "an explicit «никогда» must stick, not fall back to the default")
        }
        T.test("unload: the default is one of the choices offered in Настройки") {
            T.ok(SettingsPane.unloadOptions.contains { $0.0 == Prefs.defaultUnloadMinutes }, "\(SettingsPane.unloadOptions)")
        }
    }

    // MARK: 5. ⌃⌥V paste again

    static func pasteAgain() {
        T.test("paste: a space follows a sentence end, so the next dictation does not stick to it") {
            T.eq(Paster.withTrailingSpace("Готово."), "Готово. ")
            T.eq(Paster.withTrailingSpace("Правда?"), "Правда? ")
            T.eq(Paster.withTrailingSpace("Ура!"), "Ура! ")
            T.eq(Paster.withTrailingSpace("и так далее…"), "и так далее… ")
        }
        T.test("paste: no space after a word or an empty text") {
            T.eq(Paster.withTrailingSpace("созвон в 11"), "созвон в 11")
            T.eq(Paster.withTrailingSpace(""), "")
        }
        T.test("paste: property — the text itself is never changed, at most one space is added") {
            var rng = SeededRandom(5)
            for _ in 0..<200 {
                let p = rng.phrase() + ["", ".", "?", "!", "…", ","].randomElement(using: &rng)!
                let r = Paster.withTrailingSpace(p)
                T.ok(r == p || r == p + " ", "'\(p)' → '\(r)'")
            }
        }
    }

    // MARK: 8. Is there a text field to paste into?

    static func focusedField() {
        typealias F = FocusedField
        T.test("focus: text fields and editable elements count as a place to paste") {
            for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
                T.eq(F.classify(error: .success, role: role, editable: false, lazyTree: false, isFinder: false), .text, role)
            }
            T.eq(F.classify(error: .success, role: "AXGroup", editable: true, lazyTree: false, isFinder: false), .text,
                 "a contenteditable div is an AXGroup with an editable ancestor")
        }
        T.test("focus: a file list, a button or a web page without a field is not a place to paste") {
            for role in ["AXList", "AXOutline", "AXButton", "AXWebArea", "AXWindow"] {
                T.eq(F.classify(error: .success, role: role, editable: false, lazyTree: false, isFinder: false), .none, role)
            }
        }
        T.test("focus: nothing focused means the desktop only in Finder; elsewhere it is unknown") {
            T.eq(F.classify(error: .noValue, role: nil, editable: false, lazyTree: false, isFinder: true), .none)
            T.eq(F.classify(error: .noValue, role: nil, editable: false, lazyTree: false, isFinder: false), .unknown)
        }
        T.test("focus: Chrome/Electron without an accessibility tree never get the card (no false alarms)") {
            for role in ["AXWindow", "AXGroup", "AXWebArea"] {
                T.eq(F.classify(error: .success, role: role, editable: false, lazyTree: true, isFinder: false), .unknown, role)
            }
            T.eq(F.classify(error: .success, role: "AXTextArea", editable: false, lazyTree: true, isFinder: false), .text)
        }
        T.test("focus: Accessibility errors (no permission, app busy) are unknown, not «no field»") {
            for e in [AXError.apiDisabled, .cannotComplete, .notImplemented, .failure] {
                T.eq(F.classify(error: e, role: nil, editable: false, lazyTree: false, isFinder: true), .unknown, "\(e.rawValue)")
            }
        }
        T.test("focus: property — an editable element is always a place to paste, whatever its role") {
            var rng = SeededRandom(8)
            let roles = Array(F.nonTextRoles) + ["AXUnknown", "AXCustom"]
            for _ in 0..<200 {
                let r = roles.randomElement(using: &rng)!
                T.eq(F.classify(error: .success, role: r, editable: true, lazyTree: Bool.random(using: &rng), isFinder: Bool.random(using: &rng)), .text, r)
            }
        }
        T.test("focus: Electron/Chromium apps and browsers are recognised as building their tree lazily") {
            let app = FileManager.default.temporaryDirectory.appendingPathComponent("Fake-\(UUID().uuidString).app")
            defer { try? FileManager.default.removeItem(at: app) }
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                    withIntermediateDirectories: true)
            T.ok(F.hasLazyTree(bundleID: "com.example.chat", bundleURL: app), "Electron app by its framework")
            T.ok(F.hasLazyTree(bundleID: "com.google.Chrome", bundleURL: nil), "Chrome by bundle id")
            T.ok(!F.hasLazyTree(bundleID: "com.apple.TextEdit", bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")), "TextEdit is native")
        }
    }

    // MARK: 10. Updates

    static func updateVersions() {
        T.test("update: newer versions are recognised numerically, not as text") {
            T.ok(Updater.isNewer("1.10.0", than: "1.9.0"), "1.10 > 1.9")
            T.ok(Updater.isNewer("v1.1.0", than: "1.0"), "tag with v")
            T.ok(Updater.isNewer("2", than: "1.99.99"), "major")
            T.ok(Updater.isNewer("1.1.1", than: "1.1"), "patch on a two-part version")
        }
        T.test("update: the same or an older version is not offered") {
            T.ok(!Updater.isNewer("1.1.0", than: "1.1.0"), "same")
            T.ok(!Updater.isNewer("1.1", than: "1.1.0"), "same, fewer parts")
            T.ok(!Updater.isNewer("1.0.9", than: "1.1.0"), "older")
            T.ok(!Updater.isNewer("garbage", than: "1.0"), "unparsable tag")
            T.ok(!Updater.isNewer("1.2.0-beta", than: "1.2.0"), "pre-release suffix of the same version")
        }
        T.test("update: property — «newer» is a strict order (never both ways, never with itself)") {
            var rng = SeededRandom(10)
            func v() -> String { (0..<Int.random(in: 1...3, using: &rng)).map { _ in "\(Int.random(in: 0...12, using: &rng))" }.joined(separator: ".") }
            for _ in 0..<300 {
                let a = v(), b = v(), c = v()
                T.ok(!Updater.isNewer(a, than: a), "\(a) > itself")
                T.ok(!(Updater.isNewer(a, than: b) && Updater.isNewer(b, than: a)), "\(a) vs \(b)")
                if Updater.isNewer(a, than: b) && Updater.isNewer(b, than: c) { T.ok(Updater.isNewer(a, than: c), "\(a) > \(b) > \(c)") }
            }
        }
    }

    static func release(_ extra: [String: Any] = [:], assets: [[String: Any]]? = nil) -> Data {
        var j: [String: Any] = ["tag_name": "v1.2.0", "html_url": "https://github.com/Malashkin/JustTellMe/releases/tag/v1.2.0",
                                "body": "### Added\n- something", "draft": false, "prerelease": false,
                                "assets": assets ?? [["name": "JustTellMe.zip", "size": 537_000_000,
                                                      "browser_download_url": "https://github.com/Malashkin/JustTellMe/releases/download/v1.2.0/JustTellMe.zip"]]]
        for (k, v) in extra { j[k] = v }
        return try! JSONSerialization.data(withJSONObject: j)
    }

    static func releaseParsing() {
        T.test("update: a GitHub release gives version, zip, size and notes") {
            guard let r = Updater.parse(release()) else { return T.fail("not parsed") }
            T.eq(r.version, "1.2.0")
            T.eq(r.zip?.lastPathComponent, "JustTellMe.zip")
            T.eq(r.size, 537_000_000)
            T.ok(r.notes.contains("something"), r.notes)
        }
        T.test("update: drafts and pre-releases are ignored") {
            T.ok(Updater.parse(release(["draft": true])) == nil, "draft")
            T.ok(Updater.parse(release(["prerelease": true])) == nil, "prerelease")
        }
        T.test("update: a release without JustTellMe.zip has no download (the app opens the page instead)") {
            let r = Updater.parse(release(assets: [["name": "Source.tar.gz", "browser_download_url": "https://x/y"]]))
            T.ok(r != nil && r?.zip == nil, "\(String(describing: r))")
        }
        T.test("update: without the API the version comes from the /releases/latest redirect") {
            func v(_ u: String) -> String? { Updater.version(fromReleasePage: URL(string: u)!) }
            T.eq(v("https://github.com/Malashkin/JustTellMe/releases/tag/v1.2.0"), "1.2.0")
            T.eq(v("https://github.com/Malashkin/JustTellMe/releases/tag/2.0"), "2.0")
            T.eq(v("https://github.com/Malashkin/JustTellMe/releases"), nil, "no releases yet: the page does not redirect to a tag")
            T.eq(v("https://github.com/Malashkin/JustTellMe/releases/tag/nightly"), nil, "not a version")
        }
        T.test("update: garbage from the network is rejected, not crashed on") {
            for d in [Data(), Data("<html>rate limited</html>".utf8), Data("{}".utf8), Data("[1,2]".utf8), Data(#"{"tag_name": 5}"#.utf8)] {
                T.ok(Updater.parse(d) == nil, String(decoding: d, as: UTF8.self))
            }
        }
    }

    // MARK: 4. Recording pill

    static func waveform() {
        T.test("pill: bars stay inside the pill and move with the voice") {
            let w = WaveView(frame: NSRect(x: 0, y: 0, width: 132, height: 28))
            w.mode = .recording
            var rng = SeededRandom(4)
            var maxAmp: CGFloat = 0
            for i in 0..<300 {
                if i % 3 == 0 { w.push(Float.random(in: 0...0.5, using: &rng)) }
                w.tick()
                for b in 0..<18 {
                    let a = w.amplitude(b)
                    T.ok(a > 0 && a <= 1, "bar \(b) amplitude \(a)")
                    maxAmp = max(maxAmp, a)
                }
            }
            T.ok(maxAmp > 0.5, "loud speech should raise the bars, max \(maxAmp)")
        }
        T.test("pill: in silence the bars settle to the idle pulse") {
            let w = WaveView(frame: NSRect(x: 0, y: 0, width: 132, height: 28))
            w.mode = .recording
            w.push(0.3)
            for _ in 0..<Int(WaveView.fps * 4) { w.tick() } // 4 s of silence
            for b in 0..<18 { T.ok(w.amplitude(b) <= 0.2, "bar \(b) still at \(w.amplitude(b))") }
        }
    }
}
