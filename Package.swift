// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Leap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LeapCore"),
        .executableTarget(
            name: "Leap",
            dependencies: ["LeapCore"]
        ),
        .testTarget(name: "LeapCoreTests", dependencies: ["LeapCore"]),
    ]
)
