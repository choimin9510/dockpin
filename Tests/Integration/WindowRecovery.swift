import AppKit
import DockpinCore

// Exercises the production recovery path against an explicitly selected running app.
@main enum WindowRecovery {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard let bundle = CommandLine.arguments.dropFirst().first, AXIsProcessTrusted() else {
                print("Usage: WindowRecovery bundle.identifier (Accessibility required)"); exit(1)
            }
            let apps = { AppIdentity.current().filter { $0.bundle == bundle } }
            let access = WindowAccess(), screens = Screens.current()
            let scan = await access.scan(apps: apps(), displays: screens)
            guard let window = scan.windows.first else { print("FAIL: no eligible window"); exit(1) }
            let original = window.globalFrame
            let root = AXUIElementCreateApplication(window.snapshot.pid)
            let originalEnhanced = AX.value(root, "AXEnhancedUserInterface") as? Bool
            let displaced = CGRect(x: original.minX, y: original.minY, width: max(400, original.width - 100), height: max(300, original.height - 80))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockpinLive-" + UUID().uuidString)
            let repository = LayoutRepository(directory: directory)
            let baseline = LayoutSnapshot(displays: screens, windows: scan.windows.map(\.snapshot), dock: nil)
            do { try repository.save(baseline) } catch { print("FAIL:", error); exit(1) }
            let recovery = Recovery(directory: directory, applications: apps)
            recovery.enabled = true; recovery.start()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            _ = await access.move(window, to: displaced)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            let firstDeadline = Date().addingTimeInterval(60)
            while AX.rect(window.element).map({ !Geometry.close($0, original) }) == true && Date() < firstDeadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let rebound = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, recovery.input.idle else { return }
                _ = await access.move(window, to: displaced)
            }
            let end = Date().addingTimeInterval(50)
            while !recovery.status.contains("복원 완료") && Date() < end { try? await Task.sleep(nanoseconds: 250_000_000) }
            let frameOK = AX.rect(window.element).map { Geometry.close($0, original) } ?? false
            let unchanged = (try? repository.load().first) == baseline
            let diagnostic = (try? Data(contentsOf: directory.appendingPathComponent("recovery-status.txt"))) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: diagnostic)) as? [String: Any]
            let details = (json?["lastRecovery"] as? [String: Any])?["windows"] as? [[String: Any]] ?? []
            let retried = details.contains { ($0["attempts"] as? Int ?? 0) >= 2 }
            rebound.cancel(); recovery.stop()
            _ = await access.move(window, to: original)
            let modePreserved = AX.value(root, "AXEnhancedUserInterface") as? Bool == originalEnhanced
            let result = frameOK && unchanged && retried && modePreserved && recovery.status.contains("복원 완료")
            print(result ? "PASS:" : "FAIL:", bundle, "actual restore + late resize; frame", frameOK, "baseline", unchanged, "retried", retried, recovery.status)
            print(String(data: diagnostic, encoding: .utf8) ?? "")
            try? FileManager.default.removeItem(at: directory)
            exit(result ? 0 : 1)
        }
        app.run()
    }
}
