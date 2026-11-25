// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RunloopCore",
    platforms: [.iOS(.v26), .watchOS(.v26), .macOS(.v13)],
    products: [.library(name: "RunloopCore", targets: ["RunloopCore"])],
    targets: [
        .target(name: "RunloopCore"),
        .testTarget(name: "RunloopCoreTests", dependencies: ["RunloopCore"])
    ]
)
