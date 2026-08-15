import CUfbx
import Foundation

/// Loads an FBX file with ufbx and extracts a `SceneData`.
struct FBXSceneLoader {
    /// The unit in meters the scene is scaled to.
    var targetUnitMeters: Double

    func load(contentsOf url: URL) throws(FBXGLTFError) -> SceneData {
        var loadOptions = ufbx_load_opts()
        loadOptions.generate_missing_normals = true
        // Normalize to the glTF conventions: right-handed Y-up, meters.
        loadOptions.target_axes = ufbx_axes_right_handed_y_up
        loadOptions.target_unit_meters = ufbx_real(targetUnitMeters)
        loadOptions.space_conversion = UFBX_SPACE_CONVERSION_ADJUST_TRANSFORMS
        // Bake FBX geometric transforms (pivot offsets) into extra nodes so
        // the node hierarchy stays valid for formats without them.
        loadOptions.geometry_transform_handling = UFBX_GEOMETRY_TRANSFORM_HANDLING_HELPER_NODES
        // Blender flattens its PBR materials into legacy Phong slots; this reads
        // them back as authored (metallic from ReflectionFactor, roughness from
        // ShininessExponent) for files Blender exported.
        loadOptions.use_blender_pbr_material = true

        var error = ufbx_error()
        guard let scene = ufbx_load_file(url.path, &loadOptions, &error) else {
            throw FBXGLTFError.loadFailed(Self.message(from: &error))
        }
        defer { ufbx_free_scene(scene) }

        var context = ExtractionContext(baseURL: url.deletingLastPathComponent())
        if let rootNode = scene.pointee.root_node {
            for child in list(rootNode.pointee.children) {
                guard let child else { continue }
                let index = context.extractNode(child)
                context.data.rootIndices.append(index)
            }
        }
        // Bone nodes can be traversed after the meshes bound to them, so
        // anything referencing nodes by identity resolves once the map is complete.
        context.resolveSkins()
        context.extractAnimations(scene)
        return context.data
    }

    private static func message(from error: inout ufbx_error) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = ufbx_format_error(&buffer, buffer.count, &error)
        return buffer.withUnsafeBytes { String(decoding: $0.prefix(Int(length)), as: UTF8.self) }
    }
}

/// Mutable state shared across the recursive scene traversal.
private struct ExtractionContext {
    let baseURL: URL
    var data = SceneData()

    private var meshIndices: [MeshInstanceKey: Int] = [:]
    private var materialIndices: [UnsafeRawPointer: Int] = [:]
    private var textureIndices: [TextureKey: Int?] = [:]
    private var packedTextureIndices: [PackedTextureKey: Int?] = [:]
    private var seenWarnings: Set<String> = []
    private var nodeIndexByTypedId: [UInt32: Int] = [:]
    private var pendingSkins: [(meshIndex: Int, deformer: UnsafeMutablePointer<ufbx_skin_deformer>)] = []
    private var morphSlotsByElementId: [UInt32: (meshIndex: Int, slot: Int)] = [:]

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    mutating func extractNode(_ node: UnsafeMutablePointer<ufbx_node>) -> Int {
        var result = SceneData.Node()
        result.name = String(ufbx: node.pointee.name)

        let transform = node.pointee.local_transform
        result.translation = SIMD3(transform.translation)
        result.rotationXYZW = SIMD4(transform.rotation)
        result.scale = SIMD3(transform.scale)

        if let mesh = node.pointee.mesh {
            result.meshIndex = extractMesh(mesh, node: node)
        }

        let index = data.nodes.count
        data.nodes.append(result)
        nodeIndexByTypedId[node.pointee.typed_id] = index

        var childIndices: [Int] = []
        for child in list(node.pointee.children) {
            guard let child else { continue }
            childIndices.append(extractNode(child))
        }
        data.nodes[index].childIndices = childIndices
        return index
    }

    // MARK: - Meshes

