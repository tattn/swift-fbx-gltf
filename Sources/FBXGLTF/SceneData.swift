import Foundation

/// Engine-agnostic intermediate representation extracted from an FBX scene.
/// Keeps the ufbx interop isolated from the glTF serialization.
struct SceneData {
    struct Node {
        static let identityRotation = SIMD4<Float>(0, 0, 0, 1)
        static let identityScale = SIMD3<Float>(repeating: 1)

        var name: String?
        var translation: SIMD3<Float> = .zero
        var rotationXYZW = identityRotation
        var scale = identityScale
        var meshIndex: Int?
        var childIndices: [Int] = []
    }

    /// Optional attributes are empty rather than nil, so that appending to one
    /// the mesh does not have cannot be silently dropped.
    struct Primitive {
        var positions: [Float] = [] // xyz triplets
        var normals: [Float] = [] // xyz triplets
        var uvs: [Float] = [] // uv pairs, top-left origin
        var colors: [Float] = [] // rgba quadruplets
        var indices: [UInt32] = []
        var materialIndex: Int?
        var joints: [UInt16] = [] // 4 per vertex, indices into the mesh's skin joints
        var weights: [Float] = [] // 4 per vertex, normalized to sum to 1
        var morphTargets: [MorphTarget] = [] // aligned with Mesh.morphChannels
    }

    struct MorphTarget {
        var positionDeltas: [Float] // xyz triplets, dense per vertex
        var normalDeltas: [Float] = [] // xyz triplets, empty when the shape has none
    }

    struct MorphChannel {
        var name: String?
        var defaultWeight: Float
    }

    struct Mesh {
        var name: String?
        var primitives: [Primitive]
        var skinIndex: Int?
        var morphChannels: [MorphChannel] = []
    }

    struct Skin {
        var jointNodeIndices: [Int]
        var inverseBindMatrices: [Float] // 16 column-major floats per joint
    }

    struct Animation {
        enum Path {
            case translation
            case rotation
            case scale
        }

        struct Channel {
            var nodeIndex: Int
            var path: Path
            var times: [Float] // seconds, starting at zero
            var values: [Float] // xyz triplets, or xyzw for rotation
        }

        /// Morph weight animation, targeting a mesh rather than a node because
        /// glTF animates the weights of every node instancing that mesh.
        struct WeightTrack {
            var meshIndex: Int
            var times: [Float] // seconds, starting at zero
            var values: [Float] // one weight per morph channel per key, flattened
        }

        var name: String?
        var channels: [Channel]
        var weightTracks: [WeightTrack] = []
    }

    struct Material {
        static let defaultBaseColorFactor = SIMD4<Float>(repeating: 1)

        var name: String?
        var baseColorFactor = defaultBaseColorFactor
        var metallicFactor: Float = 0
        var roughnessFactor: Float = 1
        var emissiveFactor: SIMD3<Float>?
        var baseColorTextureIndex: Int?
        var metallicRoughnessTextureIndex: Int?
        var normalTextureIndex: Int?
        var occlusionTextureIndex: Int?
        var emissiveTextureIndex: Int?
        var alphaBlend = false
        var doubleSided = false
    }

    struct Texture {
        /// How the sampler repeats outside [0,1], per axis.
        enum Wrap: Hashable {
            case repeating
            case clampU
            case clampV
            case clampBoth

            init(clampsU: Bool, clampsV: Bool) {
                switch (clampsU, clampsV) {
                case (false, false): self = .repeating
                case (true, false): self = .clampU
                case (false, true): self = .clampV
                case (true, true): self = .clampBoth
                }
            }

            var clampsU: Bool { self == .clampU || self == .clampBoth }
            var clampsV: Bool { self == .clampV || self == .clampBoth }
        }

        var name: String?
        var mimeType: String
        var data: Data
        var wrap: Wrap = .repeating
    }

    var rootIndices: [Int] = []
    var nodes: [Node] = []
    var meshes: [Mesh] = []
    var materials: [Material] = []
    var textures: [Texture] = []
    var skins: [Skin] = []
    var animations: [Animation] = []
    var warnings: [String] = []
}
