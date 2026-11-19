import AppKit
import DockpinCore

@main enum AgentBoardResize {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let useDemo = CommandLine.arguments.contains("--demo")
            guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: "app.agentboard.mac").first(where: {
                ($0.bundleURL?.path.contains("geometry-fix") ?? false) == useDemo
            }) else { print("FAIL: AgentBoard target not found"); exit(1) }
            let access = WindowAccess(), displays = Screens.current()
            let apps = AppIdentity.current().filter { $0.pid == target.processIdentifier }
            let scan = await access.scan(apps: apps, displays: displays)
            guard let live = scan.windows.first,
                  AX.settable(live.element, kAXSizeAttribute),
                  let screen = Geometry.display(for: live.globalFrame, in: displays) else {
                print("FAIL: AgentBoard main panel must be tracked and expose writable AXSize"); exit(1)
            }
            let original = live.globalFrame
            let full = CGRect(x: original.minX, y: screen.workArea.minY, width: original.width, height: screen.workArea.height)
            let small = CGRect(x: original.minX, y: screen.workArea.minY, width: original.width, height: 600)
            if CommandLine.arguments.contains("--recovery") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBoardRecovery-" + UUID().uuidString)
                let recovery = Recovery(directory: directory, applications: { apps })
                recovery.enabled = true; recovery.start(rememberCurrent: true)
                let end = Date().addingTimeInterval(20)
                while recovery.savedAt == nil && Date() < end { try? await Task.sleep(nanoseconds: 250_000_000) }
                guard let before = try? LayoutRepository(directory: directory).load().first, before.windows.count == 1 else {
                    recovery.stop(); print("FAIL: panel was not saved"); exit(1)
                }
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                _ = await access.move(live, to: small)
                try? await Task.sleep(nanoseconds: 500_000_000)
                let protected = (try? LayoutRepository(directory: directory).load().first) == before
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                let deadline = Date().addingTimeInterval(50)
                while !recovery.status.contains("복원 완료") && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
                let restored = AX.rect(live.element).map { Geometry.close($0, original) } ?? false
                recovery.stop()
                _ = await access.move(live, to: original)
                try? FileManager.default.removeItem(at: directory)
                guard protected && restored else { print("FAIL: panel sleep recovery", recovery.status); exit(1) }
                print("PASS: AgentBoard snapshot protected during sleep and full height restored on wake")
                exit(0)
            }
            let shrunk = await access.move(live, to: small)
            let expanded = await access.move(live, to: full)
            let final = AX.rect(live.element)
            if !CommandLine.arguments.contains("--fill") { _ = await access.move(live, to: original) }
            guard shrunk, expanded, let final, Geometry.close(final, full) else {
                print("FAIL: external resize did not match requested frame", String(describing: final), full); exit(1)
            }
            print("PASS: accessory panel tracked, AX resize to 600pt and full height", final)
            exit(0)
        }
        app.run()
    }
}
