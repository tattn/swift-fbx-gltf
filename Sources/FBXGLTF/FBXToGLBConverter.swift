public import Foundation

public enum FBXGLTFError: Error, LocalizedError {
    case loadFailed(String)
    case encodingFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let message):
            "Failed to load the FBX file: \(message)"
        case .encodingFailed(let error):
            "Failed to encode the glTF document: \(error)"
        }
    }
}

/// Converts an FBX file into a self-contained GLB (binary glTF 2.0).
///
/// The output is normalized to the glTF conventions (right-handed Y-up, meters,
/// linear colors) and embeds all textures. Skeletons, skinning, blend shapes and
/// animations are converted; anything the converter has to approximate or drop
/// is reported through ``Summary/warnings``.
public struct FBXToGLBConverter: Sendable {
    public struct Options: Sendable {
        /// The unit in meters the scene is scaled to. The default of 1.0 converts
        /// FBX files authored in centimeters or other units into meters.
        public var targetUnitMeters: Double

        public init(targetUnitMeters: Double = 1.0) {
            self.targetUnitMeters = targetUnitMeters
        }
    }

    public struct Summary: Sendable {
        public let nodeCount: Int
        public let meshCount: Int
        public let primitiveCount: Int
        public let triangleCount: Int
        public let materialCount: Int
        public let textureCount: Int
        public let animationCount: Int
        /// Size of the produced GLB in bytes.
        public let byteCount: Int
        public let warnings: [String]
    }

    public struct Result: Sendable {
        public let glb: Data
        public let summary: Summary
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func convert(contentsOf url: URL) throws(FBXGLTFError) -> Result {
        let scene = try FBXSceneLoader(targetUnitMeters: options.targetUnitMeters).load(contentsOf: url)
        let glb = try GLTFBuilder.buildGLB(from: scene)
        let summary = Summary(
            nodeCount: scene.nodes.count,
            meshCount: scene.meshes.count,
            primitiveCount: scene.meshes.reduce(0) { $0 + $1.primitives.count },
            triangleCount: scene.meshes.reduce(0) { total, mesh in
                total + mesh.primitives.reduce(0) { $0 + $1.indices.count / 3 }
            },
            materialCount: scene.materials.count,
            textureCount: scene.textures.count,
            animationCount: scene.animations.count,
            byteCount: glb.count,
            warnings: scene.warnings
        )
        return Result(glb: glb, summary: summary)
    }

    @discardableResult
    public func convert(contentsOf url: URL, to outputURL: URL) throws -> Summary {
        let result = try convert(contentsOf: url)
        try result.glb.write(to: outputURL)
        return result.summary
    }
}
