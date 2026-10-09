// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AstralCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AstralCore", targets: ["AstralCore"]),
    ],
    targets: [
        .target(name: "AstralCore"),
        .testTarget(name: "AstralCoreTests", dependencies: ["AstralCore"]),
    ]
)
