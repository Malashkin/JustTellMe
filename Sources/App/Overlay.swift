import Cocoa

/// Floating pill at the bottom of the screen: live waveform while recording,
/// a travelling wave while transcribing. Never takes focus, so ⌘V still lands
/// in the app the user was typing in.
final class RecordingOverlay {
    enum Mode { case hidden, recording, transcribing }

    private let size = NSSize(width: 168, height: 44)
    private var panel: NSPanel?
    private let wave = WaveView()
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?

    func show(_ mode: Mode) {
        hideWork?.cancel()
        switch mode {
        case .hidden: hide(); return
        case .recording: wave.mode = .recording; wave.reset()
        case .transcribing: wave.mode = .transcribing
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
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.wave.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    func push(level: Float) { wave.push(level) }

    /// Debug: write the pill as PNG (used by --demo-overlay to check the look without screen recording).
    func snapshot(to url: URL) {
        guard let v = panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) {
                guard self?.hideWork?.isCancelled == false else { return }
                p.orderOut(nil)
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

private final class WaveView: NSView {
    var mode: RecordingOverlay.Mode = .recording
    private let count = 18
    private var levels: [CGFloat]
    private var target: CGFloat = 0
    private var phase: CGFloat = 0

    override init(frame: NSRect) {
        levels = Array(repeating: 0, count: count)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset() { levels = Array(repeating: 0, count: count); target = 0 }

    func push(_ rms: Float) {
        // Speech RMS is ~0.01–0.2; map to 0…1 on a log-ish curve so quiet voices still move.
        let v = CGFloat(min(1, max(0, (log10(max(rms, 1e-4)) + 3.2) / 2.2)))
        target = max(target * 0.6, v)
    }

    func tick() {
        phase += 0.12
        if mode == .recording {
            levels.removeFirst()
            let jitter = CGFloat.random(in: 0.75...1.0)
            levels.append(target * jitter)
            target *= 0.88
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let w = bounds.width, h = bounds.height
        let gap: CGFloat = 3
        let barW = (w - gap * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            let amp: CGFloat
            let color: NSColor
            switch mode {
            case .transcribing:
                amp = 0.25 + 0.35 * (0.5 + 0.5 * sin(phase - CGFloat(i) * 0.45))
                color = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.35, alpha: 0.95)
            default:
                // Centre-weighted so the shape reads as a voice waveform, with a small idle pulse.
                let centre = 1 - abs(CGFloat(i) - CGFloat(count - 1) / 2) / CGFloat(count) * 0.9
                amp = max(0.12 + 0.04 * sin(phase + CGFloat(i) * 0.6), levels[i] * centre)
                color = .white
            }
            let bh = max(barW, h * amp)
            let r = NSRect(x: CGFloat(i) * (barW + gap), y: (h - bh) / 2, width: barW, height: bh)
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
