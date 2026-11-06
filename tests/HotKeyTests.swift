import AppKit
import Carbon

// This test links only the native shortcut, without the Rust or microphone code.
struct AppError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@main
struct HotKeyTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let hotKey = HotKey(keyCode: UInt32(kVK_F20))
        var calls = 0
        hotKey.onPress = { calls += 1 }
        try hotKey.register()
        defer { hotKey.unregister() }

        func send(signature: OSType, id: UInt32) throws {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                     0, UInt32(kEventAttributeNone), &event) == noErr)
            guard let event else { preconditionFailure("Cannot create synthetic Carbon event") }
            defer { ReleaseEvent(event) }
            var hotKeyID = EventHotKeyID(signature: signature, id: id)
            precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           MemoryLayout<EventHotKeyID>.size, &hotKeyID) == noErr)
            _ = SendEventToEventTarget(event, GetEventDispatcherTarget())
        }
        try send(signature: 0x4C575350, id: 1)
        precondition(calls == 1, "AppKit global shortcuts must receive Carbon dispatcher events")
        try send(signature: 0x4C575350, id: 2)
        try send(signature: 0x41424344, id: 1)
        precondition(calls == 1, "Unrelated shortcuts must not start dictation")
        hotKey.unregister()
        try send(signature: 0x4C575350, id: 1)
        precondition(calls == 1, "Unregister must remove the callback")
        try hotKey.register()
        try send(signature: 0x4C575350, id: 1)
        precondition(calls == 2, "A shortcut must register again after cleanup")
        print("PASS: Carbon dispatcher delivery, shortcut identity, and unregister/re-register without keyboard injection")
    }
}
