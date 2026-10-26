import Foundation
import Testing
@testable import FBXGLTF

/// End-to-end conversion of the checked-in OBJ fixtures, which bring their
/// materials from `.mtl` libraries and their textures from files beside them.
struct ObjConversionTests {
    private func convert(
        _ name: String, options: GLBConverter.Options = .init()
    ) throws -> (glb: Data, summary: GLBConverter.Summary, json: [String: Any]) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/obj/\(name)", withExtension: "obj"))
        let result = try GLBConverter(options: options).convert(contentsOf: url)
        return (result.glb, result.summary, try #require(result.glb.jsonChunk()))
    }

    private func mesh(named name: String, in json: [String: Any]) throws -> [String: Any] {
        let meshes = try #require(json["meshes"] as? [[String: Any]])
        return try #require(meshes.first { $0["name"] as? String == name })
    }

    private func material(named name: String, in json: [String: Any]) throws -> [String: Any] {
        let materials = try #require(json["materials"] as? [[String: Any]])
        return try #require(materials.first { $0["name"] as? String == name })
    }

    /// Each `o` statement becomes its own node and mesh.
    @Test func convertsEachObjectIntoANodeAndMesh() throws {
        let (glb, summary, json) = try convert("props")
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        #expect(nodes.compactMap { $0["name"] as? String } == ["Crate", "Pane"])
        #expect(summary.meshCount == 2)
        // Six quads and a hexagon fan
        #expect(summary.triangleCount == 12 + 4)
        #expect(summary.materialCount == 2)
        #expect(summary.warnings.isEmpty)
        #expect(summary.byteCount == glb.count)
    }

    /// `map_Kd` points at a PNG next to the library, which has to end up inside the GLB.
    @Test func embedsTheDiffuseMapFromTheMaterialLibrary() throws {
        let (glb, summary, json) = try convert("props")
        #expect(summary.textureCount == 1)
        let wood = try material(named: "wood", in: json)
        let pbr = try #require(wood["pbrMetallicRoughness"] as? [String: Any])
        let textureIndex = try #require((pbr["baseColorTexture"] as? [String: Any])?["index"] as? Int)
        let textures = try #require(json["textures"] as? [[String: Any]])
        let imageIndex = try #require(textures[textureIndex]["source"] as? Int)
        let images = try #require(json["images"] as? [[String: Any]])
        #expect(images[imageIndex]["name"] as? String == "checker")
        let bufferView = try #require(images[imageIndex]["bufferView"] as? Int)
        let png = try #require(glb.bytes(ofBufferView: bufferView, in: json))
        let image = try #require(RGBA8Image(png: png))
        #expect(image.width == 4 && image.height == 4)
    }

    /// `Kd` and the `d` dissolve become a translucent base color.
    @Test func turnsDissolveIntoAlphaBlending() throws {
        let (_, _, json) = try convert("props")
        let glass = try material(named: "glass", in: json)
        let pbr = try #require(glass["pbrMetallicRoughness"] as? [String: Any])
        #expect(pbr["baseColorFactor"] as? [Double] == [0.2, 0.4, 0.8, 0.5])
        #expect(glass["alphaMode"] as? String == "BLEND")
    }

    /// OBJ puts the texture origin at the bottom left and glTF at the top left.
    @Test func flipsTextureCoordinatesVertically() throws {
        let (glb, _, json) = try convert("props")
        let crate = try mesh(named: "Crate", in: json)
        let attributes = try #require((crate["primitives"] as? [[String: Any]])?.first?["attributes"] as? [String: Int])
        let positions = try floats(of: try #require(attributes["POSITION"]), components: 3, in: glb, json: json)
        let uvs = try floats(of: try #require(attributes["TEXCOORD_0"]), components: 2, in: glb, json: json)
        // The corner (-0.5, -0.5, 0.5) is written with `vt 0 0`, `vt 1 0` and `vt 0 1` on its three faces
        let corner: [Float] = [-0.5, -0.5, 0.5]
        let cornerUVs = Set(zip(positions, uvs).filter { $0.0 == corner }.map(\.1))
        #expect(cornerUVs == [[0, 1], [1, 1], [0, 0]])
    }

    /// The pane has no `vn` lines, so its normals are generated facing along its plane's normal.
    @Test func generatesMissingNormals() throws {
        let (glb, _, json) = try convert("props")
        let pane = try mesh(named: "Pane", in: json)
        let attributes = try #require((pane["primitives"] as? [[String: Any]])?.first?["attributes"] as? [String: Int])
        let normals = try floats(of: try #require(attributes["NORMAL"]), components: 3, in: glb, json: json)
        #expect(!normals.isEmpty)
        #expect(normals.allSatisfy { $0 == [0, 0, 1] })
    }

    /// A library renamed after export is found by the OBJ's own name, without a warning.
    @Test func findsARenamedLibraryByTheObjName() throws {
        let (_, summary, json) = try convert("renamed_library")
        let red = try material(named: "red", in: json)
        let pbr = try #require(red["pbrMetallicRoughness"] as? [String: Any])
        #expect(pbr["baseColorFactor"] as? [Double] == [1, 0, 0, 1])
        #expect(summary.warnings.isEmpty)
    }

    /// A missing library still converts the geometry and says which file was missing.
    @Test func convertsWithoutTheLibraryAndWarns() throws {
        let (_, summary, _) = try convert("missing_library")
        #expect(summary.triangleCount == 1)
        #expect(summary.warnings.count == 1)
        #expect(summary.warnings.first?.contains("missing_materials.mtl") == true)
    }

    /// OBJ does not record its unit, so the caller's assumption decides the scale.
    @Test func scalesByTheAssumedObjUnit() throws {
        let (_, _, json) = try convert("props", options: .init(objUnitMeters: 0.01))
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        for node in nodes {
            let scale = try #require(node["scale"] as? [Double])
            for component in scale {
                #expect(abs(component - 0.01) < 1e-6)
            }
        }
    }

    private func floats(of accessorIndex: Int, components: Int, in glb: Data, json: [String: Any]) throws -> [[Float]] {
        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let accessor = accessors[accessorIndex]
        let count = try #require(accessor["count"] as? Int)
        let bufferView = try #require(accessor["bufferView"] as? Int)
        let bytes = try #require(glb.bytes(ofBufferView: bufferView, in: json))
        let offset = accessor["byteOffset"] as? Int ?? 0
        return bytes.withUnsafeBytes { raw in
            (0..<count).map { vertex in
                (0..<components).map { component in
                    raw.loadUnaligned(fromByteOffset: offset + (vertex * components + component) * 4, as: Float.self)
                }
            }
        }
    }
}
