// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Figma x Finder",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FigmaFinder", targets: ["FigmaFinder"])],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "FigmaFinder", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
    ]
)
