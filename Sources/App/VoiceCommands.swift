import Cocoa

/// A spoken command word at the very start of a dictation («Заметка …», «Задача …»).
/// The recogniser sometimes gets the word slightly wrong («Замевка», «Заметко», «За метка»), so the first word
/// may be one letter off; real words that are one letter off are listed in `lookalikes` and never count.
struct SpokenKeyword {
    let keyword: String
    /// Ordinary words one letter away from the keyword: a phrase starting with them is not a command.
    let lookalikes: Set<String>
    /// Accept a word one letter off. Off for short words, where one letter turns «идея» into «идем».
    var fuzzy = true

    /// The text after the keyword when `text` starts with it (or a near miss of it) as a whole word, else nil.
    /// «Заметка, купить молоко.» → «Купить молоко.»; «Замевка купить молоко» → «Купить молоко»;
    /// «Заметка.» → ""; «Заметками …», «Заметна …» and «Это заметка …» → nil.
    func body(of text: String) -> String? { match(text)?.body }

    /// Like `body(of:)`, and whether the keyword was heard exactly (an exact word beats a near miss of another list).
    func match(_ text: String) -> (body: String, exact: Bool)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = Self.leadingWords(t, count: 2)
        guard let first = words.first else { return nil }
        var restStart: String.Index?
        var exact = false
        if let m = matchKind(first.word) {
            restStart = first.end
            exact = m
        } else if words.count == 2, first.word.count <= 3, let m = matchKind(first.word + words[1].word) {
            restStart = words[1].end   // «За метка …»
            exact = m
        }
        guard let from = restStart else { return nil }
        let leading = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "—–-"))
        var body = String(t[from...]).trimmingCharacters(in: leading)
        if body.isEmpty { return ("", exact) }
        // Keep the closing punctuation the recogniser put after the text itself.
        if let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last, ".!?…".contains(last), !".!?…".contains(body.last!) {
            body.append(last)
        }
        return (body.prefix(1).uppercased() + body.dropFirst(), exact)
    }

    /// Lowercase, «ё» as «е»: how keywords and heard words are compared.
    static func normalize(_ w: String) -> String { w.lowercased().replacingOccurrences(of: "ё", with: "е") }

    /// true: the keyword itself; false: one letter off it (and not a real word that merely looks like it); nil: no.
    private func matchKind(_ word: String) -> Bool? {
        let w = Self.normalize(word)
        if w == keyword { return true }
        guard fuzzy, !lookalikes.contains(w), abs(w.count - keyword.count) <= 1 else { return nil }
        return Self.editDistance(w, keyword, limit: 1) <= 1 ? false : nil
    }

    /// The first `count` words (letters and digits) and where each ends.
    private static func leadingWords(_ s: String, count: Int) -> [(word: String, end: String.Index)] {
        var out: [(String, String.Index)] = []
        var i = s.startIndex
        while out.count < count, i < s.endIndex {
            while i < s.endIndex, !(s[i].isLetter || s[i].isNumber) {
                // Only spaces may separate the two halves of «За метка»; punctuation ends the search.
                if !out.isEmpty && !s[i].isWhitespace { return out }
                i = s.index(after: i)
            }
            let begin = i
            while i < s.endIndex, s[i].isLetter || s[i].isNumber { i = s.index(after: i) }
            if begin < i { out.append((String(s[begin..<i]), i)) }
        }
        return out
    }

    /// Levenshtein distance, giving up (returning limit + 1) once it exceeds `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if cur.min()! > limit { return limit + 1 }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }
}

// MARK: - "Saved to “Notes”" card: confirms that nothing was pasted and where the text went

final class SavedCard: NSObject {
    var onOpen: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let open = NSButton(title: "", target: nil, action: nil)

    private var panel: NSPanel?
    private let body = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 380, height: 104)

    func show(_ text: String, title: String, button: String) {
        let p = panel ?? make()
        panel = p
        body.stringValue = text
        self.title.stringValue = title
        open.title = button
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28)) }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        hide(after: 4)
    }

    private func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Debug: write the card as PNG (--demo-note-card).
    func snapshot(to url: URL) {
        guard let v = panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @objc private func openAction() { hide(after: 0); onOpen?() }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        let w = size.width - 28
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 14, y: size.height - 30, width: w, height: 18)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 2
        body.cell?.truncatesLastVisibleLine = true
        body.lineBreakMode = .byWordWrapping
        body.frame = NSRect(x: 14, y: 40, width: w, height: 32)
        open.target = self
        open.action = #selector(openAction)
        open.bezelStyle = .rounded
        open.frame = NSRect(x: size.width - 14 - 150, y: 6, width: 150, height: 30)
        for v in [title, body, open] as [NSView] { bg.addSubview(v) }
        p.contentView = bg
        return p
    }
}
