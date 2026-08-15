import Foundation

/// Builds a GLB payload (glTF JSON + binary buffer) from a `SceneData`.
enum GLTFBuilder {
    static func buildGLB(from scene: SceneData) throws(FBXGLTFError) -> Data {
        var buffer = BufferBuilder()
        let images = appendImages(of: scene, to: &buffer)
        let meshes = appendMeshes(of: scene, to: &buffer)
        let skins = appendSkins(of: scene, to: &buffer)
        let animations = appendAnimations(of: scene, to: &buffer)

        let document = GLTFDocument(
            scenes: [.init(nodes: scene.rootIndices)],
            nodes: scene.nodes.map { node in
                var result = Self.node(from: node)
                result.skin = node.meshIndex.flatMap { scene.meshes[$0].skinIndex }
                return result
            },
            meshes: meshes.nilIfEmpty,
            materials: scene.materials.map(Self.material(from:)).nilIfEmpty,
            textures: images.textures.nilIfEmpty,
            samplers: images.samplers.nilIfEmpty,
            images: images.images.nilIfEmpty,
            skins: skins.nilIfEmpty,
            animations: animations.nilIfEmpty,
            accessors: buffer.accessors.nilIfEmpty,
            bufferViews: buffer.bufferViews.nilIfEmpty,
            buffers: buffer.data.isEmpty ? nil : [.init(byteLength: buffer.data.count)]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json: Data
        do {
            json = try encoder.encode(document)
        } catch {
            // Most often a non-finite coordinate, which JSON cannot represent
            throw FBXGLTFError.encodingFailed(error)
        }
        return GLBContainer.encode(json: json, binary: buffer.data)
    }

    /// Images with the samplers their wrap modes need; glTF keeps the two
    /// separate so one image can serve several wrap combinations.
    private static func appendImages(
        of scene: SceneData, to buffer: inout BufferBuilder
    ) -> (images: [GLTFDocument.Image], textures: [GLTFDocument.Texture], samplers: [GLTFDocument.Sampler]) {
        var images: [GLTFDocument.Image] = []
        var textures: [GLTFDocument.Texture] = []
        var samplers: [GLTFDocument.Sampler] = []
        var samplerByWrap: [SceneData.Texture.Wrap: Int] = [:]

        for texture in scene.textures {
            images.append(buffer.appendImage(name: texture.name, mimeType: texture.mimeType, data: texture.data))
            // The default sampler already repeats, so only clamping needs one
            guard texture.wrap != .repeating else {
                textures.append(.init(source: images.count - 1))
                continue
            }
            let sampler = samplerByWrap[texture.wrap] ?? {
                samplers.append(.init(
                    wrapS: texture.wrap.clampsU ? .clampToEdge : nil,
                    wrapT: texture.wrap.clampsV ? .clampToEdge : nil
                ))
                samplerByWrap[texture.wrap] = samplers.count - 1
                return samplers.count - 1
            }()
            textures.append(.init(sampler: sampler, source: images.count - 1))
        }
        return (images, textures, samplers)
    }

    private static func appendMeshes(of scene: SceneData, to buffer: inout BufferBuilder) -> [GLTFDocument.Mesh] {
        scene.meshes.map { mesh in
            var result = GLTFDocument.Mesh(
                name: mesh.name,
                primitives: mesh.primitives.map { appendPrimitive($0, to: &buffer) }
            )
            guard !mesh.morphChannels.isEmpty else { return result }
            let weights = mesh.morphChannels.map(\.defaultWeight)
            result.weights = weights.contains { $0 != 0 } ? weights : nil
            result.extras = .init(targetNames: mesh.morphChannels.enumerated().map { $1.name ?? "target\($0)" })
            return result
        }
    }

    private static func appendPrimitive(
        _ primitive: SceneData.Primitive, to buffer: inout BufferBuilder
    ) -> GLTFDocument.Mesh.Primitive {
        var attributes: [String: Int] = [:]
        attributes["POSITION"] = buffer.addAccessor(
            primitive.positions, componentType: .float, type: .vec3, target: .arrayBuffer,
            bounds: tripletBounds(of: primitive.positions)
        )
        attributes["NORMAL"] = buffer.addAccessor(
            primitive.normals, componentType: .float, type: .vec3, target: .arrayBuffer
        )
        if !primitive.uvs.isEmpty {
            attributes["TEXCOORD_0"] = buffer.addAccessor(
                primitive.uvs, componentType: .float, type: .vec2, target: .arrayBuffer
            )
        }
        if !primitive.colors.isEmpty {
            attributes["COLOR_0"] = buffer.addAccessor(
                primitive.colors, componentType: .float, type: .vec4, target: .arrayBuffer
            )
        }
        if !primitive.joints.isEmpty {
            attributes["JOINTS_0"] = buffer.addAccessor(
                primitive.joints, componentType: .unsignedShort, type: .vec4, target: .arrayBuffer
            )
            attributes["WEIGHTS_0"] = buffer.addAccessor(
                primitive.weights, componentType: .float, type: .vec4, target: .arrayBuffer
            )
        }
        let indices = buffer.addAccessor(
            primitive.indices, componentType: .unsignedInt, type: .scalar, target: .elementArrayBuffer
        )
        let targets = primitive.morphTargets.map { target -> [String: Int] in
            // The spec requires bounds on morph POSITION deltas as well
            var accessorsByAttribute = [
                "POSITION": buffer.addAccessor(
                    target.positionDeltas, componentType: .float, type: .vec3, target: .arrayBuffer,
                    bounds: tripletBounds(of: target.positionDeltas)
                ),
            ]
            if !target.normalDeltas.isEmpty {
                accessorsByAttribute["NORMAL"] = buffer.addAccessor(
                    target.normalDeltas, componentType: .float, type: .vec3, target: .arrayBuffer
                )
            }
            return accessorsByAttribute
        }
        return .init(
            attributes: attributes,
            indices: indices,
            material: primitive.materialIndex,
            targets: targets.nilIfEmpty
        )
    }

    private static func appendSkins(of scene: SceneData, to buffer: inout BufferBuilder) -> [GLTFDocument.Skin] {
        scene.skins.map { skin in
            GLTFDocument.Skin(
                inverseBindMatrices: buffer.addAccessor(
                    skin.inverseBindMatrices, componentType: .float, type: .mat4
                ),
                joints: skin.jointNodeIndices
            )
        }
    }

    private static func appendAnimations(of scene: SceneData, to buffer: inout BufferBuilder) -> [GLTFDocument.Animation] {
        let nodesByMesh = Dictionary(grouping: scene.nodes.indices.compactMap { index in
            scene.nodes[index].meshIndex.map { (mesh: $0, node: index) }
        }, by: \.mesh).mapValues { $0.map(\.node) }

        return scene.animations.map { animation in
            var samplers: [GLTFDocument.Animation.Sampler] = []
            var channels: [GLTFDocument.Animation.Channel] = []

            /// The spec requires bounds on every animation input accessor.
            func addSampler(times: [Float], values: [Float], type: GLTFDocument.AccessorType) -> Int {
                let input = buffer.addAccessor(
                    times, componentType: .float, type: .scalar,
                    bounds: (min: [times.first ?? 0], max: [times.last ?? 0])
                )
                let output = buffer.addAccessor(values, componentType: .float, type: type)
                samplers.append(.init(input: input, output: output))
                return samplers.count - 1
            }

            for channel in animation.channels {
                let sampler = addSampler(
                    times: channel.times,
                    values: channel.values,
                    type: channel.path == .rotation ? .vec4 : .vec3
                )
                channels.append(.init(
                    sampler: sampler,
                    target: .init(node: channel.nodeIndex, path: targetPath(of: channel.path))
                ))
            }
            for track in animation.weightTracks {
                let sampler = addSampler(times: track.times, values: track.values, type: .scalar)
                // Weights animate per node, so every node instancing the mesh
                // gets a channel over the same sampler
                for node in nodesByMesh[track.meshIndex] ?? [] {
                    channels.append(.init(sampler: sampler, target: .init(node: node, path: .weights)))
                }
            }
            return GLTFDocument.Animation(name: animation.name, samplers: samplers, channels: channels)
        }
    }

    private static func targetPath(of path: SceneData.Animation.Path) -> GLTFDocument.Animation.TargetPath {
        switch path {
        case .translation: .translation
        case .rotation: .rotation
        case .scale: .scale
        }
    }

    private static func node(from node: SceneData.Node) -> GLTFDocument.Node {
        // Identity components are omitted to keep the output compact
        GLTFDocument.Node(
            name: node.name,
            children: node.childIndices.nilIfEmpty,
            translation: node.translation == .zero ? nil : node.translation,
            rotation: node.rotationXYZW == SceneData.Node.identityRotation ? nil : node.rotationXYZW,
            scale: node.scale == SceneData.Node.identityScale ? nil : node.scale,
            mesh: node.meshIndex
        )
    }

    private static func material(from material: SceneData.Material) -> GLTFDocument.Material {
        var result = GLTFDocument.Material(name: material.name)
        result.pbrMetallicRoughness = .init(
            baseColorFactor: material.baseColorFactor == SceneData.Material.defaultBaseColorFactor ? nil : material.baseColorFactor,
            baseColorTexture: material.baseColorTextureIndex.map { .init(index: $0) },
            metallicFactor: material.metallicFactor,
            roughnessFactor: material.roughnessFactor,
            metallicRoughnessTexture: material.metallicRoughnessTextureIndex.map { .init(index: $0) }
        )
        result.normalTexture = material.normalTextureIndex.map { .init(index: $0) }
        result.occlusionTexture = material.occlusionTextureIndex.map { .init(index: $0) }
        result.emissiveTexture = material.emissiveTextureIndex.map { .init(index: $0) }
        // glTF multiplies the emissive texture by the factor, which defaults to zero
        result.emissiveFactor = material.emissiveFactor ?? (material.emissiveTextureIndex != nil ? SIMD3(repeating: 1) : nil)
        result.alphaMode = material.alphaBlend ? .blend : nil
        result.doubleSided = material.doubleSided ? true : nil
        return result
    }

    /// The per-component minimum and maximum of xyz triplets, in a single pass.
    private static func tripletBounds(of values: [Float]) -> (min: [Float], max: [Float])? {
        guard values.count >= 3 else { return nil }
        var minimum = SIMD3(values[0], values[1], values[2])
        var maximum = minimum
        for base in stride(from: 3, to: values.count - 2, by: 3) {
            let value = SIMD3(values[base], values[base + 1], values[base + 2])
            minimum = pointwiseMin(minimum, value)
            maximum = pointwiseMax(maximum, value)
        }
        return ([minimum.x, minimum.y, minimum.z], [maximum.x, maximum.y, maximum.z])
    }
}

/// Accumulates the GLB binary chunk together with the buffer views and
/// accessors describing it, so the three always stay in step.
private struct BufferBuilder {
    private(set) var data = Data()
    private(set) var bufferViews: [GLTFDocument.BufferView] = []
    private(set) var accessors: [GLTFDocument.Accessor] = []

