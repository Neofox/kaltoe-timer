// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .executable(name: "kaltoe-core", targets: ["KaltoeDaemon"]),
]
var targets: [Target] = [
    .target(name: "KaltoeCore", path: "Sources/KaltoeCore"),
    .executableTarget(name: "KaltoeDaemon", dependencies: ["KaltoeCore"], path: "Sources/KaltoeDaemon"),
    .testTarget(name: "KaltoeCoreTests", dependencies: ["KaltoeCore"], path: "Tests/KaltoeCoreTests",
                resources: [.copy("Fixtures")]),
]
#if os(macOS)
products.append(.executable(name: "FlexTimer", targets: ["FlexTimer"]))
targets += [
    .executableTarget(name: "FlexTimer", dependencies: ["KaltoeCore"], path: "Sources/FlexTimer"),
    .testTarget(name: "FlexTimerTests", dependencies: ["FlexTimer"], path: "Tests/FlexTimerTests"),
]
#endif

let package = Package(
    name: "FlexTimer",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
