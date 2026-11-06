import Carbon
import Foundation

@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private(set) var statusText = "⌘⇧Space: Not registered"
    var onPress: (() -> Void)?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func register() throws {
        unregister()
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetEventDispatcherTarget()
        let result = InstallEventHandler(target, { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4C575350, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches application events on the main event loop.
            MainActor.assumeIsolated {
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &event, pointer, &handler)
        guard result == noErr else {
            statusText = "⌘⇧Space: Cannot install handler (\(result))"
            throw AppError(statusText)
        }
        let id = EventHotKeyID(signature: 0x4C575350, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, target, 0, &reference)
        guard status == noErr else {
            unregister()
            statusText = "⌘⇧Space: Registration failed (\(status)); another app may use it"
            throw AppError("\(statusText). Recording is still available from the menu bar.")
        }
        statusText = "⌘⇧Space: Registered"
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        statusText = "⌘⇧Space: Not registered"
    }
}
