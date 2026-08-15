import Foundation
import Testing
@testable import FBXGLTF

/// Covers the glTF defaulting rules applied when translating `SceneData.Material`.
struct MaterialMappingTests {
    private func materialJSON(_ material: SceneData.Material) throws -> [String: Any] {
        var scene = SceneData()
        scene.materials = [material]
        scene.nodes = [SceneData.Node(name: "n")]
        scene.rootIndices = [0]
        let json = try #require(try GLTFBuilder.buildGLB(from: scene).jsonChunk())
        let materials = try #require(json["materials"] as? [[String: Any]])
        return materials[0]
    }

    @Test func omitsTheDefaultBaseColorAndKeepsOthers() throws {
        let defaulted = try materialJSON(SceneData.Material(name: "m"))
        let pbr = try #require(defaulted["pbrMetallicRoughness"] as? [String: Any])
        #expect(pbr["baseColorFactor"] == nil)

        let tinted = try materialJSON(SceneData.Material(name: "m", baseColorFactor: [1, 0, 0, 1]))
        let tintedPBR = try #require(tinted["pbrMetallicRoughness"] as? [String: Any])
        #expect(tintedPBR["baseColorFactor"] as? [Double] == [1, 0, 0, 1])
    }

    /// glTF multiplies the emissive texture by a factor that defaults to zero, so a
    /// material carrying only an emissive texture would otherwise render unlit.
    @Test func suppliesAWhiteEmissiveFactorForATextureWithoutOne() throws {
        var material = SceneData.Material(name: "m")
        material.emissiveTextureIndex = 0
        #expect(try materialJSON(material)["emissiveFactor"] as? [Double] == [1, 1, 1])

        material.emissiveFactor = [0.5, 0.5, 0.5]
        #expect(try materialJSON(material)["emissiveFactor"] as? [Double] == [0.5, 0.5, 0.5])
    }

    @Test func omitsEmissiveFactorWhenThereIsNeitherTextureNorColor() throws {
        #expect(try materialJSON(SceneData.Material(name: "m"))["emissiveFactor"] == nil)
    }

    @Test func writesAlphaModeAndDoubleSidedOnlyWhenEnabled() throws {
        let opaque = try materialJSON(SceneData.Material(name: "m"))
        #expect(opaque["alphaMode"] == nil)
        #expect(opaque["doubleSided"] == nil)

        var blended = SceneData.Material(name: "m")
        blended.alphaBlend = true
        blended.doubleSided = true
        let json = try materialJSON(blended)
        #expect(json["alphaMode"] as? String == "BLEND")
        #expect(json["doubleSided"] as? Bool == true)
    }
}
