import AppKit
import UniformTypeIdentifiers

enum Tool: Int, CaseIterable {
    case pen, highlighter, arrow, rectangle, crop

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .crop: return "crop"
        }
    }

    var label: String {
        switch self {
        case .pen: return "Pen (1)"
        case .highlighter: return "Highlighter (2)"
        case .arrow: return "Arrow (3)"
        case .rectangle: return "Rectangle (4)"
        case .crop: return "Crop (5)"
        }
    }
}

/// A markup stroke, in image point coordinates (origin bottom-left).
struct Annotation {
    enum Shape {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
    }

    var shape: Shape
    var color: NSColor
    var width: CGFloat

    func draw() {
        switch shape {
        case .pen(let points):
            color.setStroke()
            polyline(points).stroke()
        case .highlighter(let points):
            color.withAlphaComponent(0.4).setStroke()
            polyline(points).stroke()
        case .arrow(let from, let to):
            drawArrow(from: from, to: to)
        case .rectangle(let rect):
            color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = width
            path.lineJoinStyle = .miter
            path.stroke()
        }
    }

    private func polyline(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = points.first else { return path }
        path.move(to: first)
        // A single click still leaves a dot.
        for point in points.count == 1 ? points : Array(points.dropFirst()) {
            path.line(to: point)
        }
        return path
    }

    private func drawArrow(from: CGPoint, to: CGPoint) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0.5 else { return }
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = min(max(width * 4, 12), length)
        let spread = CGFloat.pi / 7
        func point(_ distance: CGFloat, _ theta: CGFloat) -> CGPoint {
            CGPoint(x: to.x - distance * cos(theta), y: to.y - distance * sin(theta))
        }

        color.set()
        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: point(head * 0.8, angle))
        shaft.stroke()

        let tip = NSBezierPath()
        tip.move(to: to)
        tip.line(to: point(head, angle - spread))
        tip.line(to: point(head, angle + spread))
        tip.close()
        tip.fill()
    }
}

enum ImageOps {
    /// Burns the annotations into a new bitmap at the original pixel resolution.
    static func flatten(_ rep: NSBitmapImageRep, _ annotations: [Annotation]) -> NSBitmapImageRep {
        guard !annotations.isEmpty,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return rep }
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        annotations.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    static func crop(_ rep: NSBitmapImageRep, to rect: CGRect) -> NSBitmapImageRep? {
        guard let cg = rep.cgImage else { return nil }
        let sx = CGFloat(rep.pixelsWide) / rep.size.width
        let sy = CGFloat(rep.pixelsHigh) / rep.size.height
        // CGImage pixel space has its origin at the top-left.
        let pixelRect = CGRect(x: rect.minX * sx, y: (rep.size.height - rect.maxY) * sy,
                               width: rect.width * sx, height: rect.height * sy).integral
        guard let cropped = cg.cropping(to: pixelRect) else { return nil }
        let out = NSBitmapImageRep(cgImage: cropped)
        out.size = CGSize(width: CGFloat(cropped.width) / sx, height: CGFloat(cropped.height) / sy)
        return out
    }
}

// MARK: - Canvas

