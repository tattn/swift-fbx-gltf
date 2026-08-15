import Foundation
import Testing
@testable import FBXGLTF

/// End-to-end conversion of the checked-in FBX fixtures. Each expectation pins a
/// distinct converter behaviour, so a failure names the feature that regressed
/// rather than just reporting that some bytes moved.
struct FixtureConversionTests {
    private func convert(_ name: String) throws -> (glb: Data, summary: FBXToGLBConverter.Summary, json: [String: Any]) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "fbx"))
        let result = try FBXToGLBConverter().convert(contentsOf: url)
        return (result.glb, result.summary, try #require(result.glb.jsonChunk()))
    }

    private func meshes(_ json: [String: Any]) throws -> [[String: Any]] {
        try #require(json["meshes"] as? [[String: Any]])
    }

    private func nodes(_ json: [String: Any]) throws -> [[String: Any]] {
        try #require(json["nodes"] as? [[String: Any]])
    }

    @Test func convertsTheCharacterSceneWholesale() throws {
        let (glb, summary, _) = try convert("character_scene")
        #expect(summary.nodeCount == 64)
        #expect(summary.meshCount == 4)
        #expect(summary.primitiveCount == 5)
        #expect(summary.triangleCount == 1701)
        #expect(summary.animationCount == 1)
        #expect(summary.byteCount == glb.count)
        #expect(summary.warnings.isEmpty)
        #expect(glb.count % 4 == 0)
    }

    /// A mesh whose polygons reference two materials becomes several primitives.
    @Test func splitsAMeshWithSeveralMaterialsIntoPrimitives() throws {
        let (_, _, json) = try convert("character_scene")
        let character = try #require(try meshes(json).first { $0["name"] as? String == "characterMedium" })
        let primitives = try #require(character["primitives"] as? [[String: Any]])
        #expect(primitives.count == 2)
        #expect(Set(primitives.compactMap { $0["material"] as? Int }).count == 2)
    }

    /// Two nodes sharing one FBX geometry must share one glTF mesh.
    @Test func sharesOneMeshBetweenInstancedNodes() throws {
        let (_, _, json) = try convert("character_scene")
        let crateNodes = try nodes(json).filter { ($0["name"] as? String)?.hasPrefix("Crate") == true }
        #expect(crateNodes.count == 2)
        #expect(Set(crateNodes.compactMap { $0["mesh"] as? Int }).count == 1)
    }

    /// A 7-gon has to survive triangulation as a five-triangle fan.
    @Test func triangulatesPolygonsWithMoreThanFourCorners() throws {
        let (glb, _, json) = try convert("character_scene")
        let signboard = try #require(try meshes(json).first { $0["name"] as? String == "看板メッシュ" })
        let primitive = try #require((signboard["primitives"] as? [[String: Any]])?.first)
        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let indicesAccessor = try #require(primitive["indices"] as? Int)
        let indexCount = try #require(accessors[indicesAccessor]["count"] as? Int)
        #expect(indexCount / 3 == 5)
        #expect(glb.count > 0)
    }

    @Test func keepsNonASCIINodeNames() throws {
        let (_, _, json) = try convert("character_scene")
        #expect(try nodes(json).contains { $0["name"] as? String == "看板" })
    }

    /// FBX stores vertex colors as sRGB by convention; glTF requires linear.
    /// The fixture's green channel is authored at a constant linear 0.25.
    @Test func exportsVertexColorsInLinearSpace() throws {
        let (glb, _, json) = try convert("character_scene")
        let signboard = try #require(try meshes(json).first { $0["name"] as? String == "看板メッシュ" })
        let primitive = try #require((signboard["primitives"] as? [[String: Any]])?.first)
        let attributes = try #require(primitive["attributes"] as? [String: Int])
        let colorAccessorIndex = try #require(attributes["COLOR_0"])

        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let accessor = accessors[colorAccessorIndex]
        #expect(accessor["type"] as? String == "VEC4")
        let count = try #require(accessor["count"] as? Int)

        let viewIndex = try #require(accessor["bufferView"] as? Int)
        let colors: [Float] = try #require(glb.bytes(ofBufferView: viewIndex, in: json))
            .prefix(count * 16)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let reds = stride(from: 0, to: colors.count, by: 4).map { colors[$0] }
        let greens = stride(from: 1, to: colors.count, by: 4).map { colors[$0] }
        #expect(abs(reds.min()! - 0) < 0.01 && abs(reds.max()! - 1) < 0.01)
        for green in greens {
            #expect(abs(green - 0.25) < 0.01)
        }
    }

    /// Clamped FBX textures need a glTF sampler; repeating ones use the default.
    @Test func emitsSamplersOnlyForClampedTextures() throws {
        let (_, _, json) = try convert("character_scene")
        let samplers = try #require(json["samplers"] as? [[String: Any]])
        #expect(samplers.count == 1)
        #expect(samplers[0]["wrapS"] as? Int == 33071)
        #expect(samplers[0]["wrapT"] as? Int == 33071)

        let textures = try #require(json["textures"] as? [[String: Any]])
        let images = try #require(json["images"] as? [[String: Any]])
        let samplerByImageName = Dictionary(uniqueKeysWithValues: textures.map { texture in
            (images[texture["source"] as! Int]["name"] as? String ?? "?", texture["sampler"] as? Int)
        })
        #expect(samplerByImageName["metallicRoughness"] == 0)
        #expect(samplerByImageName["base_color_texture"] == .some(nil))
    }

    /// The textures are embedded in the FBX, so conversion must not need side files.
    @Test func embedsTheTexturesInTheBinaryChunk() throws {
        let (_, summary, json) = try convert("character_scene")
        #expect(summary.textureCount == 2)
        let images = try #require(json["images"] as? [[String: Any]])
        let bufferViews = try #require(json["bufferViews"] as? [[String: Any]])
        for image in images {
            #expect(image["mimeType"] as? String == "image/png")
            #expect(image["uri"] == nil)
            let imageBufferView = try #require(image["bufferView"] as? Int)
            let length = try #require(bufferViews[imageBufferView]["byteLength"] as? Int)
            #expect(length > 0)
        }
    }

    /// The separate FBX metallic and roughness gradient textures are packed into
    /// glTF's single texture: roughness in G growing along U, metallic in B along V.
    @Test func packsMetallicAndRoughnessTexturesIntoOne() throws {
        let (glb, _, json) = try convert("character_scene")
        let materials = try #require(json["materials"] as? [[String: Any]])
        let accent = try #require(materials.first { $0["name"] as? String == "accent" })
        let pbr = try #require(accent["pbrMetallicRoughness"] as? [String: Any])
        let textureInfo = try #require(pbr["metallicRoughnessTexture"] as? [String: Any])
        // The packed channels carry the data, so the factors must not scale it away
        #expect(pbr["metallicFactor"] as? Double == 1)
        #expect(pbr["roughnessFactor"] as? Double == 1)

        let textures = try #require(json["textures"] as? [[String: Any]])
        let textureIndex = try #require(textureInfo["index"] as? Int)
        let imageIndex = try #require(textures[textureIndex]["source"] as? Int)
        let images = try #require(json["images"] as? [[String: Any]])
        let viewIndex = try #require(images[imageIndex]["bufferView"] as? Int)
        let png = try #require(glb.bytes(ofBufferView: viewIndex, in: json))

        let pixels = try #require(RGBA8Image(png: png))
        #expect(pixels.width == 64 && pixels.height == 64)
        // Roughness gradient runs along U: G goes dark to bright left to right
        #expect(pixels.channel(1, x: 2, y: 32) < 30)
        #expect(pixels.channel(1, x: 61, y: 32) > 225)
        #expect(abs(Int(pixels.channel(1, x: 32, y: 2)) - Int(pixels.channel(1, x: 32, y: 61))) < 10)
        // Metallic gradient runs along V: B varies top to bottom, flat horizontally
        let metallicTop = pixels.channel(2, x: 32, y: 2)
        let metallicBottom = pixels.channel(2, x: 32, y: 61)
        #expect(abs(Int(metallicTop) - Int(metallicBottom)) > 200)
        #expect(abs(Int(pixels.channel(2, x: 2, y: 32)) - Int(pixels.channel(2, x: 61, y: 32))) < 10)
    }

    /// The skinned character carries a skin whose joints and bind matrices line up.
    @Test func exportsSkinWithJointsAndWeights() throws {
        let (_, _, json) = try convert("character_scene")
        let skins = try #require(json["skins"] as? [[String: Any]])
        #expect(skins.count == 1)
        let joints = try #require(skins[0]["joints"] as? [Int])
        #expect(joints.count == 58)

        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let bindMatrices = accessors[try #require(skins[0]["inverseBindMatrices"] as? Int)]
        #expect(bindMatrices["type"] as? String == "MAT4")
        #expect(bindMatrices["count"] as? Int == joints.count)

        let character = try #require(try meshes(json).first { $0["name"] as? String == "characterMedium" })
        for primitive in try #require(character["primitives"] as? [[String: Any]]) {
            let attributes = try #require(primitive["attributes"] as? [String: Int])
            #expect(attributes["JOINTS_0"] != nil)
            #expect(attributes["WEIGHTS_0"] != nil)
        }
        let characterNode = try #require(try nodes(json).first { $0["name"] as? String == "characterMedium" })
        #expect(characterNode["skin"] as? Int == 0)
    }

    /// The animation stack becomes baked TRS channels with the bounds the spec requires.
    @Test func exportsBakedAnimationChannels() throws {
        let (_, _, json) = try convert("character_scene")
        let animations = try #require(json["animations"] as? [[String: Any]])
        #expect(animations.count == 1)
        let channels = try #require(animations[0]["channels"] as? [[String: Any]])
        let samplers = try #require(animations[0]["samplers"] as? [[String: Any]])
        #expect(channels.count == samplers.count)
        let paths = Set(channels.compactMap { ($0["target"] as? [String: Any])?["path"] as? String })
        #expect(paths == ["translation", "rotation", "scale", "weights"])

        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let nodeCount = try nodes(json).count
        for channel in channels {
            let target = try #require(channel["target"] as? [String: Any])
            let node = try #require(target["node"] as? Int)
            #expect((0..<nodeCount).contains(node))
        }
        for sampler in samplers {
            let input = accessors[try #require(sampler["input"] as? Int)]
            #expect(input["min"] != nil && input["max"] != nil)
        }
    }

    /// Blend shapes become morph targets with the conventional names in extras.
    @Test func exportsMorphTargets() throws {
        let (_, _, json) = try convert("character_scene")
        let blob = try #require(try meshes(json).first { $0["name"] as? String == "BlobMesh" })
        let primitive = try #require((blob["primitives"] as? [[String: Any]])?.first)
        let targets = try #require(primitive["targets"] as? [[String: Int]])
        #expect(targets.count == 1)
        let extras = try #require(blob["extras"] as? [String: Any])
        #expect(extras["targetNames"] as? [String] == ["Bulge"])

        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let deltas = accessors[try #require(targets[0]["POSITION"])]
        // The spec requires bounds on morph POSITION deltas as well
        #expect(deltas["min"] != nil && deltas["max"] != nil)
        let positions = accessors[try #require((primitive["attributes"] as? [String: Int])?["POSITION"])]
        #expect(deltas["count"] as? Int == positions["count"] as? Int)
    }

    /// The animated shape key becomes a weights channel on the node with the mesh,
    /// carrying one weight per morph target per key.
    @Test func exportsMorphWeightAnimation() throws {
        let (_, _, json) = try convert("character_scene")
        let animations = try #require(json["animations"] as? [[String: Any]])
        let channels = try #require(animations[0]["channels"] as? [[String: Any]])
        let weightChannels = channels.filter { ($0["target"] as? [String: Any])?["path"] as? String == "weights" }
        #expect(weightChannels.count == 1)

        let target = try #require(weightChannels[0]["target"] as? [String: Any])
        let node = try nodes(json)[try #require(target["node"] as? Int)]
        #expect(node["name"] as? String == "Blob")

        let samplers = try #require(animations[0]["samplers"] as? [[String: Any]])
        let sampler = samplers[try #require(weightChannels[0]["sampler"] as? Int)]
        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let input = accessors[try #require(sampler["input"] as? Int)]
        let output = accessors[try #require(sampler["output"] as? Int)]
        let keyCount = try #require(input["count"] as? Int)
        let blob = try #require(try meshes(json).first { $0["name"] as? String == "BlobMesh" })
        let targetCount = try #require((blob["primitives"] as? [[String: Any]])?.first?["targets"] as? [[String: Int]]).count
        #expect(output["count"] as? Int == keyCount * targetCount)
    }

    /// The fixture is authored Z-up, so the root has to carry the -90° X rotation
    /// that brings it into glTF's Y-up convention.
    @Test func rotatesAZUpSceneIntoGLTFOrientation() throws {
        let (_, _, json) = try convert("character_scene")
        let rotation = try #require(try nodes(json)[0]["rotation"] as? [Double])
        #expect(abs(abs(rotation[0]) - 0.7071068) < 1e-5)
        #expect(abs(rotation[1]) < 1e-6)
        #expect(abs(rotation[2]) < 1e-6)
        #expect(abs(abs(rotation[3]) - 0.7071068) < 1e-5)
    }

    /// A centimetre scene has to be scaled into metres.
    @Test func scalesACentimetreSceneIntoMetres() throws {
        let (_, summary, json) = try convert("units_centimeters")
        #expect(summary.meshCount == 1)
        let scale = try #require(try nodes(json)[0]["scale"] as? [Double])
        for component in scale {
            #expect(abs(component - 0.01) < 1e-9)
        }
    }

    @Test func producesTheSameBytesEveryRun() throws {
        let first = try convert("character_scene").glb
        let second = try convert("character_scene").glb
        #expect(first == second)
    }
}
