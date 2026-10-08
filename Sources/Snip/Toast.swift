import AppKit

/// Windows-style "Screenshot copied to clipboard" toast in the bottom-right corner.
final class ToastController {
    static let shared = ToastController()

    private static let displayDuration: TimeInterval = 6

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(image: NSImage, onClick: @escaping () -> Void) {
        dismiss(animated: false)

        let width: CGFloat = 360
        let padding: CGFloat = 12
        let textHeight: CGFloat = 38
        let thumbWidth = width - padding * 2
        let aspect = image.size.height / max(image.size.width, 1)
        let thumbHeight = min(max(thumbWidth * aspect, 60), 200)
        let height = padding + thumbHeight + 10 + textHeight + padding

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = NSRect(x: visible.maxX - width - 16, y: visible.minY + 16, width: width, height: height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = ToastView(frame: NSRect(origin: .zero, size: frame.size))
        view.onClick = { [weak self] in
            self?.dismiss(animated: true)
            onClick()
        }
        view.onClose = { [weak self] in self?.dismiss(animated: true) }
        view.onHover = { [weak self] hovering in
            if hovering { self?.dismissTimer?.invalidate() } else { self?.scheduleDismiss() }
        }

        let background = NSVisualEffectView(frame: view.bounds)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        view.addSubview(background)

        let imageView = NSImageView(frame: NSRect(x: padding, y: height - padding - thumbHeight,
                                                  width: thumbWidth, height: thumbHeight))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        view.addSubview(imageView)

        let title = NSTextField(labelWithString: "Screenshot copied to clipboard")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: padding, y: padding + 18, width: thumbWidth - 24, height: 18)
        view.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Click here to mark up and share the image")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: padding, y: padding, width: thumbWidth - 24, height: 16)
        view.addSubview(subtitle)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")!,
                             target: view, action: #selector(ToastView.closeClicked))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: width - padding - 20, y: padding + 18, width: 20, height: 20)
        view.addSubview(close)
        view.closeButton = close

        panel.contentView = view
        panel.alphaValue = 0
        panel.setFrame(frame.offsetBy(dx: 0, dy: -12), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }

        self.panel = panel
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.displayDuration, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        self.panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        } else {
            panel.orderOut(nil)
        }
    }
}

private final class ToastView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    weak var closeButton: NSButton?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Route every click to the toast itself, except clicks on the close button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let closeButton, hit === closeButton || hit.isDescendant(of: closeButton) { return hit }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func mouseDown(with event: NSEvent) {}

    @objc func closeClicked() { onClose?() }
}
