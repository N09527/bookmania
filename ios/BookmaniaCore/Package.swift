// swift-tools-version:6.0
// BookmaniaCore: everything of the iOS app that has no user interface (book parsing first). It builds on Linux
// too, so its unit tests run where the app itself cannot be built.
import PackageDescription

let package = Package(
    name: "BookmaniaCore",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "BookmaniaCore", targets: ["BookmaniaCore"]),
    ],
    targets: [
        .target(name: "BookmaniaCore"),
        .testTarget(name: "BookmaniaCoreTests", dependencies: ["BookmaniaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
