// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-fbx-gltf",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FBXGLTF",
            targets: ["FBXGLTF"]
        ),
        .executable(
            name: "model2glb",
            targets: ["model2glb"]
        ),
    ],
    targets: [
        .target(
            name: "CUfbx",
            exclude: ["LICENSE"]
        ),
        .target(
            name: "FBXGLTF",
            dependencies: ["CUfbx"]
        ),
        .executableTarget(
            name: "model2glb",
            dependencies: ["FBXGLTF"]
        ),
        .testTarget(
            name: "FBXGLTFTests",
            dependencies: ["FBXGLTF"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

for target in package.targets where target.name != "CUfbx" {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InternalImportsByDefault"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("ImmutableWeakCaptures"),
        ]
}
