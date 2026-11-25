import Cocoa

/// Floating glass pill at the bottom of the screen: a recording dot, a live waveform, the elapsed time
/// and a hint ("Esc to cancel"). While transcribing the dot and the wave turn blue.
/// Never takes focus, so ⌘V still lands in the app the user was typing in.
final class RecordingOverlay {
    enum Mode { case hidden, recording, transcribing }

    static let height: CGFloat = 56
    static let padLeft: CGFloat = 18, padRight: CGFloat = 22, gap: CGFloat = 14
    static let dotSize: CGFloat = 12, halo: CGFloat = 5

    let size: NSSize
    private var panel: NSPanel?
    private let wave = WaveView(frame: NSRect(x: 0, y: 0, width: WaveView.width, height: 30))
    private let dot = CALayer(), haloLayer = CALayer()
    private let dotHost = NSView()
    let clock = NSTextField(labelWithString: "0:00")
    let hint = NSTextField(labelWithString: "")
    private let content: NSView
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var startedAt: Date?
    private(set) var mode: Mode = .hidden

    static func clockText(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    var hintText: String {
        switch mode {
        case .transcribing: return tr("Transcribing…", "Распознаю…")
        default: return locked ? tr("Tap to finish", "Нажмите — готово") : tr("Esc to cancel", "Esc — отмена")
        }
    }

    init() {
        let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold), hintFont = NSFont.systemFont(ofSize: 12)
        clock.font = clockFont
        clock.textColor = .labelColor
        hint.font = hintFont
        hint.textColor = .secondaryLabelColor
        // A fixed width (the longest hint), so the pill does not jump when the hint changes.
        let hints = [tr("Transcribing…", "Распознаю…"), tr("Tap to finish", "Нажмите — готово"), tr("Esc to cancel", "Esc — отмена")]
        let hintW = ceil(hints.map { ($0 as NSString).size(withAttributes: [.font: hintFont]).width }.max()!) + 4
        let clockW = ceil(("00:00" as NSString).size(withAttributes: [.font: clockFont]).width) + 2
        let h = Self.height
        var x = Self.padLeft
        dotHost.frame = NSRect(x: x - Self.halo, y: (h - Self.dotSize) / 2 - Self.halo, width: Self.dotSize + Self.halo * 2, height: Self.dotSize + Self.halo * 2)
        x += Self.dotSize + Self.gap
        wave.frame.origin = NSPoint(x: x, y: (h - wave.frame.height) / 2)
        x += wave.frame.width + Self.gap
        let clockH = ceil(clock.fittingSize.height), hintH = ceil(hint.fittingSize.height)
        clock.frame = NSRect(x: x, y: (h - clockH) / 2, width: clockW, height: clockH)
        x += clockW + 10
        hint.frame = NSRect(x: x, y: (h - hintH) / 2, width: hintW, height: hintH)
        x += hintW + Self.padRight - 4
        size = NSSize(width: ceil(x), height: h)

        // A glass capsule: the blurred screen behind it and a light edge.
        // maskImage (not layer.cornerRadius) is what actually clips the behind-window blur to the pill shape.
        content = Glass.backdrop(.popover, radius: h / 2)
        content.frame = NSRect(origin: .zero, size: size)
        dotHost.wantsLayer = true
        haloLayer.frame = dotHost.bounds
        haloLayer.cornerRadius = dotHost.bounds.width / 2
        dot.frame = dotHost.bounds.insetBy(dx: Self.halo, dy: Self.halo)
        dot.cornerRadius = Self.dotSize / 2
        dotHost.layer?.addSublayer(haloLayer)
        dotHost.layer?.addSublayer(dot)
        for v in [dotHost, wave, clock, hint] { content.addSubview(v) }
        restyle()
    }

    func show(_ mode: Mode) {
        hideWork?.cancel()
        switch mode {
        case .hidden: hide(); return
        case .recording:
            if self.mode != .recording { wave.reset(); startedAt = Date(); clock.stringValue = Self.clockText(0) }
            wave.mode = .recording
        case .transcribing: wave.mode = .transcribing; locked = false
        }
        self.mode = mode
        restyle()
        let p = panel ?? makePanel()
        panel = p
        position(p)
        if !p.isVisible || p.alphaValue < 1 {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / WaveView.fps, repeats: true) { [weak self] _ in self?.tick() }
            timer?.tolerance = 0.2 / WaveView.fps
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    func push(level: Float) { wave.push(level) }

    /// The pill's window, for screen captures in the demo.
    var windowNumber: Int? { panel?.windowNumber }

    /// Hands-free recording (key was tapped, not held): the hint says how to finish.
    var locked = false { didSet { if locked != oldValue { restyle() } } }

    private func tick() {
        wave.tick()
        if mode == .recording, let t = startedAt {
            let text = Self.clockText(Int(Date().timeIntervalSince(t)))
            if clock.stringValue != text { clock.stringValue = text }
        }
    }

    private func restyle() {
        hint.stringValue = hintText
        let color = mode == .transcribing ? Brick.blue : Brick.orange
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        haloLayer.backgroundColor = color.withAlphaComponent(0.22).cgColor
        CATransaction.commit()
        if mode == .recording, haloLayer.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.35; a.duration = 0.8
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            haloLayer.add(a, forKey: "pulse")
        } else if mode != .recording {
            haloLayer.removeAnimation(forKey: "pulse")
        }
    }

