import Cocoa

/// The interface follows the system language: English by default, Russian when macOS prefers Russian.
/// The other test files check the Russian texts; these check the English ones and the switch itself.
enum LocalizationTests {
    static func run() {
        let saved = L10n.isRussian
        defer { L10n.isRussian = saved }
        L10n.isRussian = false
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!

        T.test("language: English interface texts") {
            T.eq(tr("Delete", "Удалить"), "Delete")
            T.eq(MainWindow.Page.settings.title, "Settings")
            T.eq(MainWindow.Page.home.title, "Home")
            T.eq(ListPane.deleteTitle(1, kind: .notes), "Delete 1 entry")
            T.eq(ListPane.deleteTitle(3, kind: .tasks), "Delete 3 tasks")
        }
        T.test("language: English plurals and dates") {
            T.eq(L10n.plural(1, en: ("day", "days"), ru: ("день", "дня", "дней")), "day")
            T.eq(L10n.plural(2, en: ("day", "days"), ru: ("день", "дня", "дней")), "days")
            T.eq(ListFilter.dayTitle(now, now: now), "Today, November 23")
            T.eq(ListFilter.dayTitle(cal.date(byAdding: .day, value: 1, to: now)!, now: now), "Tomorrow, November 24")
            T.eq(ListFilter.dayTitle(cal.date(byAdding: .day, value: -3, to: now)!, now: now), "Friday, November 20, 2026")
            let s = ListFilter.stamp(cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9, minute: 5))!)
            T.eq(s, "Nov 23, 09:05")
        }
        T.test("language: English default lists are Notes and Tasks, opened by «Note» and «Task»") {
            let lists = VoiceLists.defaultLists()
            T.eq(lists.map(\.name), ["Notes", "Tasks"])
            T.eq(lists.map(\.keywords), [["Note"], ["Task"]])
            T.eq(VoiceLists.match("Note: buy milk.", in: lists)?.body, "Buy milk.")
            T.eq(VoiceLists.match("Task, send the report", in: lists)?.list.name, "Tasks")
            T.eq(VoiceLists.match("Notes from the meeting", in: lists)?.body, nil, "short words must be heard exactly")
        }
        T.test("language: switching to Russian changes texts and date formats") {
            L10n.isRussian = true
            defer { L10n.isRussian = false }
            T.eq(tr("Delete", "Удалить"), "Удалить")
            T.eq(L10n.plural(5, en: ("day", "days"), ru: ("день", "дня", "дней")), "дней")
            T.eq(ListFilter.dayTitle(now, now: now), "Сегодня, 23 ноября")
            T.eq(VoiceLists.defaultLists().map(\.name), ["Заметки", "Задачи"])
        }
    }
}
