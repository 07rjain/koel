import Foundation

@MainActor
private final class Fixture {
    var current: Int32 = 2
    var explicit = false
    var marker: GlobeAction.SavedAction?
    var updates: [Int32] = []
    var writesFail = false
    var readsFail = false
    var lockFails = false
    var ignoresUpdates = false
    var clears = 0

    func controller() -> GlobeAction {
        GlobeAction(environment: .init(
            lock: { if self.lockFails { throw CocoaError(.fileLocking) } },
            read: { if self.readsFail { throw CocoaError(.fileReadCorruptFile) }; return self.marker },
            save: { if self.writesFail { throw CocoaError(.fileWriteNoPermission) }; self.marker = $0 },
            remove: { self.marker = nil },
            current: { self.current },
            update: {
                precondition(self.marker != nil, "An override must always have a recovery record")
                self.updates.append($0)
                if !self.ignoresUpdates { self.current = $0; self.explicit = true }
            },
            hasPreference: { self.explicit },
            clearPreference: { self.explicit = false; self.clears += 1 }))
    }
}

@main
struct GlobeActionTests {
    @MainActor static func main() {
        // No Carbon calls or real preferences are used anywhere in this suite.
        for explicit in [false, true] {
            let f = Fixture(); f.explicit = explicit
            let c = f.controller(); c.prepare(); c.activate(); c.activate()
            precondition(f.current == 0 && c.isManaged && f.updates == [0])
            precondition(f.marker?.action == 2 && f.marker?.hadExplicitPreference == explicit)
            c.restore(); c.restore()
            precondition(f.current == 2 && f.marker == nil && f.explicit == explicit)
            precondition(f.updates == [0, 2] && f.clears == (explicit ? 0 : 1))
            c.activate(); c.restore() // sleep/wake or permission loss/regrant
            precondition(f.current == 2 && f.updates == [0, 2, 0, 2])
        }

        let changed = Fixture(); let c = changed.controller()
        c.prepare(); c.activate(); changed.current = 3; c.activate(); c.activate(); c.restore()
        precondition(changed.current == 3 && changed.marker == nil && changed.updates == [0])

        let disabled = Fixture(); disabled.current = 0
        let d = disabled.controller(); d.prepare(); d.activate(); d.restore()
        precondition(disabled.updates.isEmpty && disabled.marker == nil)

        let alreadyDisabled = Fixture(); alreadyDisabled.current = 0
        let e = alreadyDisabled.controller(); e.prepare(); e.activate()
        alreadyDisabled.current = 3; e.activate(); e.restore()
        precondition(alreadyDisabled.current == 3 && alreadyDisabled.updates.isEmpty)

        for userChanged in [false, true] {
            let crashed = Fixture()
            crashed.marker = .init(version: 1, action: 2, hadExplicitPreference: false)
            crashed.current = userChanged ? 3 : 0
            let recovered = crashed.controller(); recovered.prepare()
            precondition(crashed.current == (userChanged ? 3 : 2) && crashed.marker == nil)
            precondition(crashed.updates == (userChanged ? [] : [2]))
            if userChanged {
                recovered.activate()
                precondition(crashed.current == 3 && crashed.updates.isEmpty)
            }
        }

        for failure in 0..<3 {
            let f = Fixture(); f.writesFail = failure == 0
            f.readsFail = failure == 1; f.lockFails = failure == 2
            let c = f.controller(); c.prepare(); c.activate(); c.restore()
            precondition(f.current == 2 && f.updates.isEmpty && c.problem != nil)
        }

        let unavailable = GlobeAction(environment: nil); unavailable.prepare(); unavailable.activate()
        precondition(unavailable.problem != nil && !unavailable.isManaged)
        let ignored = Fixture(); ignored.ignoresUpdates = true
        let i = ignored.controller(); i.prepare(); i.activate()
        precondition(ignored.current == 2 && !i.isManaged && i.problem != nil)
        print("PASS: Globe action ownership, original defaults, sleep/restart recovery, user changes, and storage/API failures")
    }
}
