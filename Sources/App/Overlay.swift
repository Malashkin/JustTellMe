import Cocoa

/// Floating pill at the bottom of the screen: live waveform while recording,
/// a travelling wave while transcribing. Never takes focus, so ⌘V still lands
/// in the app the user was typing in.
final class RecordingOverlay {
    enum Mode { case hidden, recording, transcribing }

    private let size = NSSize(width: 168, height: 44)
    private var panel: NSPanel?
    private let wave = WaveView()
    private let lockDot = NSView()
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?

    func show(_ mode: Mode) {
        hideWork?.cancel()
        switch mode {
        case .hidden: hide(); return
        case .recording: if wave.mode != .recording { wave.reset() }; wave.mode = .recording
        case .transcribing: wave.mode = .transcribing; locked = false
        }
        let p = panel ?? makePanel()
        panel = p
        position(p)
        if !p.isVisible || p.alphaValue < 1 {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / WaveView.fps, repeats: true) { [weak self] _ in self?.wave.tick() }
            timer?.tolerance = 0.2 / WaveView.fps
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    func push(level: Float) { wave.push(level) }

    /// Hands-free recording (key was tapped, not held): a red dot shows it keeps listening until the next tap.
    var locked = false { didSet { lockDot.isHidden = !locked } }

    /// Debug: write the pill as PNG (used by --demo-overlay to check the look without screen recording).
    func snapshot(to url: URL) {
        // The bars are plain CALayers, which cacheDisplay does not draw: render the layer tree instead.
        guard let v = panel?.contentView, let layer = v.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width) * 2, pixelsHigh: Int(v.bounds.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
        ctx.fill(v.bounds)
        layer.render(in: ctx)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func hide() {
        guard let p = panel, p.isVisible else { wave.mode = .hidden; locked = false; return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) {
                guard self?.hideWork?.isCancelled == false else { return }
                p.orderOut(nil)
                self?.wave.mode = .hidden
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

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.state = .active
        bg.blendingMode = .behindWindow
        // maskImage (not layer.cornerRadius) is what actually clips the behind-window blur to the pill shape.
        let radius = size.height / 2
        bg.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        wave.frame = bg.bounds.insetBy(dx: 18, dy: 8)
        bg.addSubview(wave)
        lockDot.frame = NSRect(x: 7, y: (size.height - 7) / 2, width: 7, height: 7)
        lockDot.wantsLayer = true
        lockDot.layer?.cornerRadius = 3.5
        lockDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        lockDot.isHidden = !locked
        bg.addSubview(lockDot)
        p.contentView = bg
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
/// view redraw: the window server only recomposites 18 small rectangles. 30 updates a second
/// look as smooth as 60 for this motion, at half the wake-ups.
final class WaveView: NSView {
    static let fps = 30.0
    var mode: RecordingOverlay.Mode = .recording { didSet { if mode != oldValue { recolor() } } }
    private let count = 18
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

    private func recolor() {
        let c = mode == .transcribing ? NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.35, alpha: 0.95) : .white
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for b in bars { b.backgroundColor = c.cgColor }
        CATransaction.commit()
    }

    private func layoutBars() {
        let w = bounds.width, h = bounds.height
        let gap: CGFloat = 3
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
