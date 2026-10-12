// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FigmaFinder",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FigmaFinder", targets: ["FigmaFinder"])],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "FigmaFinder", dependencies: ["BridgeCore"])
    ]
)
