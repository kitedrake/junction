// swift-tools-version: 6.2
import PackageDescription

// Junction: virtual audio devices and a node-and-cable audio router for macOS.
// The HAL driver (Driver/) is a plain C bundle built by build.sh, not by SwiftPM.
let package = Package(
    name: "Junction",
    platforms: [.macOS(.v26)],
    targets: [
        // Real-time mixing kernel (the IOProc), in C so the audio thread never touches ARC, locks or allocation.
        .target(
            name: "JunctionKernel",
            path: "Sources/JunctionKernel",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        .target(
            name: "JunctionCore",
            dependencies: ["JunctionKernel"],
            path: "Sources/JunctionCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Junction",
            dependencies: ["JunctionCore"],
            path: "Sources/Junction",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "JunctionCoreTests",
            dependencies: ["JunctionCore", "JunctionKernel"],
            path: "Tests/JunctionCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
