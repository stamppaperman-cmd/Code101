// swift-tools-version: 6.0
// Logic tests for StampLab. `Logic/` holds symlinks to app sources that need
// no window or permission, so they run in seconds: `swift test --package-path Tests`.
// deploy.sh runs this first and stops if anything fails.
import PackageDescription

let package = Package(
    name: "StampLabTests",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "StampLabLogic", path: "Logic"),
        .testTarget(name: "StampLabLogicTests", dependencies: ["StampLabLogic"], path: "LogicTests"),
    ],
    swiftLanguageModes: [.v5]
)
