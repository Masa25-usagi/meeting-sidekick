// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingSidekick",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MeetingSidekick", targets: ["MeetingMac"]),
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .executable(name: "MeetingProbe", targets: ["MeetingProbe"]),
        .executable(name: "MeetingChecks", targets: ["MeetingChecks"])
    ],
    targets: [
        .target(name: "MeetingCore"),
        .target(name: "MeetingServices", dependencies: ["MeetingCore"]),
        .executableTarget(name: "MeetingMac", dependencies: ["MeetingCore", "MeetingServices"]),
        .executableTarget(name: "MeetingProbe", dependencies: ["MeetingCore", "MeetingServices"]),
        .executableTarget(name: "MeetingChecks", dependencies: ["MeetingCore", "MeetingServices"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
