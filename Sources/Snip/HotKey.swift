import AppKit
import Carbon

/// A system-wide hotkey registered through Carbon (needs no Accessibility permission).
final class HotKey {
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let handler: () -> Void

    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        self.handler = handler
        HotKey.installHandlerIfNeeded()

        let id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4950), id: id) // 'SNIP'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            NSLog("Snip: failed to register hotkey \(keyCode) (status \(status))")
            return nil
        }
        HotKey.registry[id] = self
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.registry[id]?.handler() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
