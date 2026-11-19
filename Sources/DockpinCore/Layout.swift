import Foundation
import CoreGraphics
import CryptoKit

public enum WindowPolicy {
    public static func includesApplication(bundleID: String, regular: Bool) -> Bool {
        regular || bundleID == "app.agentboard.mac"
    }
    public static func includesWindow(bundleID: String, subrole: String, identifier: String) -> Bool {
        subrole == "AXStandardWindow" ||
            (bundleID == "app.agentboard.mac" && subrole == "AXSystemDialog" && identifier == "app.agentboard.panel")
    }
}

public struct DisplaySnapshot: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var bounds: CGRect
    public var workArea: CGRect
    public init(id: String, name: String, bounds: CGRect, workArea: CGRect) {
        self.id = id; self.name = name; self.bounds = bounds; self.workArea = workArea
    }
}

public struct WindowSnapshot: Codable, Equatable, Identifiable {
    public var id: String
    public var bundleID: String
    public var pid: Int32
    public var launchedAt: Date?
    public var identifier: String
    public var document: String
    public var title: String
    public var displayID: String
    public var frame: CGRect
    public init(id: String, bundleID: String, pid: Int32, launchedAt: Date?, identifier: String = "", document: String = "", title: String = "", displayID: String, frame: CGRect) {
        self.id = id; self.bundleID = bundleID; self.pid = pid; self.launchedAt = launchedAt
        self.identifier = identifier; self.document = document; self.title = title
        self.displayID = displayID; self.frame = frame
    }
}

public struct DockSnapshot: Codable, Equatable {
    public var displayID: String
    public var size: Double?
    public var magnification: Bool?
    public var magnificationSize: Double?
    public init(displayID: String, size: Double? = nil, magnification: Bool? = nil, magnificationSize: Double? = nil) {
        self.displayID = displayID; self.size = size; self.magnification = magnification; self.magnificationSize = magnificationSize
    }
}

public struct LayoutSnapshot: Codable, Equatable {
    public var version = 1
    public var savedAt: Date
    public var displays: [DisplaySnapshot]
    public var windows: [WindowSnapshot]
    public var dock: DockSnapshot?
    public var configurationID: String { Geometry.configurationID(displays) }
    public init(savedAt: Date = Date(), displays: [DisplaySnapshot], windows: [WindowSnapshot], dock: DockSnapshot?) {
        self.savedAt = savedAt; self.displays = displays; self.windows = windows; self.dock = dock
    }
}

public enum Geometry {
    public static func configurationID(_ screens: [DisplaySnapshot]) -> String { screens.map(\.id).sorted().joined(separator: "|") }
    public static func display(for frame: CGRect, in screens: [DisplaySnapshot]) -> DisplaySnapshot? {
        screens.filter { $0.bounds.intersects(frame) }.max { a, b in
            let x = a.bounds.intersection(frame), y = b.bounds.intersection(frame)
            return x.width * x.height < y.width * y.height
        }
    }
    public static func target(_ window: WindowSnapshot, savedDisplay: DisplaySnapshot, current: DisplaySnapshot) -> CGRect {
        var frame = window.frame.offsetBy(dx: current.bounds.minX, dy: current.bounds.minY)
        // Keep intentionally spanning windows when the display size is unchanged.
        if savedDisplay.bounds.size != current.bounds.size {
            frame.size.width = min(frame.width, current.workArea.width)
            frame.size.height = min(frame.height, current.workArea.height)
            frame.origin.x = max(current.workArea.minX, min(frame.minX, current.workArea.maxX - frame.width))
            frame.origin.y = max(current.workArea.minY, min(frame.minY, current.workArea.maxY - frame.height))
        }
        return frame
    }
    public static func close(_ a: CGRect, _ b: CGRect, tolerance: Double = 2) -> Bool {
        abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance && abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
    }
    public static func exposedBottom(of target: DisplaySnapshot, among displays: [DisplaySnapshot]) -> CGPoint? {
        var segments = [(target.bounds.minX + 8, target.bounds.maxX - 8)]
        let y = target.bounds.maxY + 1
        for other in displays where other.id != target.id && other.bounds.minY <= y && other.bounds.maxY > y {
            segments = segments.flatMap { lo, hi -> [(CGFloat, CGFloat)] in
                if other.bounds.maxX <= lo || other.bounds.minX >= hi { return [(lo, hi)] }
                return [(lo, min(hi, other.bounds.minX - 8)), (max(lo, other.bounds.maxX + 8), hi)].filter { $0.1 > $0.0 }
            }
        }
        guard let best = segments.filter({ $0.1 > $0.0 }).max(by: { $0.1-$0.0 < $1.1-$1.0 }) else { return nil }
        return CGPoint(x: (best.0 + best.1)/2, y: target.bounds.maxY - 1)
    }
}

