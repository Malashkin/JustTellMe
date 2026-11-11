import Cocoa

/// Is there a text field to paste into? Asked through Accessibility right after pasting.
/// It errs towards `.unknown`: a wrong "no field" would pop up a card for nothing, a missed one
/// only means the text is still in the feed on Главная, as before.
enum FocusedField: Equatable {
    case text, none, unknown

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
    /// Clearly not a place for text: a file list, the desktop, a button, a web page with no field focused.
    static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXButton", "AXImage", "AXScrollArea",
        "AXSplitGroup", "AXWindow", "AXToolbar", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider",
        "AXTabGroup", "AXWebArea", "AXStaticText", "AXGroup", "AXApplication",
    ]

    /// The decision, apart from the Accessibility calls (for tests).
    ///  - error: result of asking the app for its focused element
    ///  - editable: the element has an editable ancestor, or a settable value and text selection
    ///  - lazyTree: Chromium/Electron/Firefox build their accessibility tree only on demand, so a
    ///    window or group there may well hide a text field
    ///  - isFinder: nothing focused in Finder = the desktop
    static func classify(error: AXError, role: String?, editable: Bool, lazyTree: Bool, isFinder: Bool) -> FocusedField {
        switch error {
        case .success:
            if let role, textRoles.contains(role) { return .text }
            if editable { return .text }
            if let role, nonTextRoles.contains(role), !lazyTree { return .none }
            return .unknown
        case .noValue:
            return isFinder ? .none : .unknown
        default:
            return .unknown
        }
    }

    private static let lazyTreeBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "ru.yandex.desktop.yandex-browser",
        "org.mozilla.firefox", "org.chromium.Chromium",
    ]

    static func hasLazyTree(bundleID: String?, bundleURL: URL?) -> Bool {
        if lazyTreeBundles.contains(bundleID ?? "") { return true }
        guard let fw = bundleURL?.appendingPathComponent("Contents/Frameworks") else { return false }
        return ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains {
            FileManager.default.fileExists(atPath: fw.appendingPathComponent($0).path)
        }
    }

    /// Ask the app what is focused (blocks for up to ~0.5 s: call off the main thread).
    static func current(in app: NSRunningApplication?) -> FocusedField {
        guard AXIsProcessTrusted(), let app else { return .unknown }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXFocusedUIElementAttribute as CFString, &focused)
        var role: String?
        var editable = false
        if err == .success, let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() {
            let e = f as! AXUIElement
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r) == .success { role = r as? String }
            var anc: CFTypeRef?
            var valueSettable = DarwinBoolean(false), rangeSettable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &valueSettable)
            AXUIElementIsAttributeSettable(e, kAXSelectedTextRangeAttribute as CFString, &rangeSettable)
            editable = AXUIElementCopyAttributeValue(e, "AXEditableAncestor" as CFString, &anc) == .success
                || (valueSettable.boolValue && rangeSettable.boolValue)
        }
        return classify(error: err, role: role, editable: editable, lazyTree: hasLazyTree(bundleID: app.bundleIdentifier, bundleURL: app.bundleURL),
                        isFinder: app.bundleIdentifier == "com.apple.finder")
    }
}

/// Small card above the Dock when the text was most likely pasted nowhere: shows it with a
/// «Скопировать» button. Never takes focus.
final class NoFieldCard: NSObject {
    private var panel: NSPanel?
    private let title = NSTextField(labelWithString: "Курсор не в поле ввода?")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: "Скопировать", target: nil, action: nil)
    private var text = ""
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 380, height: 132)

    func show(_ text: String) {
        self.text = text
        let p = panel ?? make()
        panel = p
        body.stringValue = text
        copyButton.title = "Скопировать"
        copyButton.isEnabled = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28)) }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        hide(after: 12)
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

    /// Debug: write the card as PNG (--demo-card).
    func snapshot(to url: URL) {
        guard let v = panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.title = "Скопировано ✓"
        copyButton.isEnabled = false
        hide(after: 0.8)
    }

    @objc private func close() { hide(after: 0) }

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

        // Fixed layout (the panel has a fixed size): title, hint, two lines of text, buttons.
        let w = size.width - 28
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 14, y: size.height - 30, width: w, height: 18)
        let sub = NSTextField(labelWithString: "Если текст не появился, скопируйте его:")
        sub.textColor = .secondaryLabelColor
        sub.font = .systemFont(ofSize: 11)
        sub.frame = NSRect(x: 14, y: size.height - 47, width: w, height: 15)
        body.font = .systemFont(ofSize: 12)
        body.maximumNumberOfLines = 2
        body.cell?.truncatesLastVisibleLine = true
        body.lineBreakMode = .byWordWrapping
        body.frame = NSRect(x: 14, y: 46, width: w, height: 34)
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r" // drawn as the default (accent) button
        copyButton.frame = NSRect(x: size.width - 14 - 130, y: 8, width: 130, height: 30)
        let closeButton = NSButton(title: "Закрыть", target: self, action: #selector(close))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: copyButton.frame.minX - 100, y: 8, width: 100, height: 30)
        for v in [title, sub, body, closeButton, copyButton] as [NSView] { bg.addSubview(v) }
        p.contentView = bg
        return p
    }
}
