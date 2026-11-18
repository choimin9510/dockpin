import AppKit
import DockpinCore

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
    private var lastDisplayState: [DisplaySnapshot] = []
    private var dockSettings: DockSnapshot?
    private var settingsReadAt = Date.distantPast
    var selectedDisplay: () -> String = { "" }
    var dockEnabled: () -> Bool = { false }
    var dockConflict: () -> Bool = { false }
    var closePanel: () -> Void = {}
    var canRemember: Bool { !busy && gate.phase != .sleeping && gate.phase != .settling }

    init(directory: URL? = nil, applications: @escaping () -> [AppIdentity] = AppIdentity.current, isTrusted: @escaping () -> Bool = AXIsProcessTrusted) {
        let folder = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dockpin/Layouts", isDirectory: true)
        repository = LayoutRepository(directory: folder)
        self.applications = applications
        self.isTrusted = isTrusted
        diagnosticsURL = directory?.appendingPathComponent("recovery-status.txt") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dockpin-recovery.json")
        do { for snapshot in try repository.load() { profiles[snapshot.configurationID] = snapshot } }
        catch { status = "저장된 배치를 읽지 못했어요: \(error.localizedDescription)" }
    }
    func start(rememberCurrent: Bool = false) {
        input.onInput = { [weak self] in self?.currentWrite?.cancel() }
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
            } else if self.gate.canCapture { self.requestCapture() }
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
        freeze(); gate.sleep(); status = "잠자기 전 배치를 보호하는 중"
    }
    func wake() {
        guard enabled else { return }
        freeze(); gate.wake(now: Date()); restoreStarted = Date(); changedByUser.removeAll()
        status = "화면이 다시 연결되기를 기다리는 중"
    }
    private func displayChanged() {
        guard enabled else { return }
        freeze(); gate.displayChanged(now: Date())
        if gate.phase != .sleeping { status = "화면 구성이 안정되기를 기다리는 중" }
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
        status = "입력이 멈추면 저장된 배치로 복원해요"
    }
    func rememberNow() {
        guard canRemember else { return }
        freeze(); pending = nil; gate.remember(); requestCapture(force: true)
    }
    func requestAutomation() {
        closePanel()
        Task { @MainActor in
            let generation = gate.generation
            let setting = await dock.settings(displayID: selectedDisplay(), request: true)
            automationAllowed = dock.automationAllowed
            if generation == gate.generation, gate.canCapture { dockSettings = setting; settingsReadAt = Date(); requestCapture(force: true) }
            if !automationAllowed { status = "시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 System Events를 허용해 주세요" }
        }
    }
    private func tick() {
        guard enabled || pending != nil else { return }
        guard isTrusted() else { status = "창 복원에 손쉬운 사용 권한이 필요해요"; return }
        input.start()
        guard gate.phase != .sleeping else { return }
        let screens = Screens.current()
        if screens != lastDisplayState && gate.phase == .tracking { displayChanged() }
        if gate.ready(now: Date()), !busy {
            let key = Geometry.configurationID(screens)
            if pending == nil { pending = profiles[key] }
            if let pending = pending {
                let expected = Set(pending.displays.map(\.id)), actual = Set(screens.map(\.id))
                if !expected.isSubset(of: actual) && Date() < gate.deadline { return }
            }
            guard input.idle else {
                status = input.available ? "입력이 멈추면 복원을 시작해요" : "입력 감지 권한을 확인해 주세요"
                return
            }
            if let target = pending {
                gate.begin(); busy = true
                let generation = gate.generation
                restoreTask = Task { @MainActor in await self.restore(target, generation: generation) }
            } else {
                gate.finish(success: true); lastDisplayState = screens; requestCapture(force: true)
            }
        } else if gate.canCapture && !busy && Date().timeIntervalSince(lastScan) >= 5 { requestCapture() }
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
        windows += (profiles[key]?.windows ?? []).filter { old in result.unavailable.contains(old.pid) && apps.contains(where: { $0.pid == old.pid && $0.launched == old.launchedAt }) }
        automationAllowed = dock.automationAllowed
        let dockID = dockEnabled() ? selectedDisplay() : dock.currentDisplay(screens)
        if automationAllowed, Date().timeIntervalSince(settingsReadAt) >= 5, let id = dockID {
            dockSettings = await dock.settings(displayID: id); settingsReadAt = Date()
        }
        guard !Task.isCancelled, generation == gate.generation, gate.canCapture, screens == Screens.current() else { return }
        var dockSnapshot = dockID.map { DockSnapshot(displayID: $0) }
        if let setting = dockSettings, let id = dockID { dockSnapshot = setting; dockSnapshot?.displayID = id }
        let snapshot = LayoutSnapshot(displays: screens, windows: windows, dock: dockSnapshot)
        do {
            if let prior = profiles[key], prior.displays == snapshot.displays && prior.windows == snapshot.windows && prior.dock == snapshot.dock {
                savedAt = prior.savedAt
            } else {
                try repository.save(snapshot); profiles[key] = snapshot; savedAt = snapshot.savedAt
            }
            pending = nil; lastDisplayState = screens; windowCount = windows.count
            status = "\(windows.count)개 창의 정상 배치를 기억하고 있어요"
        } catch { status = "배치 저장 실패: \(error.localizedDescription)" }
        writeDiagnostics()
    }
    private func restore(_ snapshot: LayoutSnapshot, generation: Int) async {
        func cancelled() -> Bool { Task.isCancelled || gate.generation != generation || gate.phase != .restoring }
        closePanel()
        var dockOK = true
        var dockReason = ""
        if let savedDock = snapshot.dock {
            let screens = Screens.current()
            let bottom = (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom") == "bottom"
            if dockConflict() { dockOK = false; dockReason = "DockLock 실행 중" }
            else if !bottom { dockOK = false; dockReason = "Dock 아래쪽 설정 필요" }
            else if let screen = screens.first(where: { $0.id == savedDock.displayID }) {
                dockOK = false
                for _ in 0..<3 {
                    guard !cancelled() else { return }
                    if await dock.relocate(to: screen, displays: screens, input: input, cancelled: cancelled) { dockOK = true; break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard !cancelled() else { return }
                if input.idle {
                    let sizeOK = await dock.applySettings(savedDock, cancelled: cancelled)
                    dockOK = sizeOK && dockOK
                    if !sizeOK { dockReason = "Dock 크기 복원 또는 자동화 권한 확인 필요" }
                } else { dockOK = false }
            } else { dockOK = false; dockReason = "Dock 대상 화면 미연결" }
        }
        guard !cancelled() else { return }
        var restored: Set<String> = [], skipped: Set<String> = [], failed: Set<String> = []
        for attempt in 0..<3 {
            guard !cancelled() else { return }
            let screens = Screens.current(), apps = applications()
            let result = await access.scan(apps: apps, displays: screens)
            guard !cancelled() else { return }
            live = result.windows; observations.update(live, apps: apps)
            for saved in snapshot.windows where !restored.contains(saved.id) && !skipped.contains(saved.id) {
                guard !cancelled() else { return }
                guard let currentScreen = screens.first(where: { $0.id == saved.displayID }), let oldScreen = snapshot.displays.first(where: { $0.id == saved.displayID }) else { failed.insert(saved.id); continue }
                guard let match = WindowMatcher.match(saved, current: live.map(\.snapshot), original: snapshot.windows), let current = live.first(where: { $0.snapshot.id == match.id }) else {
                    if result.unavailable.contains(saved.pid) { failed.insert(saved.id) } else { skipped.insert(saved.id); failed.remove(saved.id) }
                    continue
                }
                if changedByUser.contains(match.id) { skipped.insert(saved.id); failed.remove(saved.id); continue }
                guard input.idle else { failed.insert(saved.id); continue }
                let frame = Geometry.target(saved, savedDisplay: oldScreen, current: currentScreen)
                let permit = WritePermit(); currentWrite = permit
                if await access.move(current, to: frame, permit: permit) { restored.insert(saved.id); failed.remove(saved.id) } else { failed.insert(saved.id) }
                currentWrite = nil
            }
            if failed.isEmpty { break }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        guard !cancelled() else { return }
        let success = failed.isEmpty && dockOK
        busy = false; gate.finish(success: success); lastDisplayState = Screens.current()
        pending = success ? nil : snapshot
        savedAt = snapshot.savedAt; windowCount = snapshot.windows.count
        status = success ? "\(restored.count)개 창 복원 완료" : "일부 복원 실패 · 기존 배치를 보호하고 있어요"
        if !failed.isEmpty { status += " · 창 \(failed.count)개" }
        if !dockOK { status += " · " + (dockReason.isEmpty ? "Dock 이동 실패" : dockReason) }
        if !skipped.isEmpty { status += " · 닫힘·변경·식별 불가 \(skipped.count)개 제외" }
        // Give application resize animations time to finish before accepting a new baseline.
        lastScan = Date(); writeDiagnostics()
    }
    private func writeDiagnostics() {
        let payload: [String: Any] = ["enabled": enabled, "phase": gate.phase.rawValue, "windowCount": windowCount, "status": status, "automationAllowed": automationAllowed, "savedAt": savedAt?.description ?? ""]
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
