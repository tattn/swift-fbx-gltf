import Foundation

/// Minimal glTF 2.0 document model covering the subset emitted by the converter.
/// Optional collections are `nil` when empty because the spec forbids empty arrays.
struct GLTFDocument: Encodable {
    struct Asset: Encodable {
        var version = "2.0"
        var generator = "swift-fbx-gltf"
    }

    struct Scene: Encodable {
        var nodes: [Int]
    }

    struct Node: Encodable {
        var name: String?
        var children: [Int]?
        var translation: SIMD3<Float>?
        var rotation: SIMD4<Float>?
        var scale: SIMD3<Float>?
        var mesh: Int?
        var skin: Int?
    }

    struct Mesh: Encodable {
        struct Primitive: Encodable {
            var attributes: [String: Int]
            var indices: Int
            var material: Int?
            var targets: [[String: Int]]?
        }

        /// Morph target names live in `extras`; there is no dedicated field in
        /// the spec, but this layout is the convention viewers read.
        struct Extras: Encodable {
            var targetNames: [String]
        }

        var name: String?
        var primitives: [Primitive]
        var weights: [Float]?
        var extras: Extras?
    }

    struct Skin: Encodable {
        var inverseBindMatrices: Int
        var joints: [Int]
    }

    struct Animation: Encodable {
        struct Sampler: Encodable {
            var input: Int // SCALAR accessor of times; LINEAR interpolation is the default
            var output: Int
        }

        struct Channel: Encodable {
            struct Target: Encodable {
                var node: Int
                var path: TargetPath
            }

            var sampler: Int
            var target: Target
        }

        enum TargetPath: String, Encodable {
            case translation
            case rotation
            case scale
            case weights
        }

        var name: String?
        var samplers: [Sampler]
        var channels: [Channel]
    }

    struct Material: Encodable {
        struct PBRMetallicRoughness: Encodable {
            var baseColorFactor: SIMD4<Float>?
            var baseColorTexture: TextureInfo?
            var metallicFactor: Float?
            var roughnessFactor: Float?
            var metallicRoughnessTexture: TextureInfo?
        }

        struct TextureInfo: Encodable {
            var index: Int
        }

        enum AlphaMode: String, Encodable {
            case blend = "BLEND"
        }

        var name: String?
        var pbrMetallicRoughness: PBRMetallicRoughness?
        var normalTexture: TextureInfo?
        var occlusionTexture: TextureInfo?
        var emissiveTexture: TextureInfo?
        var emissiveFactor: SIMD3<Float>?
        var alphaMode: AlphaMode?
        var doubleSided: Bool?
    }

    struct Texture: Encodable {
        var sampler: Int?
        var source: Int
    }

    /// Emitted only for non-default wrapping; an omitted sampler means repeat.
    struct Sampler: Encodable {
        var wrapS: WrapMode?
        var wrapT: WrapMode?
    }

    enum WrapMode: Int, Encodable {
        case clampToEdge = 33071
    }

    struct Image: Encodable {
        var name: String?
        var mimeType: String
        var bufferView: Int
    }

    enum ComponentType: Int, Encodable {
        case unsignedShort = 5123
        case unsignedInt = 5125
        case float = 5126
    }

    enum AccessorType: String, Encodable {
        case scalar = "SCALAR"
        case vec2 = "VEC2"
        case vec3 = "VEC3"
        case vec4 = "VEC4"
        case mat4 = "MAT4"

        var componentCount: Int {
            switch self {
            case .scalar: 1
            case .vec2: 2
            case .vec3: 3
            case .vec4: 4
            case .mat4: 16
            }
        }
    }

    enum BufferTarget: Int, Encodable {
        case arrayBuffer = 34962
        case elementArrayBuffer = 34963
    }

    struct Accessor: Encodable {
        var bufferView: Int
        var componentType: ComponentType
        var count: Int
        var type: AccessorType
        // The spec requires bounds on POSITION (base and morph) and animation inputs
        var min: [Float]?
        var max: [Float]?
    }

    struct BufferView: Encodable {
        var buffer = 0
        var byteOffset: Int
        var byteLength: Int
        var target: BufferTarget?
    }

    struct Buffer: Encodable {
        var byteLength: Int
    }

    var asset = Asset()
    var scene = 0
    var scenes: [Scene]
    var nodes: [Node]
    var meshes: [Mesh]?
    var materials: [Material]?
    var textures: [Texture]?
    var samplers: [Sampler]?
    var images: [Image]?
    var skins: [Skin]?
    var animations: [Animation]?
    var accessors: [Accessor]?
    var bufferViews: [BufferView]?
    var buffers: [Buffer]?
}
