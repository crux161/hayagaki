// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hayagaki",
    platforms: [.macOS(.v11)],
    targets: [
        // 1. Define the executable
        .executableTarget(
            name: "Hayagaki",
            dependencies: ["LibSumi"], // Depend on the C++ lib
            path: "Sources/Hayagaki",
            resources: [
                .copy("SumiCore.h"),
                .copy("Shaders.metal"),
                .copy("Demo_Bubbles.metal"),
                .copy("Demo_Neon.metal"),
                .copy("Demo_Fractal.metal")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        
        // 2. Define the C++ Library Wrapper
        .systemLibrary(
            name: "LibSumi",
            path: "Sources/libsumi",
            pkgConfig: "sumi", // Optional: if you use pkg-config
            providers: []
        )
    ]
)
