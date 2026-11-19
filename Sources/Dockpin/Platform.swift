import AppKit
import ApplicationServices
import DockpinCore

enum AX {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    static func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
    static func eligible(_ element: AXUIElement, bundleID: String) -> Bool {
        WindowPolicy.includesWindow(bundleID: bundleID,
                                    subrole: value(element, kAXSubroleAttribute) as? String ?? "",
                                    identifier: value(element, kAXIdentifierAttribute) as? String ?? "") &&
            value(element, kAXMinimizedAttribute) as? Bool != true && value(element, "AXFullScreen") as? Bool != true
    }
}

enum Screens {
    static func current() -> [DisplaySnapshot] {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let visible = screen.visibleFrame
            return DisplaySnapshot(id: CFUUIDCreateString(nil, uuid) as String, name: screen.localizedName,
                                   bounds: CGDisplayBounds(number.uint32Value),
                                   workArea: CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height))
        }
    }
}

struct AppIdentity {
    var pid: pid_t
    var bundle: String
    var launched: Date?
    var hidden: Bool
    static func current() -> [AppIdentity] {
        NSWorkspace.shared.runningApplications.filter {
            WindowPolicy.includesApplication(bundleID: $0.bundleIdentifier ?? "", regular: $0.activationPolicy == .regular) && $0.processIdentifier != getpid()
        }.map {
            AppIdentity(pid: $0.processIdentifier, bundle: $0.bundleIdentifier ?? $0.executableURL?.path ?? "", launched: $0.launchDate, hidden: $0.isHidden)
        }
    }
}
struct LiveWindow {
    var snapshot: WindowSnapshot
    var element: AXUIElement
    var globalFrame: CGRect
}
struct WindowScan {
    var windows: [LiveWindow] = []
    var unavailable: Set<pid_t> = []
}

final class WritePermit {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

final class WindowAccess {
    private let queue = DispatchQueue(label: "app.dockpin.windows", qos: .userInitiated)
    private var previous: [LiveWindow] = []
    func scan(apps: [AppIdentity], displays: [DisplaySnapshot]) async -> WindowScan {
        await withCheckedContinuation { continuation in queue.async {
            var result = WindowScan()
            for app in apps where !app.hidden {
                let root = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(root, 0.15)
                guard let windows = AX.value(root, kAXWindowsAttribute) as? [AXUIElement] else { result.unavailable.insert(app.pid); continue }
                for element in windows where AX.eligible(element, bundleID: app.bundle) {
                    AXUIElementSetMessagingTimeout(element, 0.15)
                    guard let frame = AX.rect(element) else { result.unavailable.insert(app.pid); continue }
                    guard let screen = Geometry.display(for: frame, in: displays), AX.settable(element, kAXPositionAttribute) else { continue }
                    let prior = self.previous.first { $0.snapshot.pid == app.pid && $0.snapshot.launchedAt == app.launched && CFEqual($0.element, element) }
                    let snapshot = WindowSnapshot(id: prior?.snapshot.id ?? UUID().uuidString, bundleID: app.bundle, pid: app.pid, launchedAt: app.launched,
                                                  identifier: AX.value(element, kAXIdentifierAttribute) as? String ?? "",
                                                  document: AX.value(element, kAXDocumentAttribute) as? String ?? "",
                                                  title: AX.value(element, kAXTitleAttribute) as? String ?? "", displayID: screen.id,
                                                  frame: frame.offsetBy(dx: -screen.bounds.minX, dy: -screen.bounds.minY))
                    result.windows.append(LiveWindow(snapshot: snapshot, element: element, globalFrame: frame))
                }
            }
            // Keep identities through temporary AX timeouts, but discard terminated processes.
            self.previous = result.windows + self.previous.filter { old in
                result.unavailable.contains(old.snapshot.pid) &&
                    apps.contains(where: { $0.pid == old.snapshot.pid && $0.launched == old.snapshot.launchedAt }) &&
                    !result.windows.contains(where: { CFEqual($0.element, old.element) })
            }
            continuation.resume(returning: result)
        } }
    }
    func move(_ live: LiveWindow, to frame: CGRect, permit: WritePermit = WritePermit()) async -> Bool {
        await withCheckedContinuation { continuation in queue.async {
            let e = live.element
            guard !permit.cancelled, AX.eligible(e, bundleID: live.snapshot.bundleID) else { continuation.resume(returning: false); return }
            if let current = AX.rect(e), Geometry.close(current, frame) { continuation.resume(returning: true); return }
            let root = AXUIElementCreateApplication(live.snapshot.pid)
            AXUIElementSetMessagingTimeout(root, 0.15)
            let enhancedUI = "AXEnhancedUserInterface" as CFString
            // AppKit animates AX writes in this mode; a following position write can undo the resize.
            // Restore the original accessibility mode even if user input cancels the geometry write.
            let wasEnhanced = AX.value(root, enhancedUI as String) as? Bool == true
            if wasEnhanced { _ = AXUIElementSetAttributeValue(root, enhancedUI, kCFBooleanFalse) }
            // cmux applies this attribute even when returning AXError.notImplemented.
            defer { if wasEnhanced { _ = AXUIElementSetAttributeValue(root, enhancedUI, kCFBooleanTrue) } }
            var point = frame.origin, size = frame.size
            let p = AXValueCreate(.cgPoint, &point)!, s = AXValueCreate(.cgSize, &size)!
            // Some applications constrain size using the old screen until the first move.
            if !permit.cancelled { _ = AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p) }
            if !permit.cancelled, AX.settable(e, kAXSizeAttribute) { _ = AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, s) }
            if !permit.cancelled { _ = AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p) }
            continuation.resume(returning: AX.rect(e).map { Geometry.close($0, frame) } ?? false)
        } }
    }
}

