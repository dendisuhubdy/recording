// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"])],
    targets: [
        .target(name: "MeetingCore"),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
    ]
)