    /// Stores `values` and returns the index of the accessor describing them.
    mutating func addAccessor<T>(
        _ values: [T],
        componentType: GLTFDocument.ComponentType,
        type: GLTFDocument.AccessorType,
        target: GLTFDocument.BufferTarget? = nil,
        bounds: (min: [Float], max: [Float])? = nil
    ) -> Int {
        let view = appendBufferView(target: target) { data in
            values.withUnsafeBufferPointer { data.append($0) }
            // `Data.append` writes one stride per element, so the view must span the same
            return values.count * MemoryLayout<T>.stride
        }
        accessors.append(.init(
            bufferView: view,
            componentType: componentType,
            count: values.count / type.componentCount,
            type: type,
            min: bounds?.min,
            max: bounds?.max
        ))
        return accessors.count - 1
    }

    mutating func appendImage(name: String?, mimeType: String, data payload: Data) -> GLTFDocument.Image {
        let view = appendBufferView(target: nil) { data in
            data.append(payload)
            return payload.count
        }
        return .init(name: name, mimeType: mimeType, bufferView: view)
    }

    private mutating func appendBufferView(
        target: GLTFDocument.BufferTarget?, write: (inout Data) -> Int
    ) -> Int {
        let padding = data.count.alignedToFour - data.count
        if padding > 0 {
            data.append(contentsOf: repeatElement(0, count: padding))
        }
        let offset = data.count
        let length = write(&data)
        bufferViews.append(.init(byteOffset: offset, byteLength: length, target: target))
        return bufferViews.count - 1
    }
}

private extension Array {
    /// glTF forbids empty arrays, so they are omitted from the document instead.
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
