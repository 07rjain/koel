@main
struct FnShortcutTests {
    static func main() {
        testHold()
        testTaps()
        testChordsAndInterruptions()
        testStartupRelease()
        testOwnership()
        print("PASS: Fn holds, double taps, chords, interruptions, startup cancellation, and recording ownership")
    }

    static func testHold() {
        var gesture = FnGesture()
        precondition(gesture.press(at: 0, chord: false) == nil)
        precondition(gesture.advance(to: 0.29) == nil)
        precondition(gesture.advance(to: 0.31) == .beginHold)
        precondition(gesture.advance(to: 1) == nil, "Hold must start only once")
        precondition(gesture.press(at: 1, chord: false) == nil, "Duplicate down must be ignored")
        precondition(gesture.release(at: 2) == .endHold)
        precondition(gesture.release(at: 2.1) == nil, "Duplicate release must be ignored")

        // A busy main run loop can delay the timer until after key-up.
        precondition(gesture.press(at: 3, chord: false) == nil)
        precondition(gesture.release(at: 4) == nil)
        precondition(gesture.advance(to: 4.1) == nil, "A late timer must not start capture after release")
    }

    static func tap(_ gesture: inout FnGesture, at time: Double) -> FnGesture.Action? {
        precondition(gesture.press(at: time, chord: false) == nil)
        return gesture.release(at: time + 0.05)
    }

    static func testTaps() {
        var gesture = FnGesture()
        precondition(tap(&gesture, at: 0) == nil, "Single tap must do nothing")
        precondition(tap(&gesture, at: 0.2) == .toggle)
        precondition(tap(&gesture, at: 1) == nil)
        precondition(tap(&gesture, at: 1.2) == .toggle, "Next double tap must stop via the same toggle action")
        precondition(tap(&gesture, at: 2) == nil)
        precondition(tap(&gesture, at: 3) == nil, "Slow taps must not toggle")
        precondition(gesture.press(at: 3.2, chord: false) == nil)
        precondition(gesture.advance(to: 3.51) == .beginHold, "Holding the second tap is a hold, not a toggle")
        precondition(gesture.release(at: 4) == .endHold)
        precondition(tap(&gesture, at: 4.1) == nil, "Hold release must not seed a double tap")
    }

    static func testChordsAndInterruptions() {
        var gesture = FnGesture()
        precondition(gesture.press(at: 0, chord: true) == nil)
        precondition(gesture.advance(to: 1) == nil, "Fn with another held key must not record")
        precondition(gesture.release(at: 2) == nil)
        precondition(gesture.press(at: 3, chord: false) == nil)
        precondition(gesture.interrupt() == nil)
        precondition(gesture.advance(to: 4) == nil, "Fn+arrow or Fn+modifier must cancel the pending hold")
        precondition(gesture.release(at: 5) == nil)
        precondition(tap(&gesture, at: 6) == nil)
        precondition(gesture.interrupt() == nil)
        precondition(tap(&gesture, at: 6.2) == nil, "Typing/clicking between taps must break the gesture")
        _ = gesture.reset()
        precondition(gesture.press(at: 7, chord: false) == nil)
        precondition(gesture.advance(to: 7.31) == .beginHold)
        precondition(gesture.interrupt() == .endHold, "A chord during a hold must stop that hold")
        precondition(gesture.release(at: 8) == nil)
        precondition(gesture.press(at: 9, chord: false) == nil)
        precondition(gesture.advance(to: 9.31) == .beginHold)
        precondition(gesture.reset() == .endHold, "Sleep/lost events must end a hold")
        precondition(gesture.release(at: 10) == nil)
        precondition(tap(&gesture, at: 11) == nil)
        precondition(gesture.reset() == nil)
        precondition(tap(&gesture, at: 11.2) == nil, "Reset must clear partial double taps")
    }

    static func testStartupRelease() {
        var recording = RecordingLifecycle()
        precondition(recording.begin(.fnHold))
        precondition(recording.shouldStart)
        precondition(!recording.requestStop(only: .fnHold), "A permission dialog has no live microphone to stop yet")
        precondition(!recording.shouldStart, "Release during permission/startup must prevent later capture")
        precondition(!recording.didStart(), "Cancelled startup must not become a recording")
        precondition(!recording.begin(.fnToggle), "A second request must wait for cleanup")
        recording.reset()
        precondition(recording.begin(.fnToggle))
        precondition(!recording.requestStop(), "Second double tap during startup must also cancel it")
        precondition(!recording.shouldStart)
        recording.reset()
        precondition(recording.begin(.standard))
        precondition(recording.didStart(), "App can record again after cancelled startup")
    }

    static func testOwnership() {
        var recording = RecordingLifecycle()
        precondition(recording.begin(.fnToggle))
        precondition(recording.isFnOwned)
        precondition(!recording.requestStop(only: .fnHold))
        precondition(recording.shouldStart, "Releasing an unrelated hold cannot cancel a toggle startup")
        precondition(recording.didStart())
        precondition(!recording.requestStop(only: .fnHold), "A hold release cannot stop a latched recording")
        precondition(recording.requestStop())
        recording.reset()
        precondition(recording.begin(.standard))
        precondition(!recording.isFnOwned)
        precondition(recording.didStart())
        precondition(!recording.requestStop(only: .fnHold), "Fn release must leave a menu/⌘⇧Space recording alone")
        precondition(recording.requestStop())
        recording.reset()
        precondition(recording.begin(.fnHold))
        precondition(recording.didStart())
        precondition(recording.requestStop(only: .fnHold))
        recording.reset()
        precondition(!recording.hasSession && !recording.isRecording && !recording.shouldStart)
        precondition(!recording.requestStop(), "Late releases after discard/timeout/error must be harmless")
    }
}
