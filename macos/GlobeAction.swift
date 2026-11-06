import Foundation
import Darwin

/// A recoverable lease on the standalone Globe action. Fn combinations are not
/// changed. All system access is injected so tests never touch macOS settings.
@MainActor
final class GlobeAction {
    struct SavedAction: Codable {
        let version: Int
        let action: Int32
        let hadExplicitPreference: Bool
    }

    struct Environment {
        var lock: () throws -> Void
        var read: () throws -> SavedAction?
        var save: (SavedAction) throws -> Void
        var remove: () throws -> Void
        var current: () -> Int32
        var update: (Int32) -> Void
        var hasPreference: () -> Bool
        var clearPreference: () throws -> Void
    }

    private let environment: Environment?
    private var prepared = false
    private var saved: SavedAction?
    private var yielded = false
    private(set) var problem: String?
    private(set) var isManaged = false

    init(environment: Environment?) { self.environment = environment }

    /// Recover a previous interrupted run even when keyboard access was revoked.
    func prepare() {
        guard !prepared else { return }
        guard let environment else {
            problem = "Automatic Globe handling unavailable on this macOS version"
            return
        }
        do {
            try environment.lock()
            saved = try environment.read()
            prepared = true
            let changedAfterCrash = saved != nil && environment.current() != 0
            restore()
            if changedAfterCrash {
                yielded = true
                problem = "Globe action changed externally; reopen to use Fn exclusively"
            }
        } catch { problem = "Cannot recover Globe action: \(error.localizedDescription)" }
    }

    func activate() {
        guard prepared, let environment, !yielded else { return }
        if saved != nil || isManaged {
            if environment.current() != 0 {
                // A new choice in System Settings wins for the rest of this run.
                yielded = true
                restore()
                problem = "Globe action changed externally; reopen to use Fn exclusively"
            }
            return
        }
        guard problem == nil else { return }
        let original = environment.current()
        guard original != 0 else { isManaged = true; return }
        let state = SavedAction(version: 1, action: original,
                                hadExplicitPreference: environment.hasPreference())
        do {
            // Never modify the action without first saving how to restore it.
            try environment.save(state)
            saved = state
            environment.update(0)
            guard environment.current() == 0 else {
                restore()
                problem = "macOS did not apply automatic Globe handling"
                return
            }
            isManaged = true
        } catch { problem = "Cannot save original Globe action: \(error.localizedDescription)" }
    }

    func restore() {
        isManaged = false
        guard prepared, let environment, let state = saved else { return }
        do {
            if environment.current() == 0 {
                environment.update(state.action)
                guard environment.current() == state.action else {
                    problem = "Globe action restoration pending; reopen the app to retry"
                    return
                }
                if !state.hadExplicitPreference { try environment.clearPreference() }
            }
            try environment.remove()
            saved = nil
            problem = nil
        } catch { problem = "Cannot restore Globe action: \(error.localizedDescription)" }
    }

    static func system() -> GlobeAction {
        // These Carbon entry points are also used by OpenWhispr. They apply the
        // change live; a defaults write alone does not update WindowServer.
        // Resolve dynamically because they are not public SDK declarations.
        typealias Getter = @convention(c) () -> Int32
        typealias Setter = @convention(c) (Int32) -> Void
        guard let library = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY),
              let getSymbol = dlsym(library, "TISGetFnUsageType"),
              let setSymbol = dlsym(library, "TISUpdateFnUsageType") else {
            return GlobeAction(environment: nil)
        }
        let get = unsafeBitCast(getSymbol, to: Getter.self)
        let set = unsafeBitCast(setSymbol, to: Setter.self)
        let store = GlobeActionStore()
        let domain = "com.apple.HIToolbox" as CFString
        let key = "AppleFnUsageType" as CFString
        return GlobeAction(environment: Environment(
            lock: { try store.lock() }, read: { try store.read() },
            save: { try store.save($0) }, remove: { try store.remove() },
            current: { get() }, update: { set($0) },
            hasPreference: {
                CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
            }, clearPreference: {
                CFPreferencesSetValue(key, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }))
    }
}

/// Kept outside the bundle so a crash or an app update cannot erase recovery.
private final class GlobeActionStore {
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Local Whisper", isDirectory: true)
    private var descriptor: Int32 = -1
    private var url: URL { directory.appendingPathComponent("globe-action.json") }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func lock() throws {
        if descriptor >= 0 { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("globe-action.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw NSError(domain: "LocalWhisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Another Local Whisper instance owns Fn"])
        }
        descriptor = fd
    }

    func read() throws -> GlobeAction.SavedAction? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(GlobeAction.SavedAction.self, from: Data(contentsOf: url))
        guard state.version == 1, state.action != 0 else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }

    func save(_ state: GlobeAction.SavedAction) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
