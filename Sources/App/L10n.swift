import Foundation

/// Interface language: Russian when the system's first preferred language is Russian, English otherwise.
/// Strings live next to the code as English/Russian pairs (`tr`), so the swiftc-only build needs no .strings files.
/// `JTM_LANG=en|ru` forces a language (tests, screenshots).
enum L10n {
    static var isRussian: Bool = {
        if let forced = ProcessInfo.processInfo.environment["JTM_LANG"] { return forced.hasPrefix("ru") }
        return Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
    }() {
        didSet { formatters.removeAll() }
    }

    static var locale: Locale { Locale(identifier: isRussian ? "ru_RU" : "en_US") }

    /// Noun form for a count: English one/other, Russian one/few/many («1 день», «2 дня», «5 дней»).
    static func plural(_ n: Int, en: (String, String), ru: (String, String, String)) -> String {
        guard isRussian else { return n == 1 ? en.0 : en.1 }
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return ru.0 }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return ru.1 }
        return ru.2
    }

    private static var formatters: [String: DateFormatter] = [:]

    /// A date formatter for the current language: `en` and `ru` are dateFormat patterns.
    static func formatter(en: String, ru: String) -> DateFormatter {
        let pattern = isRussian ? ru : en
        if let f = formatters[pattern] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = pattern
        formatters[pattern] = f
        return f
    }
}

/// English text, or its Russian translation when the interface is Russian.
func tr(_ en: String, _ ru: String) -> String { L10n.isRussian ? ru : en }
