import AppKit
import SwiftUI
import ServiceManagement
import DockpinCore

struct Display: Identifiable {
    let id: String
    let name: String
    let bounds: CGRect
}

final class PinStore: ObservableObject {
    let recovery = Recovery()
    @Published var displays: [Display] = []
    @Published var selected: String = UserDefaults.standard.string(forKey: "display") ?? ""
    @Published var enabled = UserDefaults.standard.bool(forKey: "enabled")
    @Published var trusted = false
    @Published var active = false
    @Published var conflict = false
    @Published var bottom = true
    @Published var message = ""
    @Published var login = SMAppService.mainApp.status == .enabled
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var received = 0
    var blocked = 0
    var effective: String { displays.contains(where: { $0.id == selected }) ? selected : displays.first?.id ?? "" }
    init() {
        refresh()
        recovery.selectedDisplay = { [weak self] in self?.selected ?? "" }
        recovery.dockEnabled = { [weak self] in self?.enabled ?? false }
        recovery.dockConflict = { [weak self] in self?.conflict ?? false }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        displays = NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = n.uint32Value
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return Display(id: CFUUIDCreateString(nil, uuid) as String, name: screen.localizedName, bounds: CGDisplayBounds(id))
        }
        trusted = AXIsProcessTrusted()
        conflict = NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "").hasPrefix("pro.docklock.") }
        bottom = (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom") == "bottom"
        if enabled && trusted && !conflict && bottom && !displays.isEmpty { start() } else { stop() }
        active = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let diagnostics: [String: Any] = ["trusted": trusted, "enabled": enabled, "active": active, "conflict": conflict, "bottom": bottom, "selected": selected, "effective": effective, "received": received, "blocked": blocked, "displays": displays.map { ["id": $0.id, "name": $0.name, "bounds": NSStringFromRect($0.bounds)] }]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dockpin-status.json"), options: .atomic)
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "enabled")
        refresh()
    }
    func select(_ display: Display) {
        selected = display.id
        UserDefaults.standard.set(selected, forKey: "display")
    }
    func permission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            login = SMAppService.mainApp.status == .enabled
            message = SMAppService.mainApp.status == .requiresApproval ? "시스템 설정에서 로그인 항목을 허용해 주세요." : ""
        } catch { message = "로그인 설정 실패: \(error.localizedDescription)" }
    }
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            let store = Unmanaged<PinStore>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = store.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            store.received += 1
            // Drop the edge event so Dock cannot consume its original movement delta.
            if !store.recovery.dock.moving, event.getIntegerValueField(.eventSourceUserData) != InputActivity.marker,
               !event.flags.contains(.maskAlternate), let point = Boundary.clamp(event.location, displays: store.displays, allowed: store.effective) {
                store.blocked += 1
                CGWarpMouseCursorPosition(point)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap = tap {
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            message = ""
        } else { message = "마우스 감지를 시작할 수 없습니다. 권한을 확인한 뒤 앱을 다시 실행해 주세요." }
    }
    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
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
}

