import Carbon

/// A system-wide keyboard shortcut via Carbon (no Accessibility permission needed).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.handlers[id] = handler
        if !HotKey.installed {
            HotKey.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                    DispatchQueue.main.async { HotKey.handlers[hotKeyID.id]?() }
                    return noErr
                }, 1, &spec, nil, nil)
        }
        RegisterEventHotKey(
            keyCode, modifiers, EventHotKeyID(signature: OSType(0x5348_4C46), id: id),
            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
