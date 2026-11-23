// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "capture-it",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "capture-it", targets: ["CaptureIt"])],
    targets: [
        .target(name: "CaptureCore"),
        .target(name: "FluidHookSupport", path: "hooks/fluid-audio/Sources/FluidHookSupport"),
        .executableTarget(
            name: "CaptureIt", dependencies: ["CaptureCore"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", root + "/Support/Info.plist"
            ])]
        ),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
        .testTarget(name: "FluidHookSupportTests", dependencies: ["FluidHookSupport"], path: "hooks/fluid-audio/Tests/FluidHookSupportTests")
    ]
)