struct Panel: View {
    @ObservedObject var store: PinStore
    let mint = Color(red: 0.42, green: 0.92, blue: 0.74)
    var status: String {
        if store.conflict { return "DockLock Lite를 종료해 주세요" }
        if !store.trusted { return "손쉬운 사용 권한이 필요해요" }
        if !store.bottom { return "Dock 위치를 아래쪽으로 설정해 주세요" }
        return store.active ? "Dock이 머물 곳을 정했어요" : "자유롭게 이동하는 중"
    }
    func position(_ display: Display) -> String {
        let sorted = store.displays.sorted { $0.bounds.midX < $1.bounds.midX }
        let horizontal = display.id == sorted.first?.id ? "왼쪽" : display.id == sorted.last?.id ? "오른쪽" : "가운데"
        let minY = store.displays.map { $0.bounds.minY }.min() ?? 0
        return display.bounds.minY > minY + 100 ? horizontal + " 아래" : horizontal
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "pin.fill").font(.system(size: 23)).foregroundColor(mint)
                    .frame(width: 44, height: 44).background(mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dockpin").font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("A little pin. A calmer workspace.").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Circle().fill(store.active ? mint : Color.gray).frame(width: 7, height: 7)
            }
            VStack(spacing: 18) {
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(Array(store.displays.prefix(4).enumerated()), id: \.element.id) { index, display in
                        VStack(spacing: 5) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [mint.opacity(display.id == store.effective ? 0.23 : 0.04), Color.white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                RoundedRectangle(cornerRadius: 8).stroke(display.id == store.effective ? mint.opacity(0.7) : .white.opacity(0.15), lineWidth: 1)
                                if display.id == store.effective {
                                    HStack(spacing: 3) { ForEach(0..<5) { _ in RoundedRectangle(cornerRadius: 2).fill(mint).frame(width: 7, height: 7) } }
                                        .padding(4).background(.white.opacity(0.12), in: Capsule()).padding(.bottom, 7)
                                }
                            }.frame(height: index == 0 ? 72 : 63)
                            Capsule().fill(.white.opacity(0.18)).frame(width: 25, height: 3)
                        }.onTapGesture { store.select(display) }
                    }
                }.padding(.horizontal, 18)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.active ? "제자리에, 편안하게." : "Dock의 자리를 정하세요.").font(.system(size: 17, weight: .semibold))
                        Text(status).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("Dock 고정", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) })).labelsHidden().toggleStyle(.switch).tint(mint)
                }
            }.padding(18).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("DOCK이 머물 디스플레이").font(.system(size: 10, weight: .bold)).tracking(1.4); Spacer(); Text("\(store.displays.count)개 연결됨").font(.system(size: 10)) }.foregroundColor(.secondary)
                ForEach(store.displays) { display in
                    Button { store.select(display) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "display").font(.system(size: 20)).foregroundColor(display.id == store.effective ? mint : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(display.name).font(.system(size: 13, weight: .medium))
                                Text("\(position(display)) · \(Int(display.bounds.width)) × \(Int(display.bounds.height)) pt").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: display.id == store.effective ? "checkmark.circle.fill" : "circle").foregroundColor(display.id == store.effective ? mint : .gray)
                        }.padding(12).background(display.id == store.effective ? mint.opacity(0.08) : .white.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)
                }
            }
            RecoveryPanel(recovery: store.recovery, mint: mint)
            if !store.trusted { Button("손쉬운 사용 권한 허용하기", action: store.permission).buttonStyle(.borderedProminent).tint(mint).foregroundColor(.black) }
            if !store.message.isEmpty { Text(store.message).font(.caption).foregroundColor(.orange) }
            Text("⌥ Option을 누르면 Dock 고정을 잠시 우회해요. 자동 복귀할 때는 포인터가 잠깐 이동할 수 있어요.").font(.system(size: 11)).foregroundColor(.secondary).lineSpacing(3)
            Divider().overlay(.white.opacity(0.06))
            HStack {
                Toggle("로그인 시 실행", isOn: Binding(get: { store.login }, set: { store.setLogin($0) })).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }.padding(24).frame(width: 400)
        }.frame(width: 400, height: 780).background(Color(red: 0.055, green: 0.075, blue: 0.085)).foregroundColor(Color.white.opacity(0.92)).preferredColorScheme(.dark)
    }
}

struct RecoveryPanel: View {
    @ObservedObject var recovery: Recovery
    let mint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("잠자기 전 배치로 자동 복원", isOn: Binding(get: { recovery.enabled }, set: { recovery.setEnabled($0) }))
                .toggleStyle(.switch).tint(mint).font(.system(size: 13, weight: .semibold))
            Text(recovery.status).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let date = recovery.savedAt {
                HStack(spacing: 4) { Text("마지막 저장"); Text(date, style: .time); Spacer(); Text("\(recovery.windowCount)개 창") }
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            HStack {
                Button("지금 복원", action: recovery.restoreNow).disabled(recovery.busy || recovery.savedAt == nil)
                Button("현재 배치 기억", action: recovery.rememberNow).disabled(!recovery.canRemember)
            }.buttonStyle(.bordered).font(.system(size: 11))
            if !recovery.automationAllowed {
                Button("Dock 크기 복원 권한 허용", action: recovery.requestAutomation).font(.system(size: 11)).foregroundColor(mint)
                Text("System Events 자동화를 허용하면 Dock 크기도 기억해요.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }.padding(16).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PinStore()
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Dockpin")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(store: store))
        store.recovery.closePanel = { [weak self] in self?.popover.performClose(nil) }
        store.recovery.start(rememberCurrent: CommandLine.arguments.contains("--remember-current"))
        if CommandLine.arguments.contains("--show") { toggle() }
        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.store.permission()
            }
        }
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button { store.refresh(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationWillTerminate(_ notification: Notification) { store.recovery.stop(); store.stop() }
}

if CommandLine.arguments.contains("--self-test") {
    let a = Display(id: "a", name: "A", bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let b = Display(id: "b", name: "B", bounds: CGRect(x: 100, y: 0, width: 100, height: 100))
    precondition(Boundary.clamp(CGPoint(x: 50, y: 99), displays: [a,b], allowed: "a") == nil)
    precondition(Boundary.clamp(CGPoint(x: 150, y: 99), displays: [a,b], allowed: "a") == CGPoint(x: 150, y: 96))
    precondition(Boundary.clamp(CGPoint(x: 150, y: 50), displays: [a,b], allowed: "a") == nil)
    let c = Display(id: "c", name: "C", bounds: CGRect(x: 100, y: 100, width: 100, height: 100))
    precondition(Boundary.clamp(CGPoint(x: 150, y: 99), displays: [a,b,c], allowed: "a") == nil)
    print("PASS: allowed display, blocked edge, interior, vertical crossing")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
