import Foundation
import CoreGraphics
import DockpinCore

// Standalone checks also run on Command Line Tools installations without XCTest.
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { if !value { fatalError("Expected true", file: file, line: line) } }
func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(!value, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { if a != b { fatalError("Expected \(a) == \(b)", file: file, line: line) } }
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(a != b, file: file, line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(a > b, file: file, line: line) }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(a < b, file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(value == nil, file: file, line: line) }

@main struct LayoutTests {
    static func main() throws {
        let suite = LayoutTests()
        suite.testWakeFreezesBaselineAndRestartsSettleOnDisplayChange()
        suite.testIdenticalDisplayNamesDoNotConfuseIdentityOrOrder()
        suite.testRelativeCoordinatesFollowScreenOriginAndKeepPointSize()
        suite.testSmallerScreenClampsToWorkArea()
        suite.testExposedBottomAvoidsMacBookBelowTarget()
        suite.testRuntimeIdentityWinsOverDuplicateTitle()
        suite.testAmbiguousTitlesAndReusedPIDsAreNeverGuessed()
        suite.testStableUniqueIdentifierSurvivesTitleChange()
        try suite.testRepositoryRoundTripAndMalformedFileIsolation()
        suite.testOnlyAgentBoardMainPanelIsIncluded()
        print("PASS: 10 recovery, geometry, identity and persistence scenarios")
    }
    func screen(_ id: String, _ x: Double = 0, _ y: Double = 0, _ width: Double = 2560, _ height: Double = 1440) -> DisplaySnapshot {
        let r = CGRect(x: x, y: y, width: width, height: height)
        return DisplaySnapshot(id: id, name: "DELL P2725QE", bounds: r, workArea: r.insetBy(dx: 0, dy: 24))
    }
    func testOnlyAgentBoardMainPanelIsIncluded() {
        XCTAssertTrue(WindowPolicy.includesApplication(bundleID: "app.agentboard.mac", regular: false))
        XCTAssertFalse(WindowPolicy.includesApplication(bundleID: "com.apple.controlcenter", regular: false))
        XCTAssertTrue(WindowPolicy.includesWindow(bundleID: "app.agentboard.mac", subrole: "AXSystemDialog", identifier: "app.agentboard.panel"))
        XCTAssertFalse(WindowPolicy.includesWindow(bundleID: "app.agentboard.mac", subrole: "AXSystemDialog", identifier: "rename-dialog"))
        XCTAssertFalse(WindowPolicy.includesWindow(bundleID: "another.app", subrole: "AXSystemDialog", identifier: "app.agentboard.panel"))
    }
    func window(_ id: String = "window", _ display: String = "a") -> WindowSnapshot {
        WindowSnapshot(id: id, bundleID: "test.app", pid: 10, launchedAt: Date(timeIntervalSince1970: 1), title: "same title", displayID: display, frame: CGRect(x: 50, y: 60, width: 900, height: 700))
    }
    func testWakeFreezesBaselineAndRestartsSettleOnDisplayChange() {
        var gate = RecoveryGate()
        let now = Date()
        gate.sleep(); XCTAssertFalse(gate.canCapture)
        gate.displayChanged(now: now); XCTAssertEqual(gate.phase, .sleeping)
        gate.wake(now: now); XCTAssertFalse(gate.ready(now: now.addingTimeInterval(2.9)))
        let generation = gate.generation
        gate.displayChanged(now: now.addingTimeInterval(2))
        XCTAssertGreaterThan(gate.generation, generation)
        XCTAssertFalse(gate.ready(now: now.addingTimeInterval(4)))
        XCTAssertTrue(gate.ready(now: now.addingTimeInterval(5)))
        XCTAssertEqual(gate.deadline, now.addingTimeInterval(60))
        gate.begin(); XCTAssertFalse(gate.canCapture)
        gate.finish(success: false); XCTAssertFalse(gate.canCapture)
        gate.remember(); XCTAssertTrue(gate.canCapture)
    }
    func testIdenticalDisplayNamesDoNotConfuseIdentityOrOrder() {
        XCTAssertEqual(Geometry.configurationID([screen("a"), screen("b")]), Geometry.configurationID([screen("b"), screen("a")]))
        XCTAssertNotEqual(Geometry.configurationID([screen("a")]), Geometry.configurationID([screen("b")]))
    }
    func testRelativeCoordinatesFollowScreenOriginAndKeepPointSize() {
        let result = Geometry.target(window(), savedDisplay: screen("a"), current: screen("a", -2560, -400))
        XCTAssertEqual(result, CGRect(x: -2510, y: -340, width: 900, height: 700))
    }
    func testSmallerScreenClampsToWorkArea() {
        var w = window(); w.frame = CGRect(x: 2000, y: 1200, width: 1600, height: 1000)
        let smaller = screen("a", 0, 0, 1280, 800)
        let target = Geometry.target(w, savedDisplay: screen("a"), current: smaller)
        XCTAssertEqual(target, smaller.workArea)
    }
    func testExposedBottomAvoidsMacBookBelowTarget() {
        let a = screen("a"), b = screen("b", 725, 1440, 1728, 1117)
        let edge = Geometry.exposedBottom(of: a, among: [a,b])!
        XCTAssertLessThan(edge.x, 725); XCTAssertEqual(edge.y, 1439)
        XCTAssertNil(Geometry.exposedBottom(of: a, among: [a,screen("c",0,1440)]))
    }
    func testRuntimeIdentityWinsOverDuplicateTitle() {
        let a = window("a"), b = window("b")
        XCTAssertEqual(WindowMatcher.match(a, current: [b,a], original: [a,b])?.id, "a")
    }
    func testAmbiguousTitlesAndReusedPIDsAreNeverGuessed() {
        let a = window("a"), b = window("b")
        XCTAssertNil(WindowMatcher.match(a, current: [window("new")], original: [a,b]))
        var relaunched = window("new"); relaunched.launchedAt = Date(timeIntervalSince1970: 2)
        XCTAssertNil(WindowMatcher.match(a, current: [relaunched], original: [a]))
    }
    func testStableUniqueIdentifierSurvivesTitleChange() {
        var a = window("a"); a.identifier = "unique"
        var b = a; b.id = "b"; b.title = "changed"
        XCTAssertEqual(WindowMatcher.match(a, current: [b], original: [a])?.id, "b")
    }
    func testRepositoryRoundTripAndMalformedFileIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = LayoutRepository(directory: directory)
        let snapshot = LayoutSnapshot(displays: [screen("a")], windows: [window()], dock: DockSnapshot(displayID: "a", size: 0.5))
        try repo.save(snapshot)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
        XCTAssertEqual(try repo.load(), [snapshot])
        var newer = snapshot; newer.windows = []
        try repo.save(newer); XCTAssertEqual(try repo.load(), [newer])
    }
}
