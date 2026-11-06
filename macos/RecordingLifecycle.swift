/// Owns recording intent while microphone permission and speech startup await.
struct RecordingLifecycle {
    enum Source: Equatable { case standard, fnHold, fnToggle }
    private enum State { case idle, starting(Source, stopRequested: Bool), recording(Source) }
    private var state = State.idle

    var hasSession: Bool { if case .idle = state { return false }; return true }
    var isRecording: Bool { if case .recording = state { return true }; return false }
    var shouldStart: Bool { if case .starting(_, false) = state { return true }; return false }
    var isFnOwned: Bool {
        switch state {
        case .starting(let source, _), .recording(let source): return source != .standard
        case .idle: return false
        }
    }

    mutating func begin(_ source: Source) -> Bool {
        guard !hasSession else { return false }
        state = .starting(source, stopRequested: false)
        return true
    }

    /// Returns true only when the microphone is ready to stop. During startup,
    /// remember the request so permission dialogs cannot leave it recording later.
    mutating func requestStop(only source: Source? = nil) -> Bool {
        switch state {
        case .starting(let owner, _):
            guard source == nil || source == owner else { return false }
            state = .starting(owner, stopRequested: true)
            return false
        case .recording(let owner): return source == nil || source == owner
        case .idle: return false
        }
    }

    mutating func didStart() -> Bool {
        guard case .starting(let source, false) = state else { return false }
        state = .recording(source)
        return true
    }

    mutating func reset() { state = .idle }
}
