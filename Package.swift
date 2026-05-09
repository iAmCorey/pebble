// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pebble",
    platforms: [
        // .v14 floor — `@Observable` macro requires Sonoma+. Dropping further
        // would mean reverting all session models to ObservableObject + @Published.
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        // Thin executable: main.swift only. Everything else lives in PebbleKit so
        // tests can `@testable import` it (SPM doesn't allow importing executables).
        .executableTarget(
            name: "Pebble",
            dependencies: ["PebbleKit"],
            path: "Sources/Pebble"
        ),
        // Tiny stand-alone CLI invoked from Claude Code / Codex hooks. Reads
        // $PEBBLE_SURFACE_ID from env, opens the unix socket the running app
        // owns, writes one JSON line, exits. Doesn't link PebbleKit on purpose
        // — keeps the binary fast and dependency-free.
        .executableTarget(
            name: "PebbleHook",
            path: "Sources/PebbleHook"
        ),
        .target(
            name: "PebbleKit",
            dependencies: [
                "GhosttyKit",
            ],
            path: "Sources/PebbleKit",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // libghostty bundles C++ deps (glslang, spirv-cross, imgui)
                // and uses Metal for rendering; link the system frameworks.
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                // Text Input Services — libghostty uses TIS to read the active
                // keyboard layout. Pulled in implicitly by SwiftTerm before;
                // now declared directly.
                .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            // Run scripts/setup-libghostty.sh to populate this; not committed.
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .testTarget(
            name: "PebbleKitTests",
            dependencies: ["PebbleKit"],
            path: "Tests/PebbleKitTests"
        ),
    ]
)
