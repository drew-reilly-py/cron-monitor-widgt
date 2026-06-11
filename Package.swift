// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CronMonitorDesktopWidget",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CronMonitorDesktopWidget", targets: ["CronMonitorDesktopWidget"])
    ],
    targets: [
        .executableTarget(name: "CronMonitorDesktopWidget")
    ]
)
