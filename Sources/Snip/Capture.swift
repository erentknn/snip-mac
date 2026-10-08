import AppKit
import ScreenCaptureKit

/// One display, frozen the moment a capture starts. Selection happens on this image,
/// so menus, tooltips and hover states stay exactly as they were.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage

    var rep: NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = screen.frame.size
        return rep
    }
}

struct WindowTarget {
    let window: SCWindow
    /// Global Cocoa coordinates (origin at the bottom-left of the primary display).
    let frame: NSRect
}

@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private(set) var mode: CaptureMode = .region
    private(set) var hoveredWindow: WindowTarget?

    private var isActive = false
    private var completion: ((NSBitmapImageRep) -> Void)?
    private var frozenScreens: [FrozenScreen] = []
    private var windows: [WindowTarget] = []
    private var overlays: [OverlayWindow] = []
    private var previousApp: NSRunningApplication?

    func start(_ mode: CaptureMode, completion: @escaping (NSBitmapImageRep) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.mode = mode
        self.completion = completion
        ToastController.shared.dismiss(animated: false)
        Task { await begin() }
    }

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

            if mode == .fullScreen {
                let mouse = NSEvent.mouseLocation
                guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
                      let frozen = try await Self.freeze(screen, content) else { return end() }
                return finish(frozen.rep)
            }

            for screen in NSScreen.screens {
                if let frozen = try await Self.freeze(screen, content) {
                    frozenScreens.append(frozen)
                }
            }
            windows = Self.windowTargets(content)
            showOverlays()
        } catch {
            end()
            Self.showPermissionAlert(error)
        }
    }

    // MARK: Overlay events

    func toggleMode() {
        mode = mode == .window ? .region : .window
        updateHover(at: NSEvent.mouseLocation)
        overlays.forEach { $0.overlayView.modeChanged() }
    }

    func updateHover(at point: NSPoint) {
        let target = mode == .window ? windows.first { $0.frame.contains(point) } : nil
        guard target?.window.windowID != hoveredWindow?.window.windowID else { return }
        hoveredWindow = target
        overlays.forEach { $0.overlayView.needsDisplay = true }
    }

    func cancel() { end() }

    func selectRegion(_ rect: NSRect, in frozen: FrozenScreen) {
        guard let rep = ImageOps.crop(frozen.rep, to: rect) else { return end() }
        finish(rep)
    }

    func selectHoveredWindow() {
        guard let target = hoveredWindow else { return }
        let fallback = cropFromFrozen(target.frame)
        closeOverlays()
        Task {
            // Capture the window on its own, so overlapping windows don't get in the way.
            if let rep = try? await Self.capture(target.window) {
                finish(rep)
            } else if let fallback {
                finish(fallback)
            } else {
                end()
            }
        }
    }

    // MARK: Lifecycle

    private func showOverlays() {
        previousApp = NSWorkspace.shared.frontmostApplication
        overlays = frozenScreens.map { OverlayWindow(frozen: $0, controller: self) }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        overlays.forEach { $0.orderFrontRegardless() }
        (overlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? overlays.first)?.makeKey()
        updateHover(at: mouse)
    }

    private func closeOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func finish(_ rep: NSBitmapImageRep) {
        let completion = completion
        end()
        completion?(rep)
    }

    private func end() {
        closeOverlays()
        isActive = false
        completion = nil
        frozenScreens = []
        windows = []
        hoveredWindow = nil
    }

    private func cropFromFrozen(_ frame: NSRect) -> NSBitmapImageRep? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let frozen = frozenScreens.first(where: { $0.screen.frame.contains(center) }) else { return nil }
        let origin = frozen.screen.frame.origin
        let local = frame.intersection(frozen.screen.frame).offsetBy(dx: -origin.x, dy: -origin.y)
        return ImageOps.crop(frozen.rep, to: local)
    }

    // MARK: ScreenCaptureKit

    private static func freeze(_ screen: NSScreen, _ content: SCShareableContent) async throws -> FrozenScreen? {
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
        config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return FrozenScreen(screen: screen, image: image)
    }

    private static func capture(_ window: SCWindow) async throws -> NSBitmapImageRep {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep
    }

    /// Normal app windows, front to back.
    private static func windowTargets(_ content: SCShareableContent) -> [WindowTarget] {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        // CGWindow bounds have a top-left origin; Cocoa's is the bottom-left of the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let window = byID[number],
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowTarget(window: window, frame: frame)
        }
    }

    private static func showPermissionAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Snip can't capture the screen"
        alert.informativeText = """
            Allow Snip in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Snip.

            (\(error.localizedDescription))
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Overlay

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(frozen: FrozenScreen, controller: CaptureController) {
        overlayView = OverlayView(frozen: frozen, controller: controller)
        super.init(contentRect: frozen.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        // The frozen screenshot sits in a static layer; the overlay view only draws on top of it.
        let background = NSView(frame: NSRect(origin: .zero, size: frozen.screen.frame.size))
        background.wantsLayer = true
        background.layer?.contents = frozen.image
        background.layer?.contentsGravity = .resize
        overlayView.frame = background.bounds
        overlayView.autoresizingMask = [.width, .height]
        background.addSubview(overlayView)
        contentView = background
        setFrame(frozen.screen.frame, display: false)
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }

    // Cover the menu bar and Dock too.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class OverlayView: NSView {
    private let frozen: FrozenScreen
    private unowned let controller: CaptureController
    private var dragStart: NSPoint?
    private var selection: NSRect?
    private var mouse: NSPoint?

    init(frozen: FrozenScreen, controller: CaptureController) {
        self.frozen = frozen
        self.controller = controller
        super.init(frame: .zero)
        let local = NSEvent.mouseLocation
        if frozen.screen.frame.contains(local) {
            mouse = NSPoint(x: local.x - frozen.screen.frame.minX, y: local.y - frozen.screen.frame.minY)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func modeChanged() {
        dragStart = nil
        selection = nil
        needsDisplay = true
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        // Keyboard input (Space/Esc) goes to whichever screen the pointer is on.
        if window?.isKeyWindow == false { window?.makeKey() }
        NSCursor.crosshair.set()
        mouse = clamped(convert(event.locationInWindow, from: nil))
        controller.updateHover(at: NSEvent.mouseLocation)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard controller.mode == .region else { return }
        dragStart = clamped(convert(event.locationInWindow, from: nil))
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = clamped(convert(event.locationInWindow, from: nil))
        mouse = p
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if controller.mode == .window {
            controller.selectHoveredWindow()
            return
        }
        dragStart = nil
        if let selection, selection.width >= 3, selection.height >= 3 {
            controller.selectRegion(selection, in: frozen)
        } else {
            selection = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller.cancel() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller.cancel()     // Esc
        case 49: controller.toggleMode() // Space
        default: super.keyDown(with: event)
        }
    }

    private func clamped(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    // MARK: Drawing

    private var pixelScale: CGFloat { CGFloat(frozen.image.width) / bounds.width }

    override func draw(_ dirtyRect: NSRect) {
        let highlight: NSRect?
        if controller.mode == .window {
            let origin = frozen.screen.frame.origin
            highlight = controller.hoveredWindow.map { $0.frame.offsetBy(dx: -origin.x, dy: -origin.y) }
        } else {
            highlight = selection
        }

        let dim = NSBezierPath(rect: bounds)
        if let highlight {
            dim.append(NSBezierPath(rect: highlight))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        if let highlight {
            let border = NSBezierPath(rect: highlight.insetBy(dx: -0.5, dy: -0.5))
            if controller.mode == .window {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                highlight.fill()
                NSColor.controlAccentColor.setStroke()
                border.lineWidth = 3
            } else {
                NSColor.white.setStroke()
                border.lineWidth = 1
            }
            border.stroke()
            let size = "\(Int((highlight.width * pixelScale).rounded())) × \(Int((highlight.height * pixelScale).rounded()))"
            drawPill(size, centeredAt: NSPoint(x: highlight.midX, y: highlight.minY - 18))
        }

        if controller.mode == .region, let mouse {
            drawLoupe(at: mouse)
        }

        let hint = controller.mode == .region
            ? "Drag to capture  ·  Space: window mode  ·  Esc: cancel"
            : "Click a window to capture  ·  Space: region mode  ·  Esc: cancel"
        drawPill(hint, centeredAt: NSPoint(x: bounds.midX, y: bounds.maxY - 60))
    }

    /// A zoomed view of the pixels around the pointer, for precise selections.
    private func drawLoupe(at p: NSPoint) {
        let cells = 15
        let cellSize: CGFloat = 8
        let side = CGFloat(cells) * cellSize
        let image = frozen.image
        guard image.width > cells, image.height > cells else { return }

        let px = min(Int(p.x * pixelScale), image.width - 1)
        let py = min(Int((bounds.height - p.y) * pixelScale), image.height - 1) // top-left origin
        let ox = min(max(px - cells / 2, 0), image.width - cells)
        let oy = min(max(py - cells / 2, 0), image.height - cells)
        guard let pixels = image.cropping(to: CGRect(x: ox, y: oy, width: cells, height: cells)),
              let context = NSGraphicsContext.current else { return }

        var origin = NSPoint(x: p.x + 24, y: p.y - 24 - side)
        if origin.x + side > bounds.maxX { origin.x = p.x - 24 - side }
        if origin.y < bounds.minY + 30 { origin.y = p.y + 24 }
        let rect = NSRect(origin: origin, size: NSSize(width: side, height: side))
        let frame = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)

        context.saveGraphicsState()
        frame.addClip()
        context.cgContext.interpolationQuality = .none
        context.cgContext.draw(pixels, in: rect)
        let center = NSRect(x: rect.minX + CGFloat(px - ox) * cellSize,
                            y: rect.maxY - CGFloat(py - oy + 1) * cellSize,
                            width: cellSize, height: cellSize)
        NSColor.black.setStroke()
        NSBezierPath(rect: center.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: center).stroke()
        context.restoreGraphicsState()

        frame.lineWidth = 2
        NSColor.white.setStroke()
        frame.stroke()

        drawPill("\(px), \(py)", centeredAt: NSPoint(x: rect.midX, y: rect.minY - 14))
    }

    private func drawPill(_ text: String, centeredAt center: NSPoint) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        var rect = NSRect(x: center.x - size.width / 2 - 8, y: center.y - size.height / 2 - 4,
                          width: size.width + 16, height: size.height + 8)
        rect.origin.x = min(max(rect.minX, 4), bounds.maxX - rect.width - 4)
        rect.origin.y = min(max(rect.minY, 4), bounds.maxY - rect.height - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        string.draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 4))
    }
}
