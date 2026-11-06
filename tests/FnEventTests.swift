import AppKit
import Carbon

@main
struct FnEventTests {
    @MainActor static func main() async {
        let listener = FnHotKey()
        var actions: [FnGesture.Action] = []
        listener.onGesture = { actions.append($0) }
        defer { listener.onGesture = nil; listener.stop() }

        // Deliver synthetic events only to this unregistered listener. There
        // is no event tap, system keyboard injection, or microphone callback.
        @discardableResult
        func send(_ type: CGEventType = .flagsChanged, code: Int64 = Int64(kVK_Function),
                  flags: CGEventFlags, at time: Double) -> Bool {
            let event = CGEvent(source: nil)!
            event.type = type
            event.flags = flags
            event.timestamp = UInt64(time * 1_000_000_000)
            event.setIntegerValueField(.keyboardEventKeycode, value: code)
            return listener.receive(type, event: event)
        }

        func drainCallbacks() async {
            // Give the listener's main-actor callbacks a chance to run.
            try? await Task.sleep(for: .milliseconds(20))
        }

        precondition(send(flags: .maskSecondaryFn, at: 10), "Bare Fn down must be recognized")
        precondition(send(flags: [], at: 10.06), "Bare Fn up must be recognized")
        precondition(send(flags: .maskSecondaryFn, at: 10.50))
        await drainCallbacks()
        precondition(actions == [.toggle], "Native Fn events must toggle on second down, without waiting for release")
        precondition(send(flags: .maskSecondaryFn, at: 10.51), "Duplicate bare Fn flags must remain classified as standalone")
        precondition(send(flags: [], at: 10.95)) // intentionally longer second press
        await drainCallbacks()
        precondition(actions == [.toggle], "Duplicate flags and second release must not undo hands-free mode")

        send(flags: .maskSecondaryFn, at: 20)
        send(flags: [], at: 20.06)
        send(flags: .maskSecondaryFn, at: 20.50)
        send(flags: [], at: 20.56)
        await drainCallbacks()
        precondition(actions == [.toggle, .toggle], "A second native double tap must deliver Stop")

        send(flags: .maskSecondaryFn, at: 30)
        precondition(!send(.keyDown, code: Int64(kVK_LeftArrow), flags: .maskSecondaryFn, at: 30.01), "Fn+arrow must pass through")
        send(flags: [], at: 30.06)
        precondition(!send(.keyUp, code: Int64(kVK_LeftArrow), flags: [], at: 30.15))
        send(flags: .maskSecondaryFn, at: 30.40)
        send(flags: [], at: 30.46)
        await drainCallbacks()
        precondition(actions == [.toggle, .toggle], "A real Fn key combination must cancel the gesture")

        precondition(send(flags: .maskSecondaryFn, at: 40))
        precondition(!send(.keyDown, code: Int64(kVK_LeftArrow), flags: .maskSecondaryFn, at: 40.01))
        precondition(!send(flags: [], at: 40.1), "Fn release after a combination must pass through to clear modifier state")
        precondition(!send(.keyUp, code: Int64(kVK_LeftArrow), flags: [], at: 40.2))
        precondition(!send(flags: [.maskSecondaryFn, .maskCommand], at: 50), "Fn with an already-held modifier must pass through")
        precondition(!send(flags: .maskCommand, at: 50.1))
        await drainCallbacks()
        precondition(actions == [.toggle, .toggle])
        // Native modifier events need not carry kVK_Function on release.
        // Match the Fn flag transitions, as OpenWhispr's listener does.
        send(flags: .maskSecondaryFn, at: 60)
        send(.keyDown, code: Int64(kVK_Function), flags: .maskSecondaryFn, at: 60.01)
        send(code: 0, flags: [], at: 60.06)
        send(code: 0, flags: [], at: 60.07) // duplicate release metadata
        send(flags: .maskSecondaryFn, at: 60.30)
        send(code: 0, flags: .maskSecondaryFn, at: 60.31) // duplicate down metadata
        send(code: 0, flags: [], at: 60.36)
        await drainCallbacks()
        precondition(actions == [.toggle, .toggle, .toggle], "Fn releases with alternate key codes and duplicate flags must preserve a double tap")

        send(code: 0, flags: .maskSecondaryFn, at: 62)
        send(code: 0, flags: [], at: 62.06)
        send(code: 0, flags: .maskSecondaryFn, at: 62.30)
        send(code: 0, flags: [], at: 62.36)
        await drainCallbacks()
        precondition(actions == [.toggle, .toggle, .toggle, .toggle], "Both edges may omit physical key-code metadata")
        // Reproduce this Mac's observed delivery: each short Fn release is
        // followed by an auxiliary key down/up, before the next Fn press.
        // Code 179 is arbitrary; the physical key identity was not captured.
        // No system events are posted and no typed key identities are retained.
        send(flags: .maskSecondaryFn, at: 64)
        send(flags: [], at: 64.10)
        send(.keyDown, code: 179, flags: [], at: 64.101)
        send(.keyUp, code: 179, flags: [], at: 64.102)
        send(flags: .maskSecondaryFn, at: 64.21)
        send(flags: [], at: 64.30)
        send(.keyDown, code: 179, flags: [], at: 64.301)
        send(.keyUp, code: 179, flags: [], at: 64.302)
        await drainCallbacks()
        precondition(actions == [.toggle, .toggle, .toggle, .toggle, .toggle], "Auxiliary key events AFTER Fn release must not erase the first tap")
        precondition(listener.diagnosticReport.contains("Double tap recognized"))
        precondition(listener.diagnosticReport.contains("100 ms"), "Diagnostics must expose durations without recording audio or typed keys")
        print("PASS: native Fn double taps, standalone Fn classification, duplicate flags, unmodified Fn combinations, and alternate modifier metadata")
    }
}
