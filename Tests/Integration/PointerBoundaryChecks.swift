import AppKit
import DockpinCore

@main enum PointerBoundaryChecks {
    static let marker: Int64 = 0x44504E54455354
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    static func event(_ point: CGPoint, dx: Int64 = 0, dy: Int64 = 0, tag: Int64 = marker) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.setIntegerValueField(.mouseEventDeltaX, value: dx)
        e.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return e
    }
    static func unitChecks() throws {
        let displays = [Display(id: "a", name: "A", bounds: CGRect(x: 0,y: 0,width: 100,height: 100)),
                        Display(id: "b", name: "B", bounds: CGRect(x: 100,y: 0,width: 100,height: 100))]
        let down = event(CGPoint(x: 150,y: 99), dx: 9, dy: 12)
        try require(Boundary.adjust(down, displays: displays, allowed: "a"), "downward pressure was not constrained")
        try require(down.location == CGPoint(x: 150,y: 96) && down.getIntegerValueField(.mouseEventDeltaY) == 0 && down.getIntegerValueField(.mouseEventDeltaX) == 9, "diagonal movement lost horizontal motion")
        let up = event(CGPoint(x: 150,y: 99), dx: 1, dy: -1)
        try require(!Boundary.adjust(up, displays: displays, allowed: "a") && up.location.y == 99 && up.getIntegerValueField(.mouseEventDeltaY) == -1, "small upward escape was intercepted")
        let sideways = event(CGPoint(x: 170,y: 99), dx: 20)
        try require(Boundary.adjust(sideways, displays: displays, allowed: "a") && sideways.location.x == 170 && sideways.getIntegerValueField(.mouseEventDeltaX) == 20, "sideways movement was lost")
        let allowed = event(CGPoint(x: 50,y: 99), dy: 10)
        try require(!Boundary.adjust(allowed, displays: displays, allowed: "a"), "selected display was constrained")
        let option = event(CGPoint(x: 150,y: 99), dy: 10); option.flags = .maskAlternate
        try require(!Boundary.adjust(option, displays: displays, allowed: "a"), "Option bypass failed")
        let restore = event(CGPoint(x: 150,y: 99), dy: 10, tag: InputActivity.marker)
        try require(!Boundary.adjust(restore, displays: displays, allowed: "a"), "Dock recovery was constrained")
        try require(!Boundary.adjust(event(CGPoint(x: 150,y: 99), dy: 10), displays: displays, allowed: "a", bypass: true), "disabled filter was active")
        let below = Display(id: "c", name: "C", bounds: CGRect(x: 100,y: 100,width: 100,height: 100))
        try require(!Boundary.adjust(event(CGPoint(x: 150,y: 99), dy: 10), displays: displays + [below], allowed: "a"), "vertical monitor crossing was constrained")
        print("PASS: downward and diagonal pressure, sideways and upward escape, selected display, Option, recovery and monitor crossings")
    }
    final class Probe {
        var tap: CFMachPort?
        var source: CFRunLoopSource?
        var intercepted = 0
        var received = 0
        var interrupted = false
        let displays: [Display]
        let allowed: String
        init(_ displays: [Display], allowed: String) { self.displays = displays; self.allowed = allowed }
        func start() throws {
            let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: types.reduce(0) { $0 | (1 << $1.rawValue) }, callback: { _, type, e, context in
                guard let context else { return Unmanaged.passUnretained(e) }
                let probe = Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    probe.interrupted = true; return Unmanaged.passUnretained(e)
                }
                guard e.getIntegerValueField(.eventSourceUserData) == marker else {
                    print("Live check interrupted:", type.rawValue, "tag", e.getIntegerValueField(.eventSourceUserData), "point", e.location,
                          "delta", e.getIntegerValueField(.mouseEventDeltaX), e.getIntegerValueField(.mouseEventDeltaY))
                    probe.interrupted = true; return Unmanaged.passUnretained(e)
                }
                probe.received += 1
                if Boundary.adjust(e, displays: probe.displays, allowed: probe.allowed) { probe.intercepted += 1 }
                return Unmanaged.passUnretained(e)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else { throw Failure(description: "Accessibility permission is required for the live pointer check") }
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        func stop() {
            if let tap { CFMachPortInvalidate(tap) }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        }
    }
    @MainActor static func liveCheck() async throws {
        let screens = Screens.current(), dock = DockAccess()
        guard let homeID = dock.currentDisplay(screens), let home = screens.first(where: { $0.id == homeID }),
              let other = screens.sorted(by: { $0.bounds.minX > $1.bounds.minX }).first(where: { $0.id != homeID && Geometry.exposedBottom(of: $0, among: screens) != nil }),
              let edge = Geometry.exposedBottom(of: other, among: screens), let original = CGEvent(source: nil)?.location else {
            throw Failure(description: "Two displays with an exposed bottom edge are required")
        }
        let probe = Probe(screens.map { Display(id: $0.id, name: $0.name, bounds: $0.bounds) }, allowed: homeID)
        try probe.start()
        defer { probe.stop(); if !probe.interrupted { CGWarpMouseCursorPosition(original) } }
        func send(_ point: CGPoint, dx: Int64 = 0, dy: Int64 = 0) async throws {
            try require(!probe.interrupted, "User input interrupted live pointer check")
            let e = event(point, dx: dx, dy: dy)
            e.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        try await send(CGPoint(x: edge.x, y: edge.y - 30))
        for _ in 0..<35 { try await send(edge, dy: 12) }
        let boundary = CGEvent(source: nil)!.location
        print("boundary pointer", boundary, "expected y", other.bounds.maxY - 4)
        let dockStayed = dock.currentDisplay(screens) == homeID
        let horizontal = CGPoint(x: edge.x + 100, y: edge.y)
        try await send(horizontal, dx: 100)
        let afterHorizontal = CGEvent(source: nil)!.location
        try await send(CGPoint(x: horizontal.x, y: edge.y - 1), dy: -1)
        try await send(CGPoint(x: horizontal.x, y: edge.y - 80), dy: -79)
        let afterUp = CGEvent(source: nil)!.location
        probe.stop()
        if !dockStayed && !probe.interrupted {
            let input = InputActivity(); input.start()
            try? await Task.sleep(nanoseconds: 2_100_000_000)
            _ = await dock.relocate(to: home, displays: screens, input: input, cancelled: { probe.interrupted })
        }
        try require(probe.received == 39, "pointer events were lost: \(probe.received)/39")
        try require(abs(boundary.y - (other.bounds.maxY - 4)) <= 1, "physical cursor was not constrained")
        try require(abs(afterHorizontal.x - horizontal.x) <= 1, "cursor froze during sideways movement")
        try require(abs(afterUp.y - (edge.y - 80)) <= 1, "cursor froze during upward escape")
        try require(dockStayed, "Dock moved to the protected display")
        print("PASS: actual pointer held at second-display edge for 2 seconds, moved sideways and escaped upward; Dock stayed pinned")
    }
    static func main() {
        do { try unitChecks() } catch { print("FAIL:", error); exit(1) }
        guard CommandLine.arguments.contains("--live") else { return }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await liveCheck(); exit(0) } catch { print("FAIL:", error); exit(1) }
        }
        app.run()
    }
}