    private mutating func extractMesh(_ mesh: UnsafeMutablePointer<ufbx_mesh>, node: UnsafeMutablePointer<ufbx_node>) -> Int {
        // Per-instance materials live on the node; fall back to the mesh's own list.
        let nodeMaterials = list(node.pointee.materials)
        let instanceMaterials = nodeMaterials.isEmpty ? Array(list(mesh.pointee.materials)) : Array(nodeMaterials)

        let key = MeshInstanceKey(mesh: UnsafeRawPointer(mesh), materials: instanceMaterials)
        if let existing = meshIndices[key] {
            return existing
        }

        let meshName = String(ufbx: mesh.pointee.name)
        let skin = firstSkinDeformer(of: mesh, meshName: meshName)
        let morphs = morphSources(of: mesh)

        var primitives: [SceneData.Primitive] = []
        for part in list(mesh.pointee.material_parts) {
            guard let primitive = extractPrimitive(
                mesh, part: part, instanceMaterials: instanceMaterials, skin: skin, morphs: morphs
            ) else { continue }
            primitives.append(primitive)
        }

        let index = data.meshes.count
        var result = SceneData.Mesh(name: meshName, primitives: primitives)
        result.morphChannels = morphs.map { SceneData.MorphChannel(name: $0.name, defaultWeight: $0.defaultWeight) }
        data.meshes.append(result)
        if let skin {
            pendingSkins.append((meshIndex: index, deformer: skin))
        }
        for (slot, morph) in morphs.enumerated() {
            morphSlotsByElementId[morph.channelElementId] = (meshIndex: index, slot: slot)
        }
        meshIndices[key] = index
        return index
    }

    /// The skin used for this mesh, or nil when the mesh is static or the
    /// deformer carries no usable weights.
    private mutating func firstSkinDeformer(
        of mesh: UnsafeMutablePointer<ufbx_mesh>, meshName: String?
    ) -> UnsafeMutablePointer<ufbx_skin_deformer>? {
        guard let deformer = list(mesh.pointee.skin_deformers).first ?? nil else { return nil }
        guard !list(deformer.pointee.clusters).isEmpty, !list(deformer.pointee.vertices).isEmpty else {
            addWarning("Mesh \"\(meshName ?? "?")\" has an empty skin; it is exported as a static mesh.")
            return nil
        }
        if deformer.pointee.skinning_method != UFBX_SKINNING_METHOD_LINEAR {
            addWarning("Mesh \"\(meshName ?? "?")\" uses non-linear skinning, which glTF approximates with linear blending.")
        }
        if deformer.pointee.max_weights_per_vertex > 4 {
            addWarning("Mesh \"\(meshName ?? "?")\" has vertices with more than 4 bone influences; the strongest 4 are kept.")
        }
        return deformer
    }

    /// Blend shapes flattened to per-control-point offsets, in channel order.
    private func morphSources(of mesh: UnsafeMutablePointer<ufbx_mesh>) -> [MorphSource] {
        var sources: [MorphSource] = []
        for deformer in list(mesh.pointee.blend_deformers) {
            guard let deformer else { continue }
            for channel in list(deformer.pointee.channels) {
                guard let channel, let shape = channel.pointee.target_shape else { continue }
                sources.append(MorphSource(
                    name: String(ufbx: channel.pointee.name) ?? String(ufbx: shape.pointee.name),
                    defaultWeight: Float(channel.pointee.weight),
                    channelElementId: channel.pointee.element_id,
                    shape: shape
                ))
            }
        }
        return sources
    }