public enum WindowMatcher {
    public static func match(_ saved: WindowSnapshot, current: [WindowSnapshot], original: [WindowSnapshot]) -> WindowSnapshot? {
        let candidates = current.filter { $0.bundleID == saved.bundleID && $0.pid == saved.pid && $0.launchedAt == saved.launchedAt }
        if let same = candidates.first(where: { $0.id == saved.id }) { return same }
        // A relaunched application or reused PID must never inherit an old window.
        guard saved.launchedAt != nil else { return nil }
        let originals = original.filter { $0.bundleID == saved.bundleID && $0.pid == saved.pid && $0.launchedAt == saved.launchedAt }
        for key in [\WindowSnapshot.identifier, \.document, \.title] {
            let value = saved[keyPath: key]
            guard !value.isEmpty else { continue }
            let matches = candidates.filter { $0[keyPath: key] == value }
            if matches.count == 1 && originals.filter({ $0[keyPath: key] == value }).count == 1 { return matches[0] }
        }
        return nil
    }
}

public struct LayoutProtection {
    public var baseline: LayoutSnapshot
    public var windowIDs: Set<String>
    public var dock: Bool
    public init(baseline: LayoutSnapshot, windowIDs: Set<String>, dock: Bool) {
        self.baseline = baseline; self.windowIDs = windowIDs; self.dock = dock
    }
    public var isEmpty: Bool { windowIDs.isEmpty && !dock }
    public func merging(_ fresh: LayoutSnapshot) -> LayoutSnapshot {
        guard fresh.configurationID == baseline.configurationID else { return fresh }
        var merged = fresh
        for saved in baseline.windows where windowIDs.contains(saved.id) {
            if let match = WindowMatcher.match(saved, current: fresh.windows, original: baseline.windows),
               let index = merged.windows.firstIndex(where: { $0.id == match.id }),
               let oldScreen = baseline.displays.first(where: { $0.id == saved.displayID }),
               let screen = fresh.displays.first(where: { $0.id == saved.displayID }) {
                // Keep current identity and title while protecting only the failed geometry.
                merged.windows[index].displayID = saved.displayID
                merged.windows[index].frame = Geometry.target(saved, savedDisplay: oldScreen, current: screen)
                    .offsetBy(dx: -screen.bounds.minX, dy: -screen.bounds.minY)
            } else { merged.windows.append(saved) }
        }
        if dock { merged.dock = baseline.dock }
        return merged
    }
}

public struct RecoveryGate {
    public enum Phase: String { case tracking, sleeping, settling, restoring }
    public private(set) var phase: Phase = .tracking
    public private(set) var generation = 0
    public private(set) var changedAt = Date.distantPast
    public private(set) var deadline = Date.distantFuture
    public init() {}
    public var canCapture: Bool { phase == .tracking }
    public mutating func sleep() { generation += 1; phase = .sleeping }
    public mutating func wake(now: Date) { generation += 1; phase = .settling; changedAt = now; deadline = now.addingTimeInterval(60) }
    public mutating func displayChanged(now: Date) {
        if phase == .sleeping { generation += 1; return }
        if phase == .tracking { deadline = now.addingTimeInterval(60) }
        generation += 1; phase = .settling; changedAt = now
    }
    public func ready(now: Date) -> Bool { phase == .settling && now.timeIntervalSince(changedAt) >= 3 }
    public mutating func begin() { phase = .restoring }
    public mutating func finish() { phase = .tracking }
    public mutating func remember() { generation += 1; phase = .tracking }
}

public final class LayoutRepository {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> [LayoutSnapshot] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(LayoutSnapshot.self, from: data), value.version == 1,
                      !value.displays.isEmpty, value.displays.allSatisfy({ valid($0.bounds) && valid($0.workArea) }),
                      value.windows.allSatisfy({ w in valid(w.frame) && value.displays.contains(where: { $0.id == w.displayID }) }) else { return nil }
                return value
            }
    }
    private func valid(_ r: CGRect) -> Bool { [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0 }
    public func save(_ snapshot: LayoutSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let filename = SHA256.hash(data: Data(snapshot.configurationID.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(filename + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
