// swift-tools-version: 5.9
import PackageDescription

// microsoft/onnxruntime-swift-package-manager 1.24.2's Objective-C bindings, reduced to what Robo
// uses (no training, extensions or tests) and pointed at the ONNX Runtime 1.30.0 pod archive: 1.30
// gives the transcripts of the Python app's onnxruntime 1.31, 1.24.2 does not (6 of 200 differ).
// 1.30's CoreML code needs Network.framework. Robo never appends a provider, so it runs on the CPU.
let package = Package(
    name: "onnxruntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "onnxruntime", type: .static, targets: ["OnnxRuntimeBindings"]),
    ],
    targets: [
        .target(name: "OnnxRuntimeBindings",
                dependencies: ["onnxruntime"],
                path: "objectivec",
                cxxSettings: [.define("SPM_BUILD")],
                linkerSettings: [.linkedFramework("Network")]),
        .binaryTarget(name: "onnxruntime",
                      url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.30.0.zip",
                      checksum: "e6f1670c14406fd9f082bb400ab197a9b0a9646058ca6366e440642e2b54a2ea"),
    ],
    cxxLanguageStandard: .cxx17
)
