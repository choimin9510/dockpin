import AppKit
import DockpinCore

struct RecoveryTiming {
    var observation: TimeInterval = 30
    var timeout: TimeInterval = 60
    var stable: TimeInterval = 3
}

final class Recovery: ObservableObject {
    @Published var enabled = UserDefaults.standard.object(forKey: "restoreEnabled") as? Bool ?? true
    @Published var status = "배치를 확인하는 중"
    @Published var savedAt: Date?
    @Published var windowCount = 0
    @Published var automationAllowed = false
    @Published var busy = false
    let input = InputActivity()
    let dock = DockAccess()
    private let access = WindowAccess()
    private let observations = WindowObservations()
    private let repository: LayoutRepository
    private let applications: () -> [AppIdentity]
    private let isTrusted: () -> Bool
    private let diagnosticsURL: URL
    private var currentWrite: WritePermit?
    private var profiles: [String: LayoutSnapshot] = [:]
    private var protections: [String: LayoutProtection] = [:]
    private var lastRecovery: [String: Any] = [:]
    private var protectionRetryAt = Date.distantFuture
    private let timing: RecoveryTiming
    private var pending: LayoutSnapshot?
    private var gate = RecoveryGate()
    private var timer: Timer?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastScan = Date.distantPast
    private var live: [LiveWindow] = []
    private var captureTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var changedByUser: Set<String> = []
    private var restoreStarted = Date.distantFuture
    private var requestedAt: Date?
    private var waitReason = ""
    private var lastDisplayState: [DisplaySnapshot] = []
    private var dockSettings: DockSnapshot?
    private var settingsReadAt = Date.distantPast
    var selectedDisplay: () -> String = { "" }
    var dockEnabled: () -> Bool = { false }
    var dockConflict: () -> Bool = { false }
    var closePanel: () -> Void = {}
    var canRemember: Bool { !busy && gate.phase != .sleeping && gate.phase != .settling }

