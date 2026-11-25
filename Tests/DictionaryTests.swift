import Cocoa

/// The Dictionary page: personal words as chips, replacements as rows, the built-in dictionary
/// behind a switch, the recogniser prompt under "Advanced". Edits are saved at once.
enum DictionaryTests {
    static func run() {
        T.test("vocab: removing a word or a replacement keeps the comments and the other lines") {
            try "# my terms\nGitHub\nFigma\n".write(to: Paths.dictionary, atomically: true, encoding: .utf8)
            try "# rules\nгитхаб => GitHub\nпул реквест => pull request\n".write(to: Paths.replacements, atomically: true, encoding: .utf8)
            let v = Vocabulary()
            v.removeTerm("figma")
            v.removeRule(from: "Гитхаб")
            T.eq(v.personalTerms, ["GitHub"])
            T.eq(v.personalRules.map(\.from), ["пул реквест"])
            T.eq(try String(contentsOf: Paths.dictionary, encoding: .utf8), "# my terms\nGitHub\n")
            T.eq(try String(contentsOf: Paths.replacements, encoding: .utf8), "# rules\nпул реквест => pull request\n")
        }
        T.test("vocab: a custom prompt is stored; the default one is not") {
            let v = Vocabulary()
            v.setPrompt("Встреча про релиз, deploy и rollback.")
            T.eq(Vocabulary().basePrompt, "Встреча про релиз, deploy и rollback.")
            v.setPrompt(Vocabulary.defaultPrompt)
            T.ok(!FileManager.default.fileExists(atPath: Paths.prompt.path), "default prompt is not stored")
        }
        T.test("dictionary page: words are chips, replacements are rows, edits save at once") {
            try "# header\nGitHub\n".write(to: Paths.dictionary, atomically: true, encoding: .utf8)
            try "# header\nгитхаб => GitHub\n".write(to: Paths.replacements, atomically: true, encoding: .utf8)
            Vocabulary.shared.reload()
            let pane = VocabularyPane()
            pane.reload()
            T.eq(pane.wordTitles, ["GitHub"])
            T.eq(pane.ruleTitles, ["гитхаб → GitHub"])
            pane.addWord("  Figma ")
            pane.addWord("figma")
            T.eq(pane.wordTitles, ["GitHub", "Figma"], "added once, trimmed")
            T.eq(Vocabulary.shared.personalTerms, ["GitHub", "Figma"], "saved")
            pane.addRule("зум", "Zoom")
            T.eq(pane.ruleTitles, ["гитхаб → GitHub", "зум → Zoom"])
            pane.removeWord("GitHub")
            pane.removeRule("гитхаб")
            T.eq(Vocabulary.shared.personalTerms, ["Figma"])
            T.eq(Vocabulary.shared.personalRules.map(\.from), ["зум"])
            T.eq(pane.ruleTitles, ["зум → Zoom"])
        }
        T.test("dictionary page: no code look, no Save button") {
            let pane = VocabularyPane()
            pane.reload()
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let views = all(pane.view)
            let fonts = views.compactMap { ($0 as? NSTextView)?.font ?? ($0 as? NSTextField)?.font }
            T.ok(!fonts.contains { $0.fontDescriptor.symbolicTraits.contains(.monoSpace) }, "no monospaced text")
            let texts = views.compactMap { ($0 as? NSTextView)?.string ?? ($0 as? NSTextField)?.stringValue }
            T.ok(!texts.contains { $0.hasPrefix("#") }, "file comments are not shown")
            T.ok(!views.contains { ($0 as? NSButton)?.title == tr("Save", "Сохранить") }, "no Save button")
        }
    }
}