    /// Debug: write the pill as PNG (used by --demo-overlay to check the look without screen recording).
    func snapshot(to url: URL, dark: Bool = false) {
        // The bars are plain CALayers, which cacheDisplay does not draw: render the layer tree instead.
        let v = content
        content.displayIfNeeded()
        guard let layer = v.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width) * 2, pixelsHigh: Int(v.bounds.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(dark ? NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.24, alpha: 1).cgColor
                              : NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.95, alpha: 1).cgColor)
        ctx.fill(v.bounds)
        layer.render(in: ctx)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func hide() {
        guard let p = panel, p.isVisible else { wave.mode = .hidden; mode = .hidden; locked = false; return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) {
                guard self?.hideWork?.isCancelled == false else { return }
                p.orderOut(nil)
                self?.wave.mode = .hidden
                self?.mode = .hidden
                self?.locked = false
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }
        hideWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        // A window shadow on a borderless panel is drawn around the rectangular frame, not the pill.
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = content
        return p
    }

    /// Bottom-centre of the screen with the mouse (where the user is working), above the Dock.
    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28))
    }
}

/// Bars are CALayers whose frames are set directly (no implicit animations), so a frame costs no
/// view redraw: the window server only recomposites 24 small rectangles. 30 updates a second
/// look as smooth as 60 for this motion, at half the wake-ups.
final class WaveView: NSView {
    static let fps = 30.0
    static let count = 24, barWidth: CGFloat = 3, barGap: CGFloat = 3
    static var width: CGFloat { CGFloat(count) * barWidth + CGFloat(count - 1) * barGap }
    var mode: RecordingOverlay.Mode = .recording { didSet { if mode != oldValue { recolor() } } }
    private let count = WaveView.count
    private var levels: [CGFloat]     // sampled history, scrolls left
    private var shown: [CGFloat]      // what is drawn, eases toward `levels`
    private var target: CGFloat = 0
    private var phase: CGFloat = 0
    private var ticks = 0
    private let samplesPerSecond = 10  // scroll speed while recording
    private var bars: [CALayer] = []
    /// Per-frame easing toward the target, same speed as 0.18 per frame at 60 fps.
    private static let ease = 1 - pow(1 - 0.18, 60 / fps)

    override init(frame: NSRect) {
        levels = Array(repeating: 0, count: count)
        shown = levels
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<count {
            let b = CALayer()
            b.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(b)
            bars.append(b)
        }
        recolor()
        layoutBars()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutBars() }

    func reset() { levels = Array(repeating: 0, count: count); shown = levels; target = 0 }

    func push(_ rms: Float) {
        // Speech RMS is ~0.01–0.2; map to 0…1 on a log-ish curve so quiet voices still move.
        let v = CGFloat(min(1, max(0, (log10(max(rms, 1e-4)) + 3.2) / 2.2)))
        target = max(target * 0.6, v)
    }

    func tick() {
        ticks += 1
        if mode == .recording {
            phase += 0.05 * 60 / Self.fps
            if ticks % (Int(Self.fps) / samplesPerSecond) == 0 {
                levels.removeFirst()
                levels.append(target * CGFloat.random(in: 0.85...1.0))
                target *= 0.6
            }
            for i in 0..<count { shown[i] += (levels[i] - shown[i]) * Self.ease }
        } else {
            phase += 0.12 * 60 / Self.fps
        }
        layoutBars()
    }

    /// Height of bar i, 0…1.
    func amplitude(_ i: Int) -> CGFloat {
        switch mode {
        case .transcribing:
            return 0.25 + 0.35 * (0.5 + 0.5 * sin(phase - CGFloat(i) * 0.45))
        default:
            // Centre-weighted so the shape reads as a voice waveform, with a small idle pulse.
            let centre = 1 - abs(CGFloat(i) - CGFloat(count - 1) / 2) / CGFloat(count) * 0.9
            return max(0.12 + 0.04 * sin(phase + CGFloat(i) * 0.6), shown[i] * centre)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private func recolor() {
        let c = cg(mode == .transcribing ? Brick.blueText : NSColor.labelColor.withAlphaComponent(0.82))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for b in bars { b.backgroundColor = c }
        CATransaction.commit()
    }

    private func layoutBars() {
        let w = bounds.width, h = bounds.height
        let gap = Self.barGap
        let barW = (w - gap * CGFloat(count - 1)) / CGFloat(count)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, b) in bars.enumerated() {
            let bh = max(barW, h * amplitude(i))
            b.frame = CGRect(x: CGFloat(i) * (barW + gap), y: (h - bh) / 2, width: barW, height: bh)
            b.cornerRadius = barW / 2
        }
        CATransaction.commit()
    }
}