    private mutating func extractPrimitive(
        _ mesh: UnsafeMutablePointer<ufbx_mesh>,
        part: ufbx_mesh_part,
        instanceMaterials: [UnsafeMutablePointer<ufbx_material>?],
        skin: UnsafeMutablePointer<ufbx_skin_deformer>?,
        morphs: [MorphSource]
    ) -> SceneData.Primitive? {
        guard part.num_triangles > 0 else { return nil }

        let positions = mesh.pointee.vertex_position
        let normals = mesh.pointee.vertex_normal
        let uvs = mesh.pointee.vertex_uv
        let colors = mesh.pointee.vertex_color
        let faces = list(mesh.pointee.faces)
        let cornerVertices = list(mesh.pointee.vertex_indices)
        // Deformation data attaches to control points, so equal attributes from
        // different control points must then stay separate vertices.
        let weldByControlPoint = skin != nil || !morphs.isEmpty

        var primitive = SceneData.Primitive()
        let cornerCount = Int(part.num_triangles) * 3
        primitive.positions.reserveCapacity(cornerCount * 3)
        primitive.normals.reserveCapacity(cornerCount * 3)
        if uvs.exists { primitive.uvs.reserveCapacity(cornerCount * 2) }
        if colors.exists { primitive.colors.reserveCapacity(cornerCount * 4) }
        primitive.indices.reserveCapacity(cornerCount)

        // FBX vertex colors are conventionally sRGB (Blender both writes and
        // reads them that way) while glTF requires linear. Converting the value
        // table once keeps the transfer function out of the per-corner loop.
        let linearColors = colors.exists ? Self.linearColorValues(of: colors) : []

        var controlPoints: [UInt32] = []
        var vertices = VertexTable(minimumCapacity: cornerCount)
        var triangleIndexBuffer = [UInt32](repeating: 0, count: max(mesh.pointee.max_face_triangles * 3, 3))

        for faceIndex in list(part.face_indices) {
            let face = faces[Int(faceIndex)]
            let triangleCount = ufbx_triangulate_face(&triangleIndexBuffer, triangleIndexBuffer.count, mesh, face)
            for corner in 0..<(Int(triangleCount) * 3) {
                let attributeIndex = Int(triangleIndexBuffer[corner])
                let position = positions.vec3(at: attributeIndex)
                let normal = normals.vec3(at: attributeIndex)
                let uv = uvs.exists ? uvs.vec2(at: attributeIndex) : nil
                let color = colors.exists ? linearColors[colors.valueIndex(at: attributeIndex)] : nil
                let controlPoint = cornerVertices[attributeIndex]

                let key = VertexKey(
                    position: position, normal: normal, uv: uv, color: color,
                    vertex: weldByControlPoint ? controlPoint : 0
                )
                let (vertexIndex, isNew) = vertices.index(for: key)
                primitive.indices.append(vertexIndex)
                guard isNew else { continue }
                if weldByControlPoint {
                    controlPoints.append(controlPoint)
                }
                primitive.positions.append(position.0)
                primitive.positions.append(position.1)
                primitive.positions.append(position.2)
                primitive.normals.append(normal.0)
                primitive.normals.append(normal.1)
                primitive.normals.append(normal.2)
                if let uv {
                    // glTF uses a top-left UV origin while FBX uses bottom-left
                    primitive.uvs.append(uv.0)
                    primitive.uvs.append(1 - uv.1)
                }
                if let color {
                    primitive.colors.append(color.0)
                    primitive.colors.append(color.1)
                    primitive.colors.append(color.2)
                    primitive.colors.append(color.3)
                }
            }
        }

        if let skin {
            (primitive.joints, primitive.weights) = skinAttributes(of: skin, controlPoints: controlPoints)
        }
        primitive.morphTargets = morphs.map { $0.target(for: controlPoints) }

        let materialSlot = Int(part.index)
        if materialSlot < instanceMaterials.count, let material = instanceMaterials[materialSlot] {
            primitive.materialIndex = extractMaterial(material)
        }
        return primitive
    }

