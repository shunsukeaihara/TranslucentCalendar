// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranslucentCalendar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TranslucentCalendar",
            path: "Sources/TranslucentCalendar"
        )
    ]
)
