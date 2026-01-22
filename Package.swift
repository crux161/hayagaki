// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hayagaki",
    platforms: [
        .macOS(.v14) // Metal support usually wants modern macOS
    ],
    products: [
        .executable(name: "Hayagaki", targets: ["Hayagaki"]),
        .library(name: "libsumi", targets: ["libsumi"])
    ],
    targets: [
        // 1. The C++ Library Target
        .target(
            name: "libsumi",
            path: "Sources/libsumi",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"]) // Enforce C++17 as per your CMakeLists
            ]
        ),
        
        // 2. The Swift Executable
        .executableTarget(
            name: "Hayagaki",
            dependencies: ["libsumi"],
            path: "Sources/Hayagaki",
            resources: [
                .process("Shaders.metal")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