final class WindowObservations {
    struct Entry { var observer: AXObserver; var root: AXUIElement; var windows: [AXUIElement] }
    private var entries: [pid_t: Entry] = [:]
    var changed: ((AXUIElement, String) -> Void)?
    func update(_ windows: [LiveWindow], apps: [AppIdentity]) {
        for pid in Array(entries.keys) where !apps.contains(where: { $0.pid == pid }) {
            if let entry = entries.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes) }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for app in apps {
            if entries[app.pid] == nil {
                var observer: AXObserver?
                let callback: AXObserverCallback = { _, element, name, info in
                    guard let info = info else { return }
                    Unmanaged<WindowObservations>.fromOpaque(info).takeUnretainedValue().changed?(element, name as String)
                }
                guard AXObserverCreate(app.pid, callback, &observer) == .success, let observer = observer else { continue }
                let root = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(root, 0.1)
                AXObserverAddNotification(observer, root, kAXWindowCreatedNotification as CFString, context)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                entries[app.pid] = Entry(observer: observer, root: root, windows: [])
            }
            guard var entry = entries[app.pid] else { continue }
            let current = windows.filter { $0.snapshot.pid == app.pid }.map(\.element)
            let names = [kAXMovedNotification, kAXResizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification]
            for old in entry.windows where !current.contains(where: { CFEqual($0, old) }) {
                for name in names { AXObserverRemoveNotification(entry.observer, old, name as CFString) }
            }
            for new in current where !entry.windows.contains(where: { CFEqual($0, new) }) {
                for name in names { AXObserverAddNotification(entry.observer, new, name as CFString, context) }
            }
            entry.windows = current; entries[app.pid] = entry
        }
    }
    func stop() {
        for e in entries.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(e.observer), .commonModes) }
        entries.removeAll(); changed = nil
    }
    deinit { stop() }
}

final class InputActivity {
    static let marker: Int64 = 0x444F434B50494E
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var lastInput = Date.distantPast
    private(set) var lastDrag = Date.distantPast
    var onInput: (() -> Void)?
    var available: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var idle: Bool { available && Date().timeIntervalSince(lastInput) >= 2 && !CGEventSource.buttonState(.combinedSessionState, button: .left) && !CGEventSource.buttonState(.combinedSessionState, button: .right) }
    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown, .keyUp, .flagsChanged, .scrollWheel]
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: types.reduce(0) { $0 | (1 << $1.rawValue) }, callback: { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<InputActivity>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.lastInput = Date()
                owner.onInput?()
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if event.getIntegerValueField(.eventSourceUserData) != InputActivity.marker {
                owner.lastInput = Date()
                owner.onInput?()
                if type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged { owner.lastDrag = Date() }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap = tap {
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    deinit { if let tap = tap { CFMachPortInvalidate(tap) }; if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) } }
}

