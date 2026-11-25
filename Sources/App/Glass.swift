import Cocoa

/// The "Liquid Glass" look: the desktop shows through a blurred window, content sits on translucent
/// panels with a light edge, and controls are capsules. Built from NSVisualEffectView and layers,
/// so it works on macOS 13+ and follows Light/Dark mode and "Reduce transparency".
enum Glass {
    /// Translucent fill of a panel or card.
    static let fill = dynamic(light: NSColor(white: 1, alpha: 0.46), dark: NSColor(white: 1, alpha: 0.07))
    /// A brighter capsule: the selected sidebar row, glass buttons.
    static let raised = dynamic(light: NSColor(white: 1, alpha: 0.82), dark: NSColor(white: 1, alpha: 0.16))
    /// The light edge around glass.
    static let edge = dynamic(light: NSColor(white: 1, alpha: 0.85), dark: NSColor(white: 1, alpha: 0.16))
    /// Separators between rows inside a card.
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.07))
    /// "Done" status capsule.
    static let doneFill = Brick.green.withAlphaComponent(0.2)
    static let doneText = Brick.greenText

    /// The main action: tinted glass, not a solid accent slab.
    static let accentFill = Brick.blue.withAlphaComponent(0.16)
    static let accentText = Brick.blueText

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }

    /// A rounded-rect mask that stretches with the view: what clips a behind-window blur to a shape.
    static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    /// The blurred desktop behind a window or a floating panel. `radius` clips it (nil: the window does).
    static func backdrop(_ material: NSVisualEffectView.Material = .fullScreenUI, radius: CGFloat? = nil) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        if let r = radius {
            v.maskImage = mask(radius: r)
            let edge = GlassView(radius: r, filled: false)
            edge.frame = v.bounds
            edge.autoresizingMask = [.width, .height]
            v.addSubview(edge)
        }
        return v
    }

    /// A borderless search field inside a glass capsule.
    static func searchCapsule(_ field: NSSearchField, width: CGFloat? = nil) -> NSView {
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        let box = GlassView(radius: 16, raised: true)
        box.capsule = true
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 32),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        if let w = width { box.widthAnchor.constraint(equalToConstant: w).isActive = true }
        return box
    }

    /// Wrap a view in a glass card (a list, the feed).
    static func card(_ content: NSView, inset: CGFloat = 6) -> GlassView {
        let card = GlassView(radius: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
        ])
        return card
    }
}

/// The interface palette: bright toy-brick blue, yellow, green and orange, and no red.
/// `…Text` variants are darker in Light mode and lighter in Dark mode, so small text stays readable.
enum Brick {
    static let blue = NSColor(srgbRed: 0, green: 0.424, blue: 0.718, alpha: 1)        // #006CB7
    static let yellow = NSColor(srgbRed: 1, green: 0.804, blue: 0.012, alpha: 1)      // #FFCD03
    static let green = NSColor(srgbRed: 0, green: 0.651, blue: 0.314, alpha: 1)       // #00A650
    static let orange = NSColor(srgbRed: 0.961, green: 0.490, blue: 0.125, alpha: 1)  // #F57D20

    static let blueText = Glass.dynamic(light: blue, dark: NSColor(srgbRed: 0.36, green: 0.66, blue: 1, alpha: 1))
    static let greenText = Glass.dynamic(light: NSColor(srgbRed: 0, green: 0.48, blue: 0.23, alpha: 1),
                                         dark: NSColor(srgbRed: 0.36, green: 0.85, blue: 0.55, alpha: 1))
    static let orangeText = Glass.dynamic(light: NSColor(srgbRed: 0.70, green: 0.32, blue: 0, alpha: 1),
                                          dark: NSColor(srgbRed: 1, green: 0.66, blue: 0.33, alpha: 1))
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSView {
    /// A dynamic color as a CGColor for this view's appearance (layers don't resolve NSColor themselves).
    func cg(_ c: NSColor) -> CGColor {
        var out = c.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }
}

/// A translucent rounded panel with a light edge. `capsule` keeps the corners at half the height.
class GlassView: NSView {
    var radius: CGFloat { didSet { needsDisplay = true } }
    var capsule = false { didSet { needsLayout = true } }
    var tint: NSColor? { didSet { needsDisplay = true } }
    private let filled: Bool
    private let raised: Bool

    init(radius: CGFloat, filled: Bool = true, raised: Bool = false) {
        self.radius = radius
        self.filled = filled
        self.raised = raised
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        if capsule { layer?.cornerRadius = bounds.height / 2 }
    }

