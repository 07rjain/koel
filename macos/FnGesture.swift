/// Timing and chord handling independent of macOS event delivery.
struct FnGesture {
    enum Action: Equatable { case beginHold, endHold, toggle }

    static let holdDelay = 0.30
    static let doubleTapWindow = 0.50
    private var pressedAt: Double?
    private var firstTapAt: Double?
    private var secondTap = false
    private var blocked = false
    private var holding = false

    mutating func press(at time: Double, chord: Bool) -> Action? {
        guard pressedAt == nil else { return nil }
        pressedAt = time
        blocked = chord
        secondTap = !chord && firstTapAt.map { (0...Self.doubleTapWindow).contains(time - $0) } == true
        firstTapAt = nil
        // Latch on the second down. Waiting for its release can misclassify
        // a slightly longer second tap as a new hold-to-talk session.
        return secondTap ? .toggle : nil
    }

    mutating func advance(to time: Double) -> Action? {
        guard let pressedAt, !blocked, !holding, !secondTap, time - pressedAt >= Self.holdDelay else { return nil }
        holding = true
        secondTap = false
        return .beginHold
    }

    mutating func release(at time: Double) -> Action? {
        guard let pressedAt else { return nil }
        defer {
            self.pressedAt = nil
            holding = false
            secondTap = false
            blocked = false
        }
        if holding { return .endHold }
        if secondTap { return nil }
        // A delayed timer must never turn a long press into a tap.
        guard !blocked, time - pressedAt < Self.holdDelay else { firstTapAt = nil; return nil }
        firstTapAt = time
        return nil
    }

    mutating func interrupt() -> Action? {
        firstTapAt = nil
        secondTap = false
        blocked = pressedAt != nil
        let action: Action? = holding ? .endHold : nil
        holding = false
        return action
    }

    mutating func reset() -> Action? {
        let action: Action? = holding ? .endHold : nil
        self = FnGesture()
        return action
    }
}