final class CanvasView: NSView {
    var image: NSBitmapImageRep {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var tool: Tool = .pen
    var color: NSColor = .systemRed
    var strokeWidth: CGFloat = 4

    /// Called with the new annotation before it is committed, so the owner can record undo state.
    var onAddAnnotation: ((Annotation) -> Void)?
    var onCrop: ((CGRect) -> Void)?
    var onToolKey: ((Tool) -> Void)?

    private var inProgress: Annotation?
    private var dragStart: CGPoint = .zero
    private var cropRect: CGRect?

    init(image: NSBitmapImageRep) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var imageRect: CGRect {
        let available = bounds.insetBy(dx: 20, dy: 20)
        let scale = max(min(available.width / image.size.width, available.height / image.size.height, 1), 0.01)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private var scale: CGFloat { imageRect.width / image.size.width }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        return CGPoint(x: (p.x - rect.minX) / scale, y: (p.y - rect.minY) / scale)
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let rect = imageRect
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
        NSColor.white.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: scale)
        transform.concat()

        annotations.forEach { $0.draw() }
        inProgress?.draw()

        if let crop = cropRect {
            let dim = NSBezierPath(rect: CGRect(origin: .zero, size: image.size))
            dim.append(NSBezierPath(rect: crop))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            dim.fill()
            let border = NSBezierPath(rect: crop)
            border.lineWidth = 1.5 / scale
            border.setLineDash([6 / scale, 4 / scale], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(for: event)
        dragStart = p
        switch tool {
        case .pen: inProgress = Annotation(shape: .pen([p]), color: color, width: strokeWidth)
        case .highlighter: inProgress = Annotation(shape: .highlighter([p]), color: color, width: strokeWidth * 4)
        case .arrow: inProgress = Annotation(shape: .arrow(p, p), color: color, width: strokeWidth)
        case .rectangle: inProgress = Annotation(shape: .rectangle(CGRect(origin: p, size: .zero)), color: color, width: strokeWidth)
        case .crop: cropRect = CGRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(for: event)
        let rect = CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                          width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y))
        switch inProgress?.shape {
        case .pen(let points): inProgress?.shape = .pen(points + [p])
        case .highlighter(let points): inProgress?.shape = .highlighter(points + [p])
        case .arrow: inProgress?.shape = .arrow(dragStart, p)
        case .rectangle: inProgress?.shape = .rectangle(rect)
        case nil: break
        }
        if tool == .crop {
            cropRect = rect.intersection(CGRect(origin: .zero, size: image.size))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let crop = cropRect {
            cropRect = nil
            needsDisplay = true
            if crop.width >= 4, crop.height >= 4 { onCrop?(crop) }
        }
        if let annotation = inProgress {
            inProgress = nil
            onAddAnnotation?(annotation)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let digit = Int(event.charactersIgnoringModifiers ?? ""), let tool = Tool(rawValue: digit - 1) {
            onToolKey?(tool)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Window

private final class EditorWindow: NSWindow {
    weak var controller: EditorController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased(),
              let controller else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, flags.contains(.shift)) {
        case ("z", false): controller.undo()
        case ("z", true): controller.redo()
        case ("c", _): controller.copyImage()
        case ("s", _): controller.save()
        case ("\u{7F}", _): controller.delete() // ⌘⌫
        case ("w", _): performClose(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class EditorController: NSObject, NSWindowDelegate {
    private struct Snapshot {
        var image: NSBitmapImageRep
        var annotations: [Annotation]
    }

    var onClose: ((EditorController) -> Void)?
    var onDelete: (() -> Void)?

    private let name: String
    private let fileURL: URL?
    private let canvas: CanvasView
    private let window: EditorWindow
    private var toolControl: NSSegmentedControl!
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var shareButton: NSButton!
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private var current: Snapshot {
        get { Snapshot(image: canvas.image, annotations: canvas.annotations) }
        set {
            canvas.image = newValue.image
            canvas.annotations = newValue.annotations
        }
    }

    init(shot: Shot) {
        name = shot.name
        fileURL = shot.fileURL
        let rep = shot.rep
        canvas = CanvasView(image: rep)
        window = EditorWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init()

        window.controller = self
        window.delegate = self
        window.title = name
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)

        canvas.onAddAnnotation = { [weak self] annotation in
            self?.mutate { $0.annotations.append(annotation) }
        }
        canvas.onCrop = { [weak self] rect in
            self?.mutate { snapshot in
                let flat = ImageOps.flatten(snapshot.image, snapshot.annotations)
                if let cropped = ImageOps.crop(flat, to: rect) {
                    snapshot = Snapshot(image: cropped, annotations: [])
                }
            }
        }
        canvas.onToolKey = { [weak self] tool in self?.select(tool) }

        buildLayout()
        sizeWindow(for: rep.size)
        updateButtons()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Layout

    private func buildLayout() {
        toolControl = NSSegmentedControl(images: Tool.allCases.map { symbol($0.symbol, $0.label) },
                                         trackingMode: .selectOne, target: self, action: #selector(toolChanged))
        for tool in Tool.allCases {
            toolControl.setToolTip(tool.label, forSegment: tool.rawValue)
        }
        toolControl.selectedSegment = Tool.pen.rawValue

        let colorWell = NSColorWell(style: .minimal)
        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Color"

        let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        widthPopup.addItems(withTitles: ["Thin", "Medium", "Thick"])
        widthPopup.selectItem(at: 1)
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        widthPopup.toolTip = "Stroke width"

        undoButton = button("arrow.uturn.backward", "Undo (⌘Z)", #selector(undo))
        redoButton = button("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redo))
        let deleteButton = button("trash", "Delete screenshot (⌘⌫)", #selector(delete))
        shareButton = button("square.and.arrow.up", "Share", #selector(share))
        let saveButton = button("square.and.arrow.down", "Save As… (⌘S)", #selector(save))
        let copyButton = NSButton(title: "Copy", image: symbol("doc.on.doc", "Copy"),
                                  target: self, action: #selector(copyImage))
        copyButton.toolTip = "Copy to clipboard (⌘C)"
        copyButton.keyEquivalent = ""

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let bar = NSStackView(views: [toolControl, colorWell, widthPopup, undoButton, redoButton,
                                      spacer, deleteButton, shareButton, saveButton, copyButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.setCustomSpacing(16, after: widthPopup)

        let container = NSView()
        for view in [bar, canvas] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
    }

    private func sizeWindow(for imageSize: CGSize) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(imageSize.width + 40, 560), screen.width * 0.85)
        let height = min(max(imageSize.height + 40 + 46, 360), screen.height * 0.85)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    private func button(_ symbolName: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: symbol(symbolName, tooltip), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        return button
    }

    // MARK: Actions

    private func select(_ tool: Tool) {
        canvas.tool = tool
        toolControl.selectedSegment = tool.rawValue
    }

    @objc private func toolChanged() {
        canvas.tool = Tool(rawValue: toolControl.selectedSegment) ?? .pen
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.color = sender.color
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        canvas.strokeWidth = [2, 4, 8][max(sender.indexOfSelectedItem, 0)]
    }

    @objc func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
        didChange()
    }

    @objc func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
        didChange()
    }

    @objc func copyImage() {
        Clipboard.copy(flattened())
    }

    @objc func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(name).png"
        panel.directoryURL = AppDelegate.screenshotsFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self,
                  let data = self.flattened().representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: self.window)
            }
        }
    }

    /// Moves the auto-saved file to the Trash, drops it from the clipboard, and closes the window.
    @objc func delete() {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.recycle([fileURL]) { [weak self] _, error in
                if let error, let window = self?.window {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
        Clipboard.clearIfOurs()
        onDelete?()
        window.close()
    }

    @objc private func share() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        guard let data = flattened().representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }

    // MARK: State

    private func mutate(_ change: (inout Snapshot) -> Void) {
        undoStack.append(current)
        redoStack.removeAll()
        var snapshot = current
        change(&snapshot)
        current = snapshot
        didChange()
    }

    /// Like the Windows Snipping Tool, every edit is copied to the clipboard right away.
    private func didChange() {
        updateButtons()
        Clipboard.copy(flattened())
    }

    private func updateButtons() {
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
    }

    private func flattened() -> NSBitmapImageRep {
        ImageOps.flatten(canvas.image, canvas.annotations)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
