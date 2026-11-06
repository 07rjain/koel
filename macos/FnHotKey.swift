import AppKit
import Carbon

/// A passive listener: never consumes Fn, text, or other apps' shortcuts.
@MainActor
final class FnHotKey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var holdTimer: Timer?
    private var healthTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var gesture = FnGesture()
    private var fnDown = false
    private var keysDown: Set<Int64> = []
    private var suspended = false
    private var generation: UInt64 = 0
    private(set) var isMonitoring = false
    var statusText: String {
        if isMonitoring { return "Fn listener active" }
        return CGPreflightListenEventAccess() ? "Fn listener unavailable; reopen the app" : "Fn requires Input Monitoring access"
    }
    var onGesture: ((FnGesture.Action) -> Void)?
    var onAvailabilityChange: (() -> Void)?
    var onInterrupted: (() -> Void)?

    func start() {
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
                    self?.reset()
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
        guard CGPreflightListenEventAccess() else { removeTap(); return }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                reset()
                onInterrupted?()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // The source is attached exclusively to the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<FnHotKey>.fromOpaque(userInfo).takeUnretainedValue().receive(type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: pointer) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoring = true
        onAvailabilityChange?()
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        removeTap()
    }

    private func receive(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            // Leave UI work outside the event-tap callback.
            Task { @MainActor [weak self] in
                self?.onInterrupted?()
                self?.refresh()
            }
            return
        }
        guard !suspended else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // Use occurrence time, rather than delivery time, for double taps.
        let now = Double(event.timestamp) / 1_000_000_000
        if type == .keyDown {
            keysDown.insert(code)
            emit(gesture.interrupt())
            holdTimer?.invalidate()
        } else if type == .keyUp {
            keysDown.remove(code)
        } else if type == .flagsChanged {
            guard code == Int64(kVK_Function) else {
                emit(gesture.interrupt())
                holdTimer?.invalidate()
                return
            }
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            if !event.flags.intersection(modifiers).isEmpty {
                emit(gesture.interrupt())
                holdTimer?.invalidate()
            }
            // Arrow and function keys also carry secondaryFn; require the
            // physical Fn keycode so those cannot start a recording.
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != fnDown else { return }
            fnDown = down
            if down {
                emit(gesture.press(at: now, chord: !keysDown.isEmpty || !event.flags.intersection(modifiers).isEmpty))
                let timer = Timer(timeInterval: FnGesture.holdDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Check the physical state in case a release was lost.
                        guard CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) else {
                            self.reset()
                            return
                        }
                        self.emit(self.gesture.advance(to: ProcessInfo.processInfo.systemUptime))
                    }
                }
                holdTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else {
                holdTimer?.invalidate()
                holdTimer = nil
                emit(gesture.release(at: now))
            }
        } else {
            emit(gesture.interrupt())
            holdTimer?.invalidate()
        }
    }

    private func emit(_ action: FnGesture.Action?) {
        guard let action else { return }
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
        keysDown.removeAll()
        // A previous endHold may still be queued. Reissue it in this generation
        // so invalidating old callbacks cannot strand an active hold recording.
        emit(.endHold)
    }

    private func checkHealth() {
        guard !suspended else { return }
        if !CGPreflightListenEventAccess() {
            if tap != nil { removeTap(); onInterrupted?() }
            return
        }
        refresh()
        if fnDown && !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) {
            reset()
        }
    }

    private func removeTap() {
        guard tap != nil || isMonitoring || fnDown else { return }
        reset()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        if isMonitoring { isMonitoring = false; onAvailabilityChange?() }
    }
}
