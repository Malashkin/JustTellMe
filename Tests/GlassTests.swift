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
