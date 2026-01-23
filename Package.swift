// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hayagaki",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Hayagaki", targets: ["Hayagaki"]),
        .library(name: "libsumi", targets: ["libsumi"])
    ],
    targets: [
        .target(
            name: "libsumi",
            path: "Sources/libsumi",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),
        .executableTarget(
            name: "Hayagaki",
            dependencies: ["libsumi"],
            path: "Sources/Hayagaki",
            resources: [
                // Copy these as text files so we can read/stitch them at runtime
                .copy("SumiCore.h"),
                .copy("Shaders.metal"),
                .copy("Demo_Bubbles.metal"),
                .copy("Demo_Neon.metal"),
                .copy("Demo_Fractal.metal")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
