import AppKit
import Carbon
import ServiceManagement

enum CaptureMode {
    case region, window, fullScreen
}

struct Shot {
    let rep: NSBitmapImageRep
    let name: String
    /// The auto-saved copy in the screenshots folder, if auto-save was on.
    let fileURL: URL?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let autoSaveKey = "autoSave"

    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var editors: [EditorController] = []
    private var lastShot: Shot?

    private var autoSaveItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var openLastItem: NSMenuItem!

    private var autoSave: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoSaveKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoSaveKey) }
    }

    nonisolated static var screenshotsFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshots", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.autoSaveKey: true])
        setUpStatusItem()
        setUpMainMenu()

        let mods = optionKey | shiftKey
        hotKeys = [
            HotKey(keyCode: kVK_ANSI_S, modifiers: mods) { [weak self] in self?.capture(.region) },
            HotKey(keyCode: kVK_ANSI_W, modifiers: mods) { [weak self] in self?.capture(.window) },
            HotKey(keyCode: kVK_ANSI_F, modifiers: mods) { [weak self] in self?.capture(.fullScreen) },
        ].compactMap { $0 }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Snip")
        icon?.isTemplate = true
        statusItem.button?.image = icon

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Capture Region", key: "s", action: #selector(captureRegion)))
        menu.addItem(item("Capture Window", key: "w", action: #selector(captureWindow)))
        menu.addItem(item("Capture Full Screen", key: "f", action: #selector(captureFullScreen)))
        menu.addItem(.separator())
        openLastItem = item("Open Last Screenshot", action: #selector(openLast))
        menu.addItem(openLastItem)
        menu.addItem(.separator())
        autoSaveItem = item("Auto-save to Pictures/Screenshots", action: #selector(toggleAutoSave))
        menu.addItem(autoSaveItem)
        menu.addItem(item("Open Screenshots Folder", action: #selector(openFolder)))
        launchAtLoginItem = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Snip", key: "q", action: #selector(quit), modifiers: .command))
        statusItem.menu = menu
    }

    private func item(_ title: String, key: String = "", action: Selector,
                      modifiers: NSEvent.ModifierFlags = [.option, .shift]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        autoSaveItem.state = autoSave ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        openLastItem.isEnabled = lastShot != nil
    }

    @objc private func captureRegion() { capture(.region) }
    @objc private func captureWindow() { capture(.window) }
    @objc private func captureFullScreen() { capture(.fullScreen) }

    @objc private func openLast() {
        guard let lastShot else { return }
        openEditor(lastShot)
    }

    @objc private func toggleAutoSave() { autoSave.toggle() }

    @objc private func openFolder() {
        let folder = Self.screenshotsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Capture

    func capture(_ mode: CaptureMode) {
        CaptureController.shared.start(mode) { [weak self] rep in
            self?.didCapture(rep)
        }
    }

    private func didCapture(_ rep: NSBitmapImageRep) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let thumbnail = NSImage(size: rep.size)
        thumbnail.addRepresentation(rep)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(formatter.string(from: Date()))"

        Clipboard.copy(rep)
        var fileURL: URL?
        if autoSave {
            let folder = Self.screenshotsFolder
            let url = folder.appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? data.write(to: url)) != nil { fileURL = url }
        }
        let shot = Shot(rep: rep, name: name, fileURL: fileURL)
        lastShot = shot

        ToastController.shared.show(image: thumbnail) { [weak self] in
            self?.openEditor(shot)
        }
    }

    // MARK: - Editor

    // Snip is menu-bar only, but while an editor is open it joins the Dock and ⌘Tab
    // so the window can be found again.
    private func openEditor(_ shot: Shot) {
        let editor = EditorController(shot: shot)
        editor.onDelete = { [weak self] in
            if self?.lastShot?.name == shot.name { self?.lastShot = nil }
        }
        editor.onClose = { [weak self] closed in
            guard let self else { return }
            self.editors.removeAll { $0 === closed }
            if self.editors.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        editors.append(editor)
        NSApp.setActivationPolicy(.regular)
        editor.show()
    }

    // Clicking the Dock icon brings the editors back to the front.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        editors.forEach { $0.show() }
        return false
    }

    /// Menu bar shown while Snip is a regular app; the editor window handles its own shortcuts.
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Snip", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Snip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        let mainMenu = NSMenu()
        for (title, menu) in [("Snip", appMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
