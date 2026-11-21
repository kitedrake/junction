// swift-tools-version: 6.2
import PackageDescription

// Junction: virtual audio devices and a node-and-cable audio router for macOS.
// The HAL driver (Driver/) is a plain C bundle built by build.sh, not by SwiftPM. build.sh puts the JunctionHelper
// executable into its own app bundle inside Junction.app.
let package = Package(
    name: "Junction",
    platforms: [.macOS(.v26)],
    dependencies: [
        // In-app updates (release builds only; see build.sh). Pinned: bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Real-time mixing kernel (the IOProc), in C so the audio thread never touches ARC, locks or allocation.
        .target(
            name: "JunctionKernel",
            path: "Sources/JunctionKernel",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-O3"])],
            linkerSettings: [.linkedFramework("AudioToolbox")]  // effect chains render Audio Units
        ),
        .target(
            name: "JunctionCore",
            dependencies: ["JunctionKernel"],
            path: "Sources/JunctionCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Junction",
            dependencies: ["JunctionCore", "JunctionKernel", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Junction",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Routing in the background: a UI-element app inside Junction.app (Contents/Library/LoginItems), registered
        // with SMAppService.agent and served over XPC (see build.sh). No Sparkle: the app updates both.
        .executableTarget(
            name: "JunctionHelper",
            dependencies: ["JunctionCore"],
            path: "Sources/JunctionHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Password-free driver installs: a launch daemon inside Junction.app (Contents/Library/HelperTools), registered
        // with SMAppService.daemon and served over XPC (see build.sh).
        .executableTarget(
            name: "JunctionDriverDaemon",
            dependencies: ["JunctionCore"],
            path: "Sources/JunctionDriverDaemon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "JunctionCoreTests",
            dependencies: ["JunctionCore", "JunctionKernel"],
            path: "Tests/JunctionCoreTests",
            exclude: ["Fixtures"],  // sample files the tests read by path
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