    override func updateLayer() {
        guard let l = layer else { return }
        l.cornerRadius = capsule ? bounds.height / 2 : radius
        l.borderWidth = 1
        l.borderColor = cg(Glass.edge)
        l.backgroundColor = filled ? cg(tint ?? (raised ? Glass.raised : Glass.fill)) : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // An unfilled edge is decoration over other views: never take their clicks.
        filled ? super.hitTest(point) : nil
    }
}

/// A capsule button: glass, the accent color (`prominent`), or red text (`destructive`).
final class CapsuleButton: NSButton {
    enum Style { case glass, prominent, destructive, done, plain }
    var style: Style { didSet { restyle() } }
    var height: CGFloat = 30 { didSet { invalidateIntrinsicContentSize() } }
    var padding: CGFloat = 14 { didSet { invalidateIntrinsicContentSize() } }
    var fontSize: CGFloat = 13 { didSet { restyle() } }
    /// Show only `image`; the title stays for tooltips and VoiceOver.
    var iconOnly = false { didSet { imagePosition = iconOnly ? .imageOnly : .noImage; restyle() } }

    init(_ title: String, style: Style = .glass, target: AnyObject? = nil, action: Selector? = nil) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.borderWidth = 1
        setButtonType(.momentaryPushIn)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var title: String { didSet { restyle() } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.45 } }

    override var intrinsicContentSize: NSSize {
        if iconOnly { return NSSize(width: height + 12, height: height) }
        let w = attributedTitle.size().width
        return NSSize(width: ceil(w) + padding * 2, height: height)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        let a = alphaValue
        alphaValue = a * 0.7
        super.mouseDown(with: event)   // tracks until mouse-up
        alphaValue = a
    }

    private var restyling = false

    private func restyle() {
        guard !restyling else { return }
        restyling = true
        defer { restyling = false }
        let text: NSColor, fill: NSColor, edge: NSColor
        switch style {
        case .glass: text = .labelColor; fill = Glass.raised; edge = Glass.edge
        case .prominent: text = Glass.accentText; fill = Glass.accentFill; edge = Glass.edge
        case .destructive: text = Brick.orangeText; fill = Glass.raised; edge = Glass.edge
        case .done: text = Glass.doneText; fill = Glass.doneFill; edge = .clear
        case .plain: text = .secondaryLabelColor; fill = .clear; edge = .clear
        }
        layer?.backgroundColor = cg(fill)
        layer?.borderColor = cg(edge)
        contentTintColor = style == .plain ? .secondaryLabelColor : text
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        // An icon-only capsule keeps its title (VoiceOver, tooltips); `.imageOnly` stops it being drawn.
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: style == .glass || style == .plain ? .regular : .semibold),
            .foregroundColor: text, .paragraphStyle: para,
        ])
        if iconOnly { imagePosition = .imageOnly }   // setting the title resets it
        invalidateIntrinsicContentSize()
    }
}

/// Table rows whose selection is a glass capsule instead of the solid accent bar.
final class CapsuleRowView: NSTableRowView {
    var inset: CGFloat = 4

    override var isEmphasized: Bool { get { false } set {} }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: inset, dy: 1.5)
        let radius = min(r.height / 2, 14)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        Glass.raised.setFill()
        path.fill()
        Glass.edge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A segmented control as a glass capsule: the chosen segment is a raised capsule inside it.
final class CapsuleSegments: GlassView {
    var onChange: ((Int) -> Void)?
    private var buttons: [CapsuleButton] = []
    var selected = 0 { didSet { restyle() } }

    /// `symbols`: SF Symbol names to show instead of the titles (the titles become tooltips and labels).
    init(_ titles: [String], symbols: [String]? = nil) {
        super.init(radius: 17)
        capsule = true
        let stack = NSStackView()
        stack.spacing = 2
        for (i, t) in titles.enumerated() {
            let b = CapsuleButton(t, style: .plain, target: self, action: #selector(pick(_:)))
            if let name = symbols?[i] {
                b.image = NSImage(systemSymbolName: name, accessibilityDescription: t)
                b.iconOnly = true
                b.toolTip = t
                b.setAccessibilityLabel(t)
            }
            b.tag = i
            b.height = 28
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pick(_ b: NSButton) {
        guard b.tag != selected else { return }
        selected = b.tag
        onChange?(selected)
    }

    private func restyle() {
        for b in buttons { b.style = b.tag == selected ? .glass : .plain }
    }
}

/// A pop-up menu inside a glass capsule.
func glassPopup(_ p: NSPopUpButton) -> NSView {
    p.isBordered = false
    p.font = .systemFont(ofSize: 13)
    let box = GlassView(radius: 15, raised: true)
    box.capsule = true
    p.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(p)
    NSLayoutConstraint.activate([
        box.heightAnchor.constraint(equalToConstant: 30),
        p.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
        p.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
        p.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])
    return box
}
