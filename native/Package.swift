// swift-tools-version: 6.0
import PackageDescription

// Robo, the native macOS build. Python (src/robo) stays the running one until the cutover.
let package = Package(
    name: "Robo",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored: upstream's 1.24.2 pin gives 6/200 transcripts that differ from the Python app's
        // onnxruntime 1.31; the vendored bindings use the 1.30.0 pod archive and match it (see its Package.swift).
        .package(path: "Vendor/onnxruntime-swift-package-manager"),
        // LaTeX in the chat: typesets $...$ with Core Text and its own Latin Modern Math font (MIT).
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
    ],
    targets: [
        .target(name: "RoboCore"),  // pure logic and Hermes client: no AppKit, time comes in as an argument
        .target(name: "RoboVoice", dependencies: [
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        ]),
        .target(name: "RoboSystem", dependencies: ["RoboCore"]),  // activity, wake, setup, vault, calendar links, nudge files
        .target(name: "RoboUI", dependencies: ["RoboCore", "RoboVoice", "RoboSystem", .product(name: "SwiftMath", package: "SwiftMath")]),  // AppKit: window, face, card
        .executableTarget(name: "robo", dependencies: ["RoboUI"]),  // thin: dispatches the subcommands
        .testTarget(name: "RoboCoreTests", dependencies: ["RoboCore"]),
        .testTarget(name: "RoboVoiceTests", dependencies: ["RoboVoice"]),
        .testTarget(name: "RoboSystemTests", dependencies: ["RoboSystem"]),
        .testTarget(name: "RoboUITests", dependencies: ["RoboUI"]),
    ],
    swiftLanguageModes: [.v5]
)
