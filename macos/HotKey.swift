import Carbon

@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    func register() throws {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches application events on the main event loop.
            MainActor.assumeIsolated {
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &event, pointer, &handler)
        guard result == noErr else { throw AppError("Cannot install the global keyboard shortcut (\(result)).") }
        let id = EventHotKeyID(signature: 0x4C575350, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), id,
                                        GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { throw AppError("⌘⇧Space is already in use. Recording is still available from the menu bar.") }
    }
}
