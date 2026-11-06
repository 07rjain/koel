import AppKit
import Carbon
@preconcurrency import ApplicationServices

/// Observes Fn gestures and temporarily manages the macOS standalone Globe action.
@MainActor
final class FnHotKey {
    private let globeAction = GlobeAction.system()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var holdTimer: Timer?
    private var healthTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var gesture = FnGesture()
    private var fnDown = false
    private var modifiers: CGEventFlags = []
    private var pressedAt: Double?
    private var releasedAt: Double?
    private var diagnostics: [String] = []
    var diagnosticReport: String { ([statusText] + diagnostics).joined(separator: "\n") }
    var lastDiagnostic: String { diagnostics.last ?? "No Fn gesture received yet" }

    var onDiagnostic: ((String) -> Void)?

    func clearDiagnostics() { diagnostics.removeAll() }

    private func note(_ text: String) {
        diagnostics.append(text)
        if diagnostics.count > 24 { diagnostics.removeFirst() }
        // Test-mode UI/logging stays outside the event-tap callback.
        Task { @MainActor [weak self] in self?.onDiagnostic?(text) }
    }
    private var standaloneFn = false
    private var keysDown: Set<Int64> = []
    private var suspended = false
    private var generation: UInt64 = 0
    private var access = KeyboardAccess.unavailable
    private(set) var isMonitoring = false
    var statusText: String {
        if isMonitoring {
            if let problem = globeAction.problem { return "Fn listening · \(problem)" }
            return access == .accessibility ? "Fn active · Accessibility · Globe action managed" : "Fn active · Input Monitoring · Globe action managed"
        }
        return DictationPermissions.current().keyboardAccess != .unavailable
            ? "Fn listener unavailable; reopen the app" : "Fn needs Accessibility or Input Monitoring access"
    }
    var onGesture: ((FnGesture.Action) -> Void)?
    var onAvailabilityChange: (() -> Void)?
    var onInterrupted: (() -> Void)?

    func start() {
        globeAction.prepare()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = true
                    self?.removeTap()
                    self?.onInterrupted?()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = false
                    self?.refresh()
                }
            })
        }
    }

    func requestAccess() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        refresh()
    }

    func refresh() {
        guard !suspended else { return }
        let nextAccess = DictationPermissions.current().keyboardAccess
        guard nextAccess != .unavailable else { removeTap(); return }
        if tap != nil && nextAccess != access { removeTap(); onInterrupted?() }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                reset()
                onInterrupted?()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            globeAction.activate()
            return
        }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // The source is attached exclusively to the main run loop.
                MainActor.assumeIsolated {
                    let listener = Unmanaged<FnHotKey>.fromOpaque(userInfo).takeUnretainedValue()
                    listener.receive(type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: pointer) else { return }
        self.tap = tap
        access = nextAccess
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoring = true
        globeAction.activate()
        onAvailabilityChange?()
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        removeTap()
    }

    // Internal so native tests can deliver events directly without posting
    // keystrokes to macOS or connecting the listener to microphone recording.
    @discardableResult
    func receive(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            globeAction.restore()
            // Leave UI work outside the event-tap callback.
            Task { @MainActor [weak self] in
                self?.onInterrupted?()
                self?.refresh()
            }
            return false
        }
        guard !suspended else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // Use occurrence time, rather than delivery time, for double taps.
        let now = Double(event.timestamp) / 1_000_000_000
        if type == .keyDown {
            // Some keyboards also report Fn as a key event. It is not a chord
            // with itself; flagsChanged remains the source of gesture edges.
            guard code != Int64(kVK_Function) else { return standaloneFn }
            keysDown.insert(code)
            // Match OpenWhispr: only a key pressed WHILE Fn is held is a
            // chord. macOS can send auxiliary key events after a bare Fn
            // release; cancelling here would erase every double-tap candidate.
            guard fnDown else { return false }
            note("Interrupted by another key while Fn held (key identity not retained)")
            standaloneFn = false
            emit(gesture.interrupt())
            holdTimer?.invalidate()
        } else if type == .keyUp {
            keysDown.remove(code)
        } else if type == .flagsChanged {
            let chordModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let nextModifiers = event.flags.intersection(chordModifiers)
            if nextModifiers != modifiers {
                standaloneFn = false
                emit(gesture.interrupt())
                holdTimer?.invalidate()
                if gesturePending(at: now) { note("Interrupted by a modifier change") }
            }
            modifiers = nextModifiers
            // Match OpenWhispr: follow transitions of the Fn flag, including
            // releases with missing/different key-code metadata. Arrows carry
            // secondaryFn on keyDown/up, not on physical modifier transitions.
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != fnDown else { return standaloneFn }
            fnDown = down
            if down {
                let chord = !keysDown.isEmpty || !modifiers.isEmpty
                let gap = releasedAt.map { String(format: " · gap %.0f ms", (now - $0) * 1000) } ?? ""
                note("Fn down\(gap)\(chord ? " · chord" : "")")
                pressedAt = now
                standaloneFn = !chord
                let action = gesture.press(at: now, chord: chord)
                emit(action)
                // A double tap is already latched. Its second press/release
                // must never start or stop a separate hold recording.
                guard action != .toggle else { return standaloneFn }
                let timer = Timer(timeInterval: FnGesture.holdDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Check the physical state in case a release was lost.
                        guard CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) else {
                            self.reset()
                            return
                        }
                        self.emit(self.gesture.advance(to: ProcessInfo.processInfo.systemUptime))
                    }
                }
                holdTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                return standaloneFn
            } else {
                let duration = pressedAt.map { String(format: "%.0f ms", (now - $0) * 1000) } ?? "unknown duration"
                note("Fn up · \(duration)")
                pressedAt = nil
                releasedAt = now
                let wasStandalone = standaloneFn
                standaloneFn = false
                holdTimer?.invalidate()
                holdTimer = nil
                emit(gesture.release(at: now))
                return wasStandalone
            }
        } else {
            if gesturePending(at: now) { note("Interrupted by a mouse click") }
            standaloneFn = false
            emit(gesture.interrupt())
            holdTimer?.invalidate()
        }
        return false
    }

    private func gesturePending(at time: Double) -> Bool {
        fnDown || releasedAt.map { (0...FnGesture.doubleTapWindow).contains(time - $0) } == true
    }

    private func emit(_ action: FnGesture.Action?) {
        guard let action else { return }
        switch action {
        case .beginHold: note("Hold recognized")
        case .endHold: note("Hold ended / reset")
        case .toggle: note("Double tap recognized")
        }
        let generation = generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.onGesture?(action)
        }
    }

    private func reset() {
        generation &+= 1
        holdTimer?.invalidate()
        holdTimer = nil
        _ = gesture.reset()
        fnDown = false
        modifiers = []
        pressedAt = nil
        releasedAt = nil
        standaloneFn = false
        keysDown.removeAll()
        // A previous endHold may still be queued. Reissue it in this generation
        // so invalidating old callbacks cannot strand an active hold recording.
        emit(.endHold)
    }

    private func checkHealth() {
        guard !suspended else { return }
        if DictationPermissions.current().keyboardAccess == .unavailable {
            if tap != nil { removeTap(); onInterrupted?() }
            return
        }
        refresh()
        if fnDown && !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) {
            reset()
        }
    }

    private func removeTap() {
        globeAction.restore()
        guard tap != nil || isMonitoring || fnDown else { return }
        reset()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        if isMonitoring { isMonitoring = false; onAvailabilityChange?() }
    }
}