    init(directory: URL? = nil, applications: @escaping () -> [AppIdentity] = AppIdentity.current, isTrusted: @escaping () -> Bool = AXIsProcessTrusted, timing: RecoveryTiming = RecoveryTiming()) {
        let folder = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dockpin/Layouts", isDirectory: true)
        repository = LayoutRepository(directory: folder)
        self.applications = applications
        self.isTrusted = isTrusted
        self.timing = timing
        diagnosticsURL = directory?.appendingPathComponent("recovery-status.txt") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dockpin-recovery.json")
        do { for snapshot in try repository.load() { profiles[snapshot.configurationID] = snapshot } }
        catch { status = "저장된 배치를 읽지 못했어요: \(error.localizedDescription)" }
    }
    func start(rememberCurrent: Bool = false) {
        input.onWindowInteraction = { [weak self] in self?.currentWrite?.cancel() }
        lastDisplayState = Screens.current()
        pending = profiles[Geometry.configurationID(lastDisplayState)] ?? profiles.values.max(by: { $0.savedAt < $1.savedAt })
        savedAt = pending?.savedAt; windowCount = pending?.windows.count ?? 0
        observations.changed = { [weak self] element, name in
            guard let self = self else { return }
            if self.gate.phase == .settling || self.gate.phase == .restoring {
                if self.input.lastDrag > self.restoreStarted && Date().timeIntervalSince(self.input.lastDrag) < 1,
                   let window = self.live.first(where: { CFEqual($0.element, element) }) {
                    self.changedByUser.insert(window.snapshot.id)
                }
            } else if self.gate.canCapture {
                if Date().timeIntervalSince(self.input.lastDrag) < 1,
                   let window = self.live.first(where: { CFEqual($0.element, element) }) {
                    for key in Array(self.protections.keys) {
                        guard let protection = self.protections[key] else { continue }
                        for saved in protection.baseline.windows where protection.windowIDs.contains(saved.id) {
                            if WindowMatcher.match(saved, current: self.live.map(\.snapshot), original: protection.baseline.windows)?.id == window.snapshot.id {
                                self.protections[key]?.windowIDs.remove(saved.id)
                            }
                        }
                    }
                }
                self.requestCapture()
            }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.sleep() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { $0.sleep() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.sleep() }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, event) { $0.wake() }
        }
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(NSWorkspace.shared.notificationCenter, event) { $0.requestCapture() }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.displayChanged() }
        CGDisplayRegisterReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        if rememberCurrent {
            pending = nil; gate.remember(); requestCapture(force: true)
        } else if enabled { wake() } else { status = "자동 복원 꺼짐" }
        writeDiagnostics()
    }
    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, _, context in
        guard let context = context else { return }
        let owner = Unmanaged<Recovery>.fromOpaque(context).takeUnretainedValue()
        if Thread.isMainThread { owner.displayChanged() } else { DispatchQueue.main.async { [weak owner] in owner?.displayChanged() } }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping (Recovery) -> Void) {
        tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in if let self = self { action(self) } }))
    }
    private func freeze() {
        currentWrite?.cancel()
        captureTask?.cancel()
        if pending == nil { pending = profiles[Geometry.configurationID(lastDisplayState)] }
        restoreTask?.cancel()
        busy = false
    }
    private func sleep() {
        guard enabled else { return }
        freeze(); gate.sleep(); status = "잠자기 전 배치를 보호하는 중"; writeDiagnostics()
    }
    func wake() {
        guard enabled else { return }
        if gate.phase == .tracking || gate.phase == .sleeping || requestedAt == nil { requestedAt = Date() }
        freeze(); gate.wake(now: Date()); restoreStarted = Date(); changedByUser.removeAll()
        waitReason = "displaySettling"
        status = "화면이 다시 연결되기를 기다리는 중"
        writeDiagnostics()
    }
    private func displayChanged() {
        guard enabled else { return }
        if gate.phase == .tracking || requestedAt == nil { requestedAt = Date() }
        freeze(); gate.displayChanged(now: Date())
        waitReason = "displaySettling"
        if gate.phase != .sleeping { status = "화면 구성이 안정되기를 기다리는 중" }
        writeDiagnostics()
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "restoreEnabled")
        if value { wake() } else {
            freeze(); gate.remember(); pending = nil; status = "자동 복원 꺼짐"
        }
    }
    func restoreNow() {
        pending = profiles[Geometry.configurationID(Screens.current())] ?? pending
        guard pending != nil else { status = "먼저 현재 배치를 기억해 주세요"; return }
        closePanel(); freeze(); gate.wake(now: Date()); restoreStarted = Date(); changedByUser.removeAll()
        requestedAt = Date(); waitReason = "displaySettling"
        status = "화면이 안정되면 저장된 배치로 복원해요"
    }
    func rememberNow() {
        guard canRemember else { return }
        freeze(); pending = nil; protections.removeValue(forKey: Geometry.configurationID(Screens.current()))
        gate.remember(); requestCapture(force: true)
    }
    func requestAutomation() {
        closePanel()
        Task { @MainActor in
            let generation = gate.generation
            let setting = await dock.settings(displayID: selectedDisplay(), request: true)
            automationAllowed = dock.automationAllowed
            if generation == gate.generation, gate.canCapture {
                dockSettings = setting; settingsReadAt = Date()
                if automationAllowed, protections[Geometry.configurationID(Screens.current())]?.dock == true { restoreNow() }
                else { requestCapture(force: true) }
            }
            if !automationAllowed { status = "시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 System Events를 허용해 주세요" }
        }
    }
    private func tick() {
        guard enabled || pending != nil else { return }
        guard isTrusted() else {
            let message = "창 복원에 손쉬운 사용 권한이 필요해요"
            if status != message { status = message; writeDiagnostics() }
            return
        }
        input.start()
        guard gate.phase != .sleeping else { return }
        let screens = Screens.current()
        if screens != lastDisplayState && gate.phase == .tracking { displayChanged() }
        if gate.ready(now: Date()), !busy {
            let key = Geometry.configurationID(screens)
            if pending == nil { pending = profiles[key] }
            if let pending = pending {
                let expected = Set(pending.displays.map(\.id)), actual = Set(screens.map(\.id))
                if !expected.isSubset(of: actual) && Date() < gate.deadline {
                    waiting("저장된 화면이 다시 연결되기를 기다리는 중", reason: "displayMissing"); return
                }
            }
            guard input.windowsReady else {
                waiting(input.available ? "클릭·드래그가 끝나면 창을 복원해요" : "입력 감지 권한을 확인해 주세요",
                        reason: input.available ? "pointerInteraction" : "inputMonitorUnavailable")
                return
            }
            if let target = pending {
                gate.begin(); busy = true
                let generation = gate.generation
                restoreTask = Task { @MainActor in await self.restore(target, generation: generation) }
            } else {
                gate.finish(); lastDisplayState = screens; requestCapture(force: true)
            }
        } else if gate.canCapture && !busy {
            let key = Geometry.configurationID(screens)
            if Date() >= protectionRetryAt, let protection = protections[key], !protection.isEmpty,
               protection.windowIDs.isEmpty ? input.idle : input.windowsReady {
                var target = protection.baseline
                if !protection.dock { target.dock = nil }
                freeze(); gate.remember(); gate.begin(); busy = true
                restoreStarted = Date(); changedByUser.removeAll()
                requestedAt = Date(); waitReason = "retry"
                let generation = gate.generation
                let retryTarget = target
                restoreTask = Task { @MainActor in await self.restore(retryTarget, generation: generation, retry: true, windowIDs: protection.windowIDs) }
            } else if Date().timeIntervalSince(lastScan) >= 5 { requestCapture() }
        }
    }
    private func waiting(_ message: String, reason: String) {
        guard status != message || waitReason != reason else { return }
        status = message; waitReason = reason; writeDiagnostics()
    }
    private func requestCapture(force: Bool = false) {
        guard gate.canCapture, !busy, (enabled || force) else { return }
        captureTask?.cancel()
        let generation = gate.generation
        captureTask = Task { @MainActor in
            if !force { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled, self.gate.generation == generation, self.gate.canCapture else { return }
            await self.capture(generation: generation)
        }
    }
    private func capture(generation: Int) async {
        guard isTrusted(), gate.canCapture else { return }
        let screens = Screens.current(), apps = applications()
        guard !screens.isEmpty else { return }
        lastScan = Date()
        let result = await access.scan(apps: apps, displays: screens)
        guard !Task.isCancelled, generation == gate.generation, gate.canCapture, screens == Screens.current() else { return }
        live = result.windows; observations.update(live, apps: apps)
        let key = Geometry.configurationID(screens)
        var windows = live.map(\.snapshot)
        windows += (profiles[key]?.windows ?? []).filter { old in
            result.unavailable.contains(old.pid) && apps.contains(where: { $0.pid == old.pid && $0.launched == old.launchedAt }) &&
                WindowMatcher.match(old, current: windows, original: profiles[key]?.windows ?? []) == nil
        }
        let dockID = dockEnabled() ? selectedDisplay() : dock.currentDisplay(screens)
        if Date().timeIntervalSince(settingsReadAt) >= 5, let id = dockID {
            if let settings = await dock.settings(displayID: id) { dockSettings = settings }
            settingsReadAt = Date()
        }
        automationAllowed = dock.automationAllowed
        guard !Task.isCancelled, generation == gate.generation, gate.canCapture, screens == Screens.current() else { return }
        var dockSnapshot = dockID.map { DockSnapshot(displayID: $0) }
        if let setting = dockSettings, let id = dockID { dockSnapshot = setting; dockSnapshot?.displayID = id }
        if dockSnapshot?.size == nil, let savedDock = profiles[key]?.dock {
            dockSnapshot = savedDock
            if let id = dockID { dockSnapshot?.displayID = id }
        }
        if let protection = protections[key] {
            for saved in protection.baseline.windows where protection.windowIDs.contains(saved.id) {
                let active = apps.contains { $0.pid == saved.pid && $0.launched == saved.launchedAt }
                let match = WindowMatcher.match(saved, current: live.map(\.snapshot), original: protection.baseline.windows)
                if !active || (match == nil && !result.unavailable.contains(saved.pid) && !apps.contains(where: { $0.pid == saved.pid && $0.hidden })) {
                    protections[key]?.windowIDs.remove(saved.id)
                }
            }
        }
        let fresh = LayoutSnapshot(displays: screens, windows: windows, dock: dockSnapshot)
        let snapshot = protections[key]?.merging(fresh) ?? fresh
        do {
            if let prior = profiles[key], prior.displays == snapshot.displays && prior.windows == snapshot.windows && prior.dock == snapshot.dock {
                savedAt = prior.savedAt
            } else {
                try repository.save(snapshot); profiles[key] = snapshot; savedAt = snapshot.savedAt
            }
            pending = nil; lastDisplayState = screens; windowCount = snapshot.windows.count
            status = "\(windows.count)개 창의 정상 배치를 기억하고 있어요"
            if let protection = protections[key], !protection.isEmpty {
                status += " · 복원 대기: 창 \(protection.windowIDs.count)개" + (protection.dock ? ", Dock" : "")
            }
        } catch { status = "배치 저장 실패: \(error.localizedDescription)" }
        writeDiagnostics()
    }
    private func restore(_ snapshot: LayoutSnapshot, generation: Int, retry: Bool = false, windowIDs: Set<String>? = nil) async {
        func cancelled() -> Bool { Task.isCancelled || gate.generation != generation || gate.phase != .restoring }
        closePanel()
        let started = Date()
        let observation = retry ? min(3, timing.observation) : timing.observation
        let deadline = started.addingTimeInterval(retry ? min(10, timing.timeout) : timing.timeout)
        lastRecovery = ["startedAt": started.description, "retry": retry, "windows": [[String: Any]](),
                        "requestedAt": requestedAt?.description ?? "",
                        "startDelaySeconds": started.timeIntervalSince(requestedAt ?? started),
                        "waitReasonBeforeStart": waitReason]
        waitReason = ""
        status = "저장된 배치로 복원하고 앱의 크기 변경을 확인하는 중"
        writeDiagnostics()
        var dockOK = snapshot.dock == nil
        var dockReason = ""
        var dockChecked = false
        var firstWrites: [String: Date] = [:]
        var restored: Set<String> = [], skipped: Set<String> = [], failed: Set<String> = []
        var attempts: [String: Int] = [:]
        var stableSince = Date()
        repeat {
            guard !cancelled() else { return }
            let screens = Screens.current(), apps = applications()
            let result = await access.scan(apps: apps, displays: screens)
            guard !cancelled() else { return }
            live = result.windows; observations.update(live, apps: apps)
            restored.removeAll(); skipped.removeAll(); failed.removeAll()
            var details: [[String: Any]] = []
            for saved in snapshot.windows where windowIDs == nil || windowIDs!.contains(saved.id) {
                guard !cancelled() else { return }
                var detail: [String: Any] = ["id": saved.id, "bundleID": saved.bundleID, "attempts": attempts[saved.id, default: 0]]
                defer {
                    if let date = firstWrites[saved.id] { detail["firstWriteAt"] = date.description }
                    details.append(detail)
                }
                guard let currentScreen = screens.first(where: { $0.id == saved.displayID }),
                      let oldScreen = snapshot.displays.first(where: { $0.id == saved.displayID }) else {
                    failed.insert(saved.id); detail["result"] = "displayMissing"; continue
                }
                let frame = Geometry.target(saved, savedDisplay: oldScreen, current: currentScreen)
                detail["target"] = rectDescription(frame)
                guard let match = WindowMatcher.match(saved, current: live.map(\.snapshot), original: snapshot.windows),
                      let current = live.first(where: { $0.snapshot.id == match.id }) else {
                    if result.unavailable.contains(saved.pid) {
                        failed.insert(saved.id); detail["result"] = "AXUnavailable"
                    } else { skipped.insert(saved.id); detail["result"] = "closedHiddenOrUnmatched" }
                    continue
                }
                detail["actual"] = rectDescription(current.globalFrame)
                if changedByUser.contains(match.id) {
                    skipped.insert(saved.id); detail["result"] = "userMoved"; continue
                }
                if Geometry.close(current.globalFrame, frame) {
                    restored.insert(saved.id); detail["result"] = "verified"; continue
                }
                // Recheck every window, including ones that previously accepted an AX write.
                failed.insert(saved.id)
                guard input.windowsReady else { detail["result"] = "waitingForPointerInteraction"; continue }
                let permit = WritePermit(); currentWrite = permit
                attempts[saved.id, default: 0] += 1
                if firstWrites[saved.id] == nil { firstWrites[saved.id] = Date() }
                let accepted = await access.move(current, to: frame, permit: permit)
                detail["attempts"] = attempts[saved.id]
                detail["result"] = accepted ? "writeAcceptedAwaitingVerification" : "writeUnconfirmed"
                currentWrite = nil
            }
            // Restore windows first; Dock cursor movement must not hold up window geometry.
            if !dockChecked {
                lastRecovery["firstWindowPassAt"] = Date().description
                let result = await restoreDock(snapshot.dock, cancelled: cancelled)
                dockOK = result.ok; dockReason = result.reason; dockChecked = true
            }
            guard !cancelled() else { return }
            if !failed.isEmpty { stableSince = Date() }
            lastRecovery["windows"] = details
            lastRecovery["dockResult"] = dockOK ? "verified" : dockReason
            lastRecovery["checkedAt"] = Date().description
            automationAllowed = dock.automationAllowed
            writeDiagnostics()
            if Date().timeIntervalSince(started) >= observation && failed.isEmpty && Date().timeIntervalSince(stableSince) >= timing.stable { break }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } while !cancelled()
        guard !cancelled() else { return }
        let success = failed.isEmpty && dockOK
        let key = snapshot.configurationID
        protections[key] = LayoutProtection(baseline: snapshot, windowIDs: failed, dock: !dockOK)
        protectionRetryAt = Date().addingTimeInterval(30)
        // Failed targets are merged individually. Healthy windows must keep being saved.
        busy = false; gate.finish(); lastDisplayState = Screens.current(); pending = nil
        savedAt = snapshot.savedAt; windowCount = snapshot.windows.count
        status = success ? "\(restored.count)개 창 복원 완료" : "정상 창 저장 계속 · 실패한 배치만 보호하고 재시도해요"
        if !failed.isEmpty { status += " · 창 \(failed.count)개" }
        if !dockOK { status += " · " + (dockReason.isEmpty ? "Dock 이동 실패" : dockReason) }
        if !skipped.isEmpty { status += " · 닫힘·변경·식별 불가 \(skipped.count)개 제외" }
        lastRecovery["finishedAt"] = Date().description
        lastRecovery["success"] = success
        lastScan = Date(); writeDiagnostics()
    }
    private func restoreDock(_ saved: DockSnapshot?, cancelled: () -> Bool) async -> (ok: Bool, reason: String) {
        guard let saved else { return (true, "") }
        guard !cancelled() else { return (false, "취소됨") }
        let screens = Screens.current()
        let bottom = (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom") == "bottom"
        if dockConflict() { return (false, "DockLock 실행 중") }
        if !bottom { return (false, "Dock 아래쪽 설정 필요") }
        guard let screen = screens.first(where: { $0.id == saved.displayID }) else { return (false, "Dock 대상 화면 미연결") }
        var positionOK = dock.currentDisplay(screens) == saved.displayID
        for _ in 0..<3 where !positionOK {
            guard !cancelled(), input.idle else { break }
            positionOK = await dock.relocate(to: screen, displays: screens, input: input, cancelled: cancelled)
            if !positionOK { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        guard !cancelled() else { return (false, "취소됨") }
        // Reading unchanged settings is safe while typing; any write still waits for idle input.
        let sizeOK = await dock.applySettings(saved, cancelled: { cancelled() || !self.input.idle })
        if positionOK && sizeOK { return (true, "") }
        if !input.idle { return (false, "Dock 복원은 입력이 멈추면 다시 시도해요") }
        return (false, sizeOK ? "Dock 이동 실패" : "Dock 크기 복원 또는 자동화 권한 확인 필요")
    }
    private func rectDescription(_ frame: CGRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    private func writeDiagnostics() {
        let key = Geometry.configurationID(Screens.current())
        let payload: [String: Any] = ["updatedAt": Date().description, "enabled": enabled, "phase": gate.phase.rawValue,
                                     "requestedAt": requestedAt?.description ?? "", "waitReason": waitReason,
                                     "inputMonitorAvailable": input.available, "windowsReady": input.windowsReady, "dockInputIdle": input.idle,
                                     "windowCount": windowCount, "status": status, "automationAllowed": automationAllowed,
                                     "automationStatus": dock.permissionStatus, "savedAt": savedAt?.description ?? "",
                                     "protectedWindowIDs": Array(protections[key]?.windowIDs ?? []).sorted(),
                                     "protectedDock": protections[key]?.dock ?? false, "lastRecovery": lastRecovery]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: diagnosticsURL, options: .atomic) }
    }
    func stop() {
        currentWrite?.cancel()
        gate.sleep(); observations.stop()
        timer?.invalidate(); captureTask?.cancel(); restoreTask?.cancel()
        CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
        for (center, token) in tokens { center.removeObserver(token) }; tokens.removeAll()
    }
}
