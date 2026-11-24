import Cocoa

/// The Liquid Glass controls: capsule buttons, the segmented capsule, and colors that follow Light/Dark mode.
enum GlassTests {
    static func run() {
        T.test("glass: colors differ between Light and Dark mode") {
            let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
            T.ok(!light.isDark && dark.isDark, "appearance detection")
            var l: CGFloat = 0, d: CGFloat = 0
            light.performAsCurrentDrawingAppearance { l = Glass.fill.usingColorSpace(.deviceRGB)!.alphaComponent }
            dark.performAsCurrentDrawingAppearance { d = Glass.fill.usingColorSpace(.deviceRGB)!.alphaComponent }
            T.ok(l > d, "light glass is more opaque than dark glass")
        }
        T.test("glass: capsule button keeps its title, pads it, and dims when disabled") {
            let b = CapsuleButton("Done", style: .prominent)
            T.eq(b.title, "Done")
            T.eq(b.attributedTitle.string, "Done")
            T.ok(b.intrinsicContentSize.width > b.attributedTitle.size().width + 20, "horizontal padding")
            T.eq(b.intrinsicContentSize.height, 30)
            b.title = "Backlog"
            T.eq(b.attributedTitle.string, "Backlog")
            b.isEnabled = false
            T.ok(b.alphaValue < 1, "disabled is dimmed")
            b.isEnabled = true
            T.eq(b.alphaValue, 1)
        }
        T.test("glass: segmented capsule reports the picked segment once") {
            let s = CapsuleSegments(["All", "Backlog", "Done"])
            var picked: [Int] = []
            s.onChange = { picked.append($0) }
            T.eq(s.selected, 0)
            let buttons = s.subviews.flatMap(\.subviews).compactMap { $0 as? CapsuleButton }
            T.eq(buttons.map(\.title), ["All", "Backlog", "Done"])
            buttons[2].performClick(nil)
            buttons[2].performClick(nil)
            T.eq(s.selected, 2)
            T.eq(picked, [2], "clicking the chosen segment again changes nothing")
            T.ok(buttons[2].style == .glass && buttons[0].style == .plain, "only the chosen segment is raised")
        }
        T.test("glass: checkbox and status capsule are centred on the first line of a task") {
            let store = VoiceLists.shared
            let l = store.addList(name: "Align", keywords: ["Выровнять"], kind: .tasks)
            defer { store.removeList(l.id) }
            store.addItem(to: l.id, text: "Сделать отчёт prime-med.", lang: "ru")
            let pane = ListPane(listID: l.id)
            pane.reload()
            func find(_ v: NSView) -> NSTableView? { (v as? NSTableView) ?? v.subviews.lazy.compactMap(find).first }
            guard let table = find(pane.view) else { return T.ok(false, "table") }
            table.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            let row = 1   // row 0 is the day header
            func cell(_ id: String) -> NSView? {
                guard let c = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { return nil }
                let v = table.view(atColumn: c, row: row, makeIfNecessary: true)
                v?.frame.size = NSSize(width: table.tableColumns[c].width, height: table.rect(ofRow: row).height)
                v?.layoutSubtreeIfNeeded()
                return v
            }
            /// Distance from the top of the cell to the centre of its first subview (or of its first text line).
            func centre(_ v: NSView?, line: Bool = false) -> CGFloat {
                guard let v = v, let sub = v.subviews.first else { return -100 }
                let r = sub.alignmentRect(forFrame: sub.frame)
                let top = v.isFlipped ? r.minY : v.bounds.height - r.maxY
                return line ? top + ListPane.firstLineHeight / 2 : top + r.height / 2
            }
            let text = centre(cell("text"), line: true)
            T.ok(abs(centre(cell("status")) - text) <= 1, "status capsule \(centre(cell("status"))) vs text line \(text)")
            T.ok(abs(centre(cell("check")) - text) <= 1, "checkbox \(centre(cell("check"))) vs text line \(text)")
        }
        T.test("glass: the backdrop mask stretches with the view") {
            let m = Glass.mask(radius: 22)
            T.eq(m.resizingMode, .stretch)
            T.eq(m.capInsets.top, 22)
            let v = Glass.backdrop(.popover, radius: 22)
            T.eq(v.blendingMode, .behindWindow)
            T.ok(v.maskImage != nil, "rounded clip for the blur")
        }
    }
}
