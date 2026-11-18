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
    @MainActor static func until(_ description: String, seconds: Double = 20, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() > end { throw Failure(description: description) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    @MainActor static func run() async throws {
        try require(AXIsProcessTrusted(), "Accessibility permission is required for integration checks")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockpinChecks-" + UUID().uuidString)
        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/fixtures/DockpinFixture.app")
        let fixture = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: NSWorkspace.OpenConfiguration())
        defer { fixture.terminate(); try? FileManager.default.removeItem(at: directory) }
        let apps = { AppIdentity.current().filter { $0.pid == fixture.processIdentifier } }
        let recovery = Recovery(directory: directory, applications: apps)
        recovery.enabled = true; recovery.start()
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
        try await until("wake restoration timeout: \(recovery.status)") { recovery.status.contains("복원 완료") }
        let after = await access.scan(apps: apps(), displays: Screens.current())
        for before in original.windows {
            let restored = after.windows.first { CFEqual($0.element, before.element) }
            try require(restored.map { Geometry.close($0.globalFrame, before.globalFrame) } ?? false, "window was not restored within 2pt")
        }
        print("PASS: two same-title windows restored across displays; frozen snapshot unchanged")
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
        try require(moved && returned, "production Dock relocation did not complete")
        let afterPointer = CGEvent(source: nil)!.location
        try require(abs(afterPointer.x-pointer.x) < 2 && abs(afterPointer.y-pointer.y) < 2, "pointer did not return")
    }
}