    /// The attribute's value table converted from sRGB to linear once, so that
    /// the transfer function runs per distinct color rather than per corner.
    private static func linearColorValues(of colors: ufbx_vertex_vec4) -> [(Float, Float, Float, Float)] {
        func linear(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return list(colors.values).map { value in
            // Alpha is coverage, not color, and stays linear
            (linear(Float(value.x)), linear(Float(value.y)), linear(Float(value.z)), Float(value.w))
        }
    }

    /// Per-vertex JOINTS_0/WEIGHTS_0 data: the strongest four influences,
    /// renormalized. ufbx sorts weights by decreasing value.
    private func skinAttributes(
        of skin: UnsafeMutablePointer<ufbx_skin_deformer>,
        controlPoints: [UInt32]
    ) -> ([UInt16], [Float]) {
        let skinVertices = list(skin.pointee.vertices)
        let skinWeights = list(skin.pointee.weights)
        var joints = [UInt16](repeating: 0, count: controlPoints.count * 4)
        var weights = [Float](repeating: 0, count: controlPoints.count * 4)

        for (vertex, controlPoint) in controlPoints.enumerated() {
            guard Int(controlPoint) < skinVertices.count else { continue }
            let influences = skinVertices[Int(controlPoint)]
            let kept = min(4, Int(influences.num_weights))
            var sum: Float = 0
            for slot in 0..<kept {
                sum += Float(skinWeights[Int(influences.weight_begin) + slot].weight)
            }
            guard sum > 0 else {
                // A vertex the skin does not influence pins to the first joint
                weights[vertex * 4] = 1
                continue
            }
            for slot in 0..<kept {
                let influence = skinWeights[Int(influences.weight_begin) + slot]
                joints[vertex * 4 + slot] = UInt16(clamping: influence.cluster_index)
                weights[vertex * 4 + slot] = Float(influence.weight) / sum
            }
        }
        return (joints, weights)
    }

    // MARK: - Materials

    private mutating func extractMaterial(_ material: UnsafeMutablePointer<ufbx_material>) -> Int {
        if let existing = materialIndices[UnsafeRawPointer(material)] {
            return existing
        }

        let pbr = material.pointee.pbr
        var result = SceneData.Material()
        result.name = String(ufbx: material.pointee.name)

        var baseColor = pbr.base_color.has_value ? SIMD3(pbr.base_color.value_vec4) : SIMD3(repeating: 1)
        if pbr.base_factor.has_value {
            baseColor *= Float(pbr.base_factor.value_real)
        }
        let opacity = pbr.opacity.has_value ? Float(pbr.opacity.value_real) : 1
        result.baseColorFactor = SIMD4(baseColor, opacity).clamped01

        // With the glossiness feature the roughness map carries inverted data
        let roughnessIsGlossiness = material.pointee.features.roughness_as_glossiness.enabled
        if pbr.metalness.has_value {
            result.metallicFactor = Float(pbr.metalness.value_real).clamped01
        }
        if pbr.roughness.has_value {
            let value = Float(pbr.roughness.value_real).clamped01
            result.roughnessFactor = roughnessIsGlossiness ? 1 - value : value
        }
        let metalTexture = resolveFileTexture(of: pbr.metalness)
        let roughTexture = resolveFileTexture(of: pbr.roughness)
        result.metallicRoughnessTextureIndex = extractMetallicRoughnessTexture(
            metalTexture: metalTexture, roughTexture: roughTexture, invertRoughness: roughnessIsGlossiness
        )
        if result.metallicRoughnessTextureIndex != nil {
            // The packed channels carry the values; a texture-less channel stays
            // white so the factor still applies to it.
            if metalTexture != nil { result.metallicFactor = 1 }
            if roughTexture != nil { result.roughnessFactor = 1 }
        }

        if pbr.emission_color.has_value {
            let factor = pbr.emission_factor.has_value ? Float(pbr.emission_factor.value_real) : 1
            let emissive = (SIMD3(pbr.emission_color.value_vec4) * factor).clamped01
            if emissive != .zero {
                result.emissiveFactor = emissive
            }
        }

        result.baseColorTextureIndex = extractTexture(from: pbr.base_color)
        result.normalTextureIndex = extractTexture(from: pbr.normal_map)
        result.occlusionTextureIndex = extractTexture(from: pbr.ambient_occlusion)
        result.emissiveTextureIndex = extractTexture(from: pbr.emission_color)

        // Semi-transparency in FBX is factor/texture based; texture alpha channels are
        // intentionally ignored here to avoid turning opaque RGBA textures translucent.
        result.alphaBlend = opacity < 1 || (pbr.opacity.texture_enabled && pbr.opacity.texture != nil)
        result.doubleSided = material.pointee.features.double_sided.enabled

        let index = data.materials.count
        data.materials.append(result)
        materialIndices[UnsafeRawPointer(material)] = index
        return index
    }

    // MARK: - Textures

    /// Resolves a material map to a concrete file texture, approximating
    /// procedural and layered textures by the first file they reference.
    private mutating func resolveFileTexture(of map: ufbx_material_map) -> UnsafeMutablePointer<ufbx_texture>? {
        guard map.texture_enabled, let texture = map.texture else { return nil }
        let name = String(ufbx: texture.pointee.name) ?? "?"
        var resolved = texture
        if texture.pointee.type != UFBX_TEXTURE_FILE {
            guard let file = list(texture.pointee.file_textures)
                .compactMap({ $0 })
                .first(where: { $0.pointee.type == UFBX_TEXTURE_FILE })
            else {
                addWarning("Texture \"\(name)\" is procedural and references no image file; it is not exported.")
                return nil
            }
            addWarning("Texture \"\(name)\" is procedural or layered; its first image file is used instead.")
            resolved = file
        }
        if resolved.pointee.has_uv_transform {
            addWarning("Texture \"\(name)\" uses a UV transform, which is not converted.")
        }
        return resolved
    }

    /// Combines the separate FBX metalness/roughness textures into the packed
    /// texture glTF requires. Returns nil when neither map has a usable texture.
    private mutating func extractMetallicRoughnessTexture(
        metalTexture: UnsafeMutablePointer<ufbx_texture>?,
        roughTexture: UnsafeMutablePointer<ufbx_texture>?,
        invertRoughness: Bool
    ) -> Int? {
        guard metalTexture != nil || roughTexture != nil else { return nil }

        let key = PackedTextureKey(
            metallic: metalTexture.map(TextureKey.init),
            roughness: roughTexture.map(TextureKey.init),
            invertRoughness: invertRoughness
        )
        if let cached = packedTextureIndices[key] {
            return cached
        }
        let index = packMetallicRoughness(
            metalTexture: metalTexture, roughTexture: roughTexture, invertRoughness: invertRoughness
        )
        packedTextureIndices[key] = index
        return index
    }

    private mutating func packMetallicRoughness(
        metalTexture: UnsafeMutablePointer<ufbx_texture>?,
        roughTexture: UnsafeMutablePointer<ufbx_texture>?,
        invertRoughness: Bool
    ) -> Int? {
        func rawData(_ texture: UnsafeMutablePointer<ufbx_texture>?) -> Data? {
            guard let texture else { return nil }
            guard let data = textureData(texture) else {
                let name = String(ufbx: texture.pointee.name) ?? "?"
                addWarning("Texture file for \"\(name)\" was not found; the material factor is kept.")
                return nil
            }
            return data
        }
        let metallic = rawData(metalTexture)
        let roughness = rawData(roughTexture)
        guard metallic != nil || roughness != nil else { return nil }
        guard let packed = TextureEncoder.packMetallicRoughness(
            metallic: metallic, roughness: roughness, invertRoughness: invertRoughness
        ) else {
            addWarning("Metallic/roughness textures use an unsupported image format; the material factors are kept.")
            return nil
        }

        // Wrapping comes from whichever source texture exists
        return appendTexture(name: "metallicRoughness", encoded: packed, wrap: (roughTexture ?? metalTexture)?.wrap)
    }

    /// Adds an encoded image to the IR and returns its index.
    private mutating func appendTexture(
        name: String?, encoded: TextureEncoder.EncodedTexture, wrap: SceneData.Texture.Wrap?
    ) -> Int {
        data.textures.append(SceneData.Texture(
            name: name,
            mimeType: encoded.mimeType,
            data: encoded.data,
            wrap: wrap ?? .repeating
        ))
        return data.textures.count - 1
    }

    private mutating func extractTexture(from map: ufbx_material_map) -> Int? {
        guard let texture = resolveFileTexture(of: map) else { return nil }
        let key = TextureKey(texture: texture)
        if let cached = textureIndices[key] {
            return cached
        }
        let index = loadTexture(texture)
        textureIndices[key] = index
        return index
    }

    private mutating func loadTexture(_ texture: UnsafeMutablePointer<ufbx_texture>) -> Int? {
        let name = String(ufbx: texture.pointee.name)
        guard let rawData = textureData(texture) else {
            addWarning("Texture file for \"\(name ?? "?")\" was not found; the material color is kept.")
            return nil
        }
        guard let encoded = TextureEncoder.normalize(rawData) else {
            addWarning("Texture \"\(name ?? "?")\" uses an unsupported image format; it is not exported.")
            return nil
        }

        return appendTexture(name: name, encoded: encoded, wrap: texture.wrap)
    }

    private func textureData(_ texture: UnsafeMutablePointer<ufbx_texture>) -> Data? {
        let content = texture.pointee.content
        if content.size > 0, let bytes = content.data {
            return Data(bytes: bytes, count: content.size)
        }

        var candidates: [URL] = []
        if let absolute = String(ufbx: texture.pointee.absolute_filename) {
            candidates.append(URL(fileURLWithPath: absolute))
        }
        if let relative = String(ufbx: texture.pointee.filename) {
            candidates.append(baseURL.appendingPathComponent(relative))
            // Textures often move next to the FBX after being exported on another machine
            let fileName = URL(fileURLWithPath: relative).lastPathComponent
            candidates.append(baseURL.appendingPathComponent(fileName))
        }
        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate) {
                return data
            }
        }
        return nil
    }

    // MARK: - Skins

    /// Runs after the node traversal, when every bone node has an index.
    mutating func resolveSkins() {
        for pending in pendingSkins {
            var joints: [Int] = []
            var inverseBindMatrices: [Float] = []
            for cluster in list(pending.deformer.pointee.clusters) {
                guard let cluster,
                      let bone = cluster.pointee.bone_node,
                      let nodeIndex = nodeIndexByTypedId[bone.pointee.typed_id]
                else {
                    joints = []
                    break
                }
                joints.append(nodeIndex)
                inverseBindMatrices += mat4(cluster.pointee.geometry_to_bone)
            }
            guard !joints.isEmpty else {
                let name = data.meshes[pending.meshIndex].name ?? "?"
                addWarning("Mesh \"\(name)\" is bound to bones outside the scene; it is exported as a static mesh.")
                for index in data.meshes[pending.meshIndex].primitives.indices {
                    data.meshes[pending.meshIndex].primitives[index].joints = []
                    data.meshes[pending.meshIndex].primitives[index].weights = []
                }
                continue
            }
            data.skins.append(SceneData.Skin(jointNodeIndices: joints, inverseBindMatrices: inverseBindMatrices))
            data.meshes[pending.meshIndex].skinIndex = data.skins.count - 1
        }
    }

    // MARK: - Animations

    /// Bakes every animation stack into per-node TRS keyframes. Baking resolves
    /// the FBX-specific transform stack (Euler orders, pivots, pre/post rotation)
    /// into values glTF can interpolate linearly.
    mutating func extractAnimations(_ scene: UnsafeMutablePointer<ufbx_scene>) {
        var bakeOptions = ufbx_bake_opts()
        // Emit keys starting at zero, which ufbx trims exactly in FBX ticks
        bakeOptions.trim_start_time = true

        for stack in list(scene.pointee.anim_stacks) {
            guard let stack else { continue }
            var error = ufbx_error()
            guard let baked = ufbx_bake_anim(scene, stack.pointee.anim, &bakeOptions, &error) else {
                let name = String(ufbx: stack.pointee.name) ?? "?"
                addWarning("Animation \"\(name)\" could not be baked; it is not exported.")
                continue
            }
            defer { ufbx_free_baked_anim(baked) }

            var channels: [SceneData.Animation.Channel] = []
            for bakedNode in list(baked.pointee.nodes) {
                guard let nodeIndex = nodeIndexByTypedId[bakedNode.typed_id] else { continue }
                if let channel = vec3Channel(bakedNode.translation_keys, node: nodeIndex, path: .translation) {
                    channels.append(channel)
                }
                if let channel = rotationChannel(bakedNode.rotation_keys, node: nodeIndex) {
                    channels.append(channel)
                }
                if let channel = vec3Channel(bakedNode.scale_keys, node: nodeIndex, path: .scale) {
                    channels.append(channel)
                }
            }

            let weightTracks = weightTracks(baked: baked)

            if !channels.isEmpty || !weightTracks.isEmpty {
                var animation = SceneData.Animation(name: String(ufbx: stack.pointee.name), channels: channels)
                animation.weightTracks = weightTracks
                data.animations.append(animation)
            }
        }
    }

    /// Merges the baked weight curves of a mesh's blend channels into one track,
    /// because glTF stores the weights of all morph targets interleaved per key.
    private func weightTracks(baked: UnsafeMutablePointer<ufbx_baked_anim>) -> [SceneData.Animation.WeightTrack] {
        var curvesByMesh: [Int: [Int: ufbx_baked_vec3_list]] = [:]
        for bakedElement in list(baked.pointee.elements) {
            guard let slot = morphSlotsByElementId[bakedElement.element_id] else { continue }
            for prop in list(bakedElement.props) where String(ufbx: prop.name) == "DeformPercent" {
                guard prop.keys.count > 0 else { continue }
                curvesByMesh[slot.meshIndex, default: [:]][slot.slot] = prop.keys
            }
        }

        return curvesByMesh.sorted { $0.key < $1.key }.map { meshIndex, curves in
            let channels = data.meshes[meshIndex].morphChannels
            var keyTimes = Set<Double>()
            for keys in curves.values {
                for key in list(keys) {
                    keyTimes.insert(key.time)
                }
            }
            let times = keyTimes.sorted()
            var values: [Float] = []
            values.reserveCapacity(times.count * channels.count)
            for time in times {
                for slot in channels.indices {
                    guard let keys = curves[slot] else {
                        values.append(channels[slot].defaultWeight)
                        continue
                    }
                    // FBX stores blend weights in percent
                    values.append(Float(ufbx_evaluate_baked_vec3(keys, time).x) * 0.01)
                }
            }
            return SceneData.Animation.WeightTrack(
                meshIndex: meshIndex,
                times: times.map(Self.keyTime),
                values: values
            )
        }
    }

    /// Trimming can land the first key on negative zero, which serializes as an
    /// ugly `-0` without meaning anything different.
    private static func keyTime(_ time: Double) -> Float {
        Float(time) + 0
    }

    private func vec3Channel(
        _ keys: ufbx_baked_vec3_list, node: Int, path: SceneData.Animation.Path
    ) -> SceneData.Animation.Channel? {
        let keys = list(keys)
        guard !keys.isEmpty else { return nil }
        var channel = SceneData.Animation.Channel(nodeIndex: node, path: path, times: [], values: [])
        channel.times.reserveCapacity(keys.count)
        channel.values.reserveCapacity(keys.count * 3)
        for key in keys {
            channel.times.append(Self.keyTime(key.time))
            channel.values.append(Float(key.value.x))
            channel.values.append(Float(key.value.y))
            channel.values.append(Float(key.value.z))
        }
        return channel
    }

    private func rotationChannel(_ keys: ufbx_baked_quat_list, node: Int) -> SceneData.Animation.Channel? {
        let keys = list(keys)
        guard !keys.isEmpty else { return nil }
        var channel = SceneData.Animation.Channel(nodeIndex: node, path: .rotation, times: [], values: [])
        channel.times.reserveCapacity(keys.count)
        channel.values.reserveCapacity(keys.count * 4)
        // Keep neighboring quaternions in the same hemisphere so that the
        // linear interpolation glTF mandates takes the short way around
        var previous = keys[0].value
        for (index, key) in keys.enumerated() {
            let value = index > 0 ? ufbx_quat_fix_antipodal(key.value, previous) : key.value
            previous = value
            channel.times.append(Self.keyTime(key.time))
            channel.values.append(Float(value.x))
            channel.values.append(Float(value.y))
            channel.values.append(Float(value.z))
            channel.values.append(Float(value.w))
        }
        return channel
    }

    private mutating func addWarning(_ warning: String) {
        if seenWarnings.insert(warning).inserted {
            data.warnings.append(warning)
        }
    }
}

