// swift-tools-version: 5.8
import PackageDescription
let package = Package(name: "Dockpin", platforms: [.macOS(.v13)], products: [.executable(name: "Dockpin", targets: ["Dockpin"])], targets: [
    .target(name: "DockpinCore"),
    .executableTarget(name: "Dockpin", dependencies: ["DockpinCore"]),
    .executableTarget(name: "DockpinChecks", dependencies: ["DockpinCore"], path: "Tests/DockpinCoreTests")
])
