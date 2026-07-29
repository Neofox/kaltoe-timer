// swift-tools-version:6.0
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
    // Keep the version as a *string*, not `.macOS(.v26)`: the SwiftPM inside the
    // swift:6.1-noble image used by scripts/build-linux.sh predates macOS 26 and
    // has no `.v26` case. The enum form compiles fine here and breaks only the
    // Linux build — a failure that would surface at release time.
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets
)
