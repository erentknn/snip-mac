import AppKit

enum Clipboard {
    private static var lastChangeCount: Int?

    static func copy(_ rep: NSBitmapImageRep) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        lastChangeCount = pasteboard.changeCount
    }

    /// Clears the clipboard only if it still holds the last image Snip put there.
    static func clearIfOurs() {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == lastChangeCount {
            pasteboard.clearContents()
            lastChangeCount = nil
        }
    }
}
