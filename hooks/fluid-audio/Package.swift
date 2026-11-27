// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CaptureItFluidHook",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "capture-it-fluid", targets: ["FluidHook"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"])
    ],
    targets: [
        .target(name: "FluidHookSupport"),
        .target(name: "CapturePaths"),
        .executableTarget(name: "FluidHook", dependencies: ["FluidHookSupport", "CapturePaths", .product(name: "FluidAudio", package: "FluidAudio")], resources: [.process("Resources")]),
        .testTarget(name: "FluidHookSupportTests", dependencies: ["FluidHookSupport"])
    ],
    swiftLanguageModes: [.v6]
)
