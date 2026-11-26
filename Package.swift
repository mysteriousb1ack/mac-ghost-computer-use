// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacGhost",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "mac-ghost-helper", targets: ["MacGhostHelper"])],
    targets: [
        .executableTarget(name: "MacGhostHelper", path: "swift"),
        .testTarget(name: "MacGhostTests", dependencies: ["MacGhostHelper"], path: "tests/Swift")
    ]
)
