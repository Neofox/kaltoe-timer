// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlexTimer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FlexTimer", path: "Sources/FlexTimer"),
        .testTarget(name: "FlexTimerTests", dependencies: ["FlexTimer"], path: "Tests/FlexTimerTests",
                    resources: [.copy("Fixtures")]),
    ]
)