final class DockAccess {
    private let queue = DispatchQueue(label: "app.dockpin.dock")
    var moving = false
    private(set) var permissionStatus: OSStatus = OSStatus(procNotFound)
    var automationAllowed: Bool { permissionStatus == noErr }
    @MainActor func checkAutomation(request: Bool = false) async -> Bool {
        // System Events exits when idle. -600 means it is not running, not denied permission.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systemevents") else {
                permissionStatus = OSStatus(procNotFound); return false
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
            catch { permissionStatus = OSStatus(procNotFound); return false }
        }
        permissionStatus = await withCheckedContinuation { continuation in queue.async {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            continuation.resume(returning: AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, request))
        } }
        return automationAllowed
    }
    func currentDisplay(_ displays: [DisplaySnapshot]) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        guard let children = AX.value(root, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { AX.value($0, kAXRoleAttribute) as? String == kAXListRole }), let frame = AX.rect(list) else { return nil }
        return Geometry.display(for: frame, in: displays)?.id
    }
    @MainActor private func script(_ source: String) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { continuation in queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            continuation.resume(returning: error == nil ? result : nil)
        } }
    }
    @MainActor func settings(displayID: String, request: Bool = false) async -> DockSnapshot? {
        guard await checkAutomation(request: request) else { return nil }
        guard let result = await script("tell application \"System Events\" to tell dock preferences to return {dock size, magnification, magnification size}") else { return nil }
        guard let size = result.atIndex(1)?.doubleValue, let magnify = result.atIndex(2)?.booleanValue, let maxSize = result.atIndex(3)?.doubleValue else { return nil }
        return DockSnapshot(displayID: displayID, size: size, magnification: magnify, magnificationSize: maxSize)
    }
    @MainActor func applySettings(_ snapshot: DockSnapshot, cancelled: () -> Bool = { false }) async -> Bool {
        guard snapshot.size != nil else { return true }
        guard let current = await settings(displayID: snapshot.displayID) else { return false }
        guard !cancelled() else { return false }
        if sameSettings(current, snapshot) { return true }
        var commands: [String] = []
        if let size = snapshot.size { commands.append("set dock size to \(min(1, max(0, size)))") }
        if let mag = snapshot.magnification { commands.append("set magnification to \(mag ? "true" : "false")") }
        if let size = snapshot.magnificationSize { commands.append("set magnification size to \(min(1, max(0, size)))") }
        guard await script("tell application \"System Events\" to tell dock preferences\n" + commands.joined(separator: "\n") + "\nend tell") != nil,
              let after = await settings(displayID: snapshot.displayID) else { return false }
        return sameSettings(after, snapshot)
    }
    private func sameSettings(_ a: DockSnapshot, _ b: DockSnapshot) -> Bool {
        abs((a.size ?? 0) - (b.size ?? 0)) < 0.001 && a.magnification == b.magnification && abs((a.magnificationSize ?? 0) - (b.magnificationSize ?? 0)) < 0.001
    }
    @MainActor func relocate(to target: DisplaySnapshot, displays: [DisplaySnapshot], input: InputActivity, cancelled: () -> Bool) async -> Bool {
        if currentDisplay(displays) == target.id { return true }
        guard input.idle, let point = Geometry.exposedBottom(of: target, among: displays), let original = CGEvent(source: nil)?.location else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let started = Date()
        func interrupted() -> Bool { cancelled() || !input.available || input.lastInput >= started }
        func post(_ location: CGPoint, delta: Int64 = 0) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: InputActivity.marker)
            event.setIntegerValueField(.mouseEventDeltaY, value: delta)
            event.post(tap: .cghidEventTap)
        }
        moving = true
        defer { moving = false; if !interrupted() { post(original) } }
        post(CGPoint(x: point.x, y: point.y - 20))
        try? await Task.sleep(nanoseconds: 100_000_000)
        for index in 0..<30 {
            guard !interrupted() else { return false }
            post(point, delta: 10)
            try? await Task.sleep(nanoseconds: 50_000_000)
            if index % 4 == 0, currentDisplay(displays) == target.id { return true }
        }
        return !interrupted() && currentDisplay(displays) == target.id
    }
}
