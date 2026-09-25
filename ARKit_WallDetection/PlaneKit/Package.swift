// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaneKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PlaneKit", targets: ["PlaneKit"])
    ],
    targets: [
        .target(name: "PlaneKit"),
        .testTarget(name: "PlaneKitTests", dependencies: ["PlaneKit"])
    ]
)
