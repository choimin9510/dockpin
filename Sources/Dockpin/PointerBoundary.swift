import AppKit

struct Display: Identifiable {
    let id: String
    let name: String
    let bounds: CGRect
}

enum Boundary {
    static func clamp(_ point: CGPoint, displays: [Display], allowed: String) -> CGPoint? {
        guard let screen = displays.first(where: { $0.bounds.contains(point) }), screen.id != allowed,
              point.y >= screen.bounds.maxY - 3 else { return nil }
        // Preserve crossings to a display physically below this edge.
        let below = CGPoint(x: point.x, y: screen.bounds.maxY + 1)
        guard !displays.contains(where: { $0.bounds.contains(below) }) else { return nil }
        return CGPoint(x: point.x, y: screen.bounds.maxY - 4)
    }

    @discardableResult
    static func adjust(_ event: CGEvent, displays: [Display], allowed: String, bypass: Bool = false) -> Bool {
        guard !bypass, event.type == .mouseMoved,
              !event.flags.contains(.maskAlternate),
              event.getIntegerValueField(.eventSourceUserData) != InputActivity.marker,
              event.getIntegerValueField(.mouseEventDeltaY) >= 0,
              let point = clamp(event.location, displays: displays, allowed: allowed) else { return false }
        // Forward every move. Dropping an edge event also drops sideways/escape motion.
        event.location = point
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        return true
    }
}
