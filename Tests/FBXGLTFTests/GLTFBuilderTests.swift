import Foundation
import Testing
@testable import FBXGLTF

struct GLTFBuilderTests {
    private func makeSingleTriangleScene() -> SceneData {
        var scene = SceneData()
        scene.materials = [SceneData.Material(name: "mat", baseColorFactor: [1, 0, 0, 1])]
        scene.meshes = [
            SceneData.Mesh(name: "tri", primitives: [
                SceneData.Primitive(
                    positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
                    normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
                    uvs: [0, 0, 1, 0, 0, 1],
                    indices: [0, 1, 2],
                    materialIndex: 0
                ),
            ]),
        ]
        scene.nodes = [SceneData.Node(name: "root", meshIndex: 0)]
        scene.rootIndices = [0]
        return scene
    }

    @Test func buildsValidGLBContainer() throws {
        let glb = try GLTFBuilder.buildGLB(from: makeSingleTriangleScene())

        #expect(glb.count % 4 == 0)
        #expect(glb.readUInt32(at: 0) == 0x4654_6C67) // "glTF"
        #expect(glb.readUInt32(at: 4) == 2)
        #expect(glb.readUInt32(at: 8) == UInt32(glb.count))
        #expect(glb.readUInt32(at: 16) == 0x4E4F_534A) // "JSON"
    }

    @Test func buildsExpectedJSONStructure() throws {
        let glb = try GLTFBuilder.buildGLB(from: makeSingleTriangleScene())
        let json = try #require(glb.jsonChunk())

        #expect((json["scenes"] as? [[String: Any]])?.first?["nodes"] as? [Int] == [0])
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        #expect(nodes.count == 1)
        #expect(nodes[0]["mesh"] as? Int == 0)

        let meshes = try #require(json["meshes"] as? [[String: Any]])
        let primitive = try #require((meshes[0]["primitives"] as? [[String: Any]])?.first)
        let attributes = try #require(primitive["attributes"] as? [String: Int])
        #expect(Set(attributes.keys) == ["POSITION", "NORMAL", "TEXCOORD_0"])
        #expect(primitive["material"] as? Int == 0)

        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let positionAccessor = accessors[try #require(attributes["POSITION"])]
        #expect(positionAccessor["count"] as? Int == 3)
        #expect(positionAccessor["min"] as? [Double] == [0, 0, 0])
        #expect(positionAccessor["max"] as? [Double] == [1, 1, 0])

        // A GLB-stored buffer must not declare a URI
        let buffers = try #require(json["buffers"] as? [[String: Any]])
        #expect(buffers[0]["uri"] == nil)
    }

    @Test func omitsEmptyCollections() throws {
        var scene = SceneData()
        scene.nodes = [SceneData.Node(name: "empty")]
        scene.rootIndices = [0]

        let glb = try GLTFBuilder.buildGLB(from: scene)
        let json = try #require(glb.jsonChunk())

        #expect(json["meshes"] == nil)
        #expect(json["materials"] == nil)
        #expect(json["accessors"] == nil)
        #expect(json["buffers"] == nil)
    }

    /// The BIN chunk must be padded to a 4-byte boundary and its declared length
    /// must match both the buffer in the JSON and the bytes actually present.
    @Test func writesAPaddedBinaryChunkMatchingTheDeclaredBuffer() throws {
        let glb = try GLTFBuilder.buildGLB(from: makeSingleTriangleScene())
        let binary = try #require(glb.binaryChunk())

        #expect(binary.type == 0x004E_4942) // "BIN"
        #expect(binary.length % 4 == 0)
        #expect(binary.payload.count == binary.length)
        #expect(20 + glb.jsonChunkLength + 8 + binary.length == glb.count)

        let json = try #require(glb.jsonChunk())
        let buffers = try #require(json["buffers"] as? [[String: Any]])
        let declared = try #require(buffers[0]["byteLength"] as? Int)
        // 3 vertices: 36 B positions + 36 B normals + 24 B UVs + 12 B indices
        #expect(declared == 108)
        #expect(binary.length == declared.alignedToFour)
    }

    /// A scene with no geometry must omit the BIN chunk rather than emit an empty one.
    @Test func omitsTheBinaryChunkWhenThereIsNoGeometry() throws {
        var scene = SceneData()
        scene.nodes = [SceneData.Node(name: "empty")]
        scene.rootIndices = [0]

        let glb = try GLTFBuilder.buildGLB(from: scene)
        #expect(glb.binaryChunk() == nil)
        #expect(20 + glb.jsonChunkLength == glb.count)
    }
}

