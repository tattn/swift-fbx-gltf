public import Foundation

public enum GLBConversionError: Error, LocalizedError {
    case loadFailed(String)
    case encodingFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let message):
            "Failed to load the model file: \(message)"
        case .encodingFailed(let error):
            "Failed to encode the glTF document: \(error)"
        }
    }
}

/// Converts an FBX or Wavefront OBJ file into a self-contained GLB (binary glTF 2.0).
///
/// The output is normalized to the glTF conventions (right-handed Y-up, meters,
/// linear colors) and embeds all textures. Skeletons, skinning, blend shapes and
/// animations are converted; anything the converter has to approximate or drop
/// is reported through ``Summary/warnings``.
public struct GLBConverter: Sendable {
    /// Lowercased extensions of the files this converter reads. An OBJ file brings
    /// its `.mtl` material library and textures along from the same folder.
    public static let supportedFileExtensions: Set<String> = ["fbx", "obj"]

    public struct Options: Sendable {
        /// The unit in meters the scene is scaled to. The default of 1.0 converts
        /// files authored in centimeters or other units into meters.
        public var targetUnitMeters: Double
        /// The unit in meters an OBJ file is read in. OBJ does not record its
        /// unit; the default of 1.0 matches Blender's and glTF's.
        public var objUnitMeters: Double

        public init(targetUnitMeters: Double = 1.0, objUnitMeters: Double = 1.0) {
            self.targetUnitMeters = targetUnitMeters
            self.objUnitMeters = objUnitMeters
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

    public func convert(contentsOf url: URL) throws(GLBConversionError) -> Result {
        let scene = try SceneLoader(options: options).load(contentsOf: url)
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
