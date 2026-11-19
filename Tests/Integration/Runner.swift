import AppKit
import DockpinCore

@main enum IntegrationRunner {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS: live window restoration, frozen baseline, cancellation, Dock relocation and pointer return"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ description: String) throws { if !condition { throw Failure(description: description) } }
    @MainActor static func until(_ description: String, seconds: Double = 50, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() > end { throw Failure(description: description) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    @MainActor static func run() async throws {
        try require(AXIsProcessTrusted(), "Accessibility permission is required for integration checks")
        let automation = DockAccess()
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents") { application.terminate() }
        try await until("System Events did not exit", seconds: 5) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty
        }
        let settings = await automation.settings(displayID: Screens.current()[0].id)
        try require(settings?.size != nil && automation.automationAllowed, "System Events relaunch did not preserve granted automation permission: \(automation.permissionStatus)")
        print("PASS: exited System Events is relaunched and granted automation remains usable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockpinChecks-" + UUID().uuidString)
        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/fixtures/DockpinFixture.app")
        let fixture = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: NSWorkspace.OpenConfiguration())
        defer { fixture.terminate(); try? FileManager.default.removeItem(at: directory) }
        let apps = { AppIdentity.current().filter { $0.pid == fixture.processIdentifier } }
        let recovery = Recovery(directory: directory, applications: apps)
        recovery.enabled = true; recovery.start(rememberCurrent: true)
        defer { recovery.stop() }
        try await until("initial snapshot timeout: \(recovery.status)") { recovery.savedAt != nil && recovery.windowCount == 2 }
        let repository = LayoutRepository(directory: directory)
        let baseline = try repository.load().first!
        let access = WindowAccess(), screens = Screens.current()
        let original = await access.scan(apps: apps(), displays: screens)
        try require(original.windows.count == 2, "expected two fixture windows")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for window in original.windows {
            let moved = await access.move(window, to: CGRect(x: 300, y: 350, width: 600, height: 440))
            try require(moved, "fixture displacement failed")
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try require(try repository.load().first == baseline, "sleep-time window moves overwrote the baseline")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        // The user may be active at wake. Schedule the rebound only after the first actual restore.
        try await until("first wake restoration timeout", seconds: 150) {
            original.windows.allSatisfy { window in AX.rect(window.element).map { Geometry.close($0, window.globalFrame) } ?? false }
        }
        DistributedNotificationCenter.default().postNotificationName(.init("app.dockpin.fixture.rebound"), object: nil, userInfo: nil, deliverImmediately: true)
        try await until("wake restoration timeout", seconds: 150) { recovery.status.contains("복원 완료") }
        let after = await access.scan(apps: apps(), displays: Screens.current())
        for before in original.windows {
            let restored = after.windows.first { CFEqual($0.element, before.element) }
            try require(restored.map { Geometry.close($0.globalFrame, before.globalFrame) } ?? false, "window was not restored within 2pt")
        }
        let diagnostics = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("recovery-status.txt"))) as! [String: Any]
        let details = (diagnostics["lastRecovery"] as! [String: Any])["windows"] as! [[String: Any]]
        try require(details.contains { ($0["attempts"] as? Int ?? 0) >= 2 }, "late fixture resize was not detected and repaired")
        print("PASS: same-title windows restored, including a second resize 8 seconds after wake; frozen snapshot unchanged")
        let deniedDirectory = directory.appendingPathComponent("denied")
        try LayoutRepository(directory: deniedDirectory).save(baseline)
        let denied = Recovery(directory: deniedDirectory, applications: apps, isTrusted: { false })
        denied.enabled = true; denied.start()
        try await until("denied permission was not surfaced", seconds: 3) { denied.status.contains("손쉬운 사용 권한") }
        try require(try LayoutRepository(directory: deniedDirectory).load().first == baseline, "permission denial changed the baseline")
        denied.stop()
        let permit = WritePermit(); permit.cancel()
        _ = await access.move(after.windows[0], to: CGRect(x: 50,y: 50,width: 300,height: 300), permit: permit)
        let unchanged = await access.scan(apps: apps(), displays: screens)
        try require(Geometry.close(unchanged.windows[0].globalFrame, after.windows[0].globalFrame), "cancelled write changed a window")
        recovery.stop()
        // A failed Dock must not suspend healthy window capture.
        let partialDirectory = directory.appendingPathComponent("partial")
        var partialBaseline = baseline
        partialBaseline.dock = DockSnapshot(displayID: screens[0].id, size: 0.5)
        try LayoutRepository(directory: partialDirectory).save(partialBaseline)
        let partial = Recovery(directory: partialDirectory, applications: apps, timing: RecoveryTiming(observation: 1, timeout: 4, stable: 1))
        partial.dockConflict = { true }
        partial.enabled = true; partial.start()
        defer { partial.stop() }
        try await until("Dock failure was not reported") { partial.status.contains("실패한 배치만") }
        let healthyFrame = CGRect(x: 200, y: 200, width: 650, height: 450)
        _ = await access.move(after.windows[0], to: healthyFrame)
        try await until("healthy window was not saved after Dock failure", seconds: 12) {
            guard let saved = try? LayoutRepository(directory: partialDirectory).load().first,
                  let window = saved.windows.first(where: { $0.identifier == after.windows[0].snapshot.identifier }),
                  let screen = screens.first(where: { $0.id == window.displayID }) else { return false }
            return Geometry.close(window.frame.offsetBy(dx: screen.bounds.minX, dy: screen.bounds.minY), healthyFrame) && saved.dock == partialBaseline.dock
        }
        print("PASS: Dock failure protects only Dock settings; healthy window geometry continues saving")
        partial.stop()
        let dock = DockAccess(), input = InputActivity()
        input.start()
        try await until("input monitor unavailable or user is active") { input.idle }
        guard let initial = dock.currentDisplay(screens), let home = screens.first(where: { $0.id == initial }),
              let target = screens.first(where: { $0.id != initial && Geometry.exposedBottom(of: $0, among: screens) != nil }) else {
            throw Failure(description: "two exposed Dock destinations are required")
        }
        let pointer = CGEvent(source: nil)!.location
        let moved = await dock.relocate(to: target, displays: screens, input: input, cancelled: { false })
        // Always attempt to return the Dock, including when validation below fails.
        try await Task.sleep(nanoseconds: 200_000_000)
        let returned = await dock.relocate(to: home, displays: screens, input: input, cancelled: { false })
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(moved && returned, "production Dock relocation did not complete: moved=\(moved), returned=\(returned), input age=\(Date().timeIntervalSince(input.lastInput))")
        let afterPointer = CGEvent(source: nil)!.location
        try require(abs(afterPointer.x-pointer.x) < 2 && abs(afterPointer.y-pointer.y) < 2, "pointer did not return")
    }
}
