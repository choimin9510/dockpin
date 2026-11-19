import AppKit

@main enum Fixture {
    static var windows: [NSWindow] = []
    static var tokens: [NSObjectProtocol] = []
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        for index in 0..<2 {
            let screen = NSScreen.screens[min(index * 2, NSScreen.screens.count - 1)]
            let area = screen.visibleFrame
            let frame = CGRect(x: area.minX + 100, y: area.minY + 100, width: 480, height: 320)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Dockpin 복원 검증"
            window.identifier = NSUserInterfaceItemIdentifier("fixture-\(index)")
            window.contentView = NSTextField(labelWithString: "자동 검증용 창입니다. 검증이 끝나면 닫힙니다.")
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        tokens.append(DistributedNotificationCenter.default().addObserver(forName: .init("app.dockpin.fixture.rebound"), object: nil, queue: .main) { _ in
            var frame = windows[0].frame
            frame.size.width = max(200, frame.width - 100)
            frame.size.height = max(200, frame.height - 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                windows[0].setFrame(frame, display: true)
            }
        })
        app.run()
    }
}
