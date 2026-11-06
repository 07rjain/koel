import AVFoundation
@preconcurrency import ApplicationServices
import Carbon

struct DictationPermissions: Encodable {
    let microphone: String
    let accessibility: Bool
    let inputMonitoring: Bool
    let secureKeyboardEntry: Bool

    var keyboardAccess: KeyboardAccess {
        KeyboardAccess(accessibility: accessibility, inputMonitoring: inputMonitoring)
    }

    static func current() -> Self {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "Allowed"
        case .denied: microphone = "Denied"
        case .restricted: microphone = "Restricted"
        case .notDetermined: microphone = "Not requested"
        @unknown default: microphone = "Unknown"
        }
        return Self(microphone: microphone, accessibility: AXIsProcessTrusted(),
                    inputMonitoring: CGPreflightListenEventAccess(), secureKeyboardEntry: IsSecureEventInputEnabled())
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