/// One blend-shape channel. The offsets stay in ufbx's sparse storage, which
/// indexes them per control point on demand.
private struct MorphSource {
    var name: String?
    var defaultWeight: Float
    var channelElementId: UInt32
    var shape: UnsafeMutablePointer<ufbx_blend_shape>

    /// Densifies the sparse offsets over a primitive's welded vertices.
    func target(for controlPoints: [UInt32]) -> SceneData.MorphTarget {
        let positionOffsets = list(shape.pointee.position_offsets)
        let normalOffsets = list(shape.pointee.normal_offsets)
        var target = SceneData.MorphTarget(
            positionDeltas: [Float](repeating: 0, count: controlPoints.count * 3),
            normalDeltas: normalOffsets.isEmpty ? [] : [Float](repeating: 0, count: controlPoints.count * 3)
        )
        for (vertex, controlPoint) in controlPoints.enumerated() {
            let offset = ufbx_get_blend_shape_offset_index(shape, Int(controlPoint))
            guard offset != UFBX_NO_INDEX else { continue }
            let position = positionOffsets[Int(offset)]
            target.positionDeltas[vertex * 3] = Float(position.x)
            target.positionDeltas[vertex * 3 + 1] = Float(position.y)
            target.positionDeltas[vertex * 3 + 2] = Float(position.z)
            if !normalOffsets.isEmpty {
                let normal = normalOffsets[Int(offset)]
                target.normalDeltas[vertex * 3] = Float(normal.x)
                target.normalDeltas[vertex * 3 + 1] = Float(normal.y)
                target.normalDeltas[vertex * 3 + 2] = Float(normal.z)
            }
        }
        return target
    }
}

// MARK: - Dictionary keys

private struct MeshInstanceKey: Hashable {
    var mesh: UnsafeRawPointer
    var materials: [UnsafeMutablePointer<ufbx_material>?]
}

private struct PackedTextureKey: Hashable {
    var metallic: TextureKey?
    var roughness: TextureKey?
    var invertRoughness: Bool
}

private struct TextureKey: Hashable {
    enum Identity: Hashable {
        case path(String)
        case object(UnsafeRawPointer)
    }

    var identity: Identity
    var wrap: SceneData.Texture.Wrap

    init(texture: UnsafeMutablePointer<ufbx_texture>) {
        // Deduplicate by file path when available so that two texture objects
        // referencing the same file share a single image.
        if let path = String(ufbx: texture.pointee.absolute_filename), !path.isEmpty {
            identity = .path(path)
        } else {
            identity = .object(UnsafeRawPointer(texture))
        }
        wrap = texture.wrap
    }
}

private extension Float {
    var clamped01: Float {
        min(max(self, 0), 1)
    }
}

private extension SIMD where Scalar == Float {
    var clamped01: Self {
        clamped(lowerBound: Self(repeating: 0), upperBound: Self(repeating: 1))
    }
}
