import CUfbx

// Thin adapters over the ufbx C types, keeping pointer handling out of the extraction logic.

func list(_ list: ufbx_node_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_node>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_material_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_material>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_mesh_part_list) -> UnsafeBufferPointer<ufbx_mesh_part> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_face_list) -> UnsafeBufferPointer<ufbx_face> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_uint32_list) -> UnsafeBufferPointer<UInt32> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_anim_stack_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_anim_stack>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_texture_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_texture>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_skin_deformer_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_skin_deformer>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_skin_cluster_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_skin_cluster>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_skin_vertex_list) -> UnsafeBufferPointer<ufbx_skin_vertex> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_skin_weight_list) -> UnsafeBufferPointer<ufbx_skin_weight> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_blend_deformer_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_blend_deformer>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_blend_channel_list) -> UnsafeBufferPointer<UnsafeMutablePointer<ufbx_blend_channel>?> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_vec3_list) -> UnsafeBufferPointer<ufbx_vec3> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_vec4_list) -> UnsafeBufferPointer<ufbx_vec4> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_baked_node_list) -> UnsafeBufferPointer<ufbx_baked_node> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_baked_vec3_list) -> UnsafeBufferPointer<ufbx_baked_vec3> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_baked_quat_list) -> UnsafeBufferPointer<ufbx_baked_quat> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_warning_list) -> UnsafeBufferPointer<ufbx_warning> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_baked_element_list) -> UnsafeBufferPointer<ufbx_baked_element> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

func list(_ list: ufbx_baked_prop_list) -> UnsafeBufferPointer<ufbx_baked_prop> {
    UnsafeBufferPointer(start: list.data, count: list.count)
}

/// The 16 column-major floats glTF expects, from ufbx's 3x4 matrix.
func mat4(_ m: ufbx_matrix) -> [Float] {
    [
        Float(m.m00), Float(m.m10), Float(m.m20), 0,
        Float(m.m01), Float(m.m11), Float(m.m21), 0,
        Float(m.m02), Float(m.m12), Float(m.m22), 0,
        Float(m.m03), Float(m.m13), Float(m.m23), 1,
    ]
}

extension ufbx_vertex_vec3 {
    func vec3(at index: Int) -> (Float, Float, Float) {
        let value = values.data[ufbxAttributeIndex(indices.data[index])]
        return (Float(value.x), Float(value.y), Float(value.z))
    }
}

extension ufbx_vertex_vec2 {
    func vec2(at index: Int) -> (Float, Float) {
        let value = values.data[ufbxAttributeIndex(indices.data[index])]
        return (Float(value.x), Float(value.y))
    }
}

extension ufbx_vertex_vec4 {
    /// Index into `values`, for callers that precompute a converted value table.
    func valueIndex(at index: Int) -> Int {
        ufbxAttributeIndex(indices.data[index])
    }
}

/// Matches the `(int32_t)` cast the ufbx inline accessors use, which maps the
/// `UFBX_NO_INDEX` sentinel onto the zero value ufbx reserves for it.
private func ufbxAttributeIndex(_ index: UInt32) -> Int {
    Int(Int32(bitPattern: index))
}

extension String {
    init?(ufbx string: ufbx_string) {
        guard string.length > 0, let data = string.data else { return nil }
        self = String(decoding: UnsafeRawBufferPointer(start: data, count: string.length), as: UTF8.self)
    }
}

extension SIMD3<Float> {
    init(_ value: ufbx_vec3) {
        self.init(Float(value.x), Float(value.y), Float(value.z))
    }

    /// Drops the unused W component of a ufbx color.
    init(_ value: ufbx_vec4) {
        self.init(Float(value.x), Float(value.y), Float(value.z))
    }
}

extension SIMD4<Float> {
    init(_ value: ufbx_quat) {
        self.init(Float(value.x), Float(value.y), Float(value.z), Float(value.w))
    }
}
