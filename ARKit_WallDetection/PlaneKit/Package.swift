// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaneKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PlaneKit", targets: ["PlaneKit"])
    ],
    targets: [
        // Optimized in Debug too (SPEC P26): Xcode's Run installs Debug builds, and the averaged cloud and the recorder
        // run on every ARKit frame. Unoptimized, the accumulator costs about 60 times more per frame.
        .target(name: "PlaneKit", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "PlaneKitTests", dependencies: ["PlaneKit"])
    ]
)
