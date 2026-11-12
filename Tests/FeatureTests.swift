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
