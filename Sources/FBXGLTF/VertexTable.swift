/// Compares the raw bit patterns so that vertices are welded only when every
/// attribute matches exactly. Fixed-size to avoid an allocation per triangle corner.
struct VertexKey: Equatable {
    var position: SIMD3<UInt32>
    var normal: SIMD3<UInt32>
    var uv: SIMD2<UInt32>
    var color: SIMD4<UInt32>
    /// Source control-point index, set on skinned or morphed meshes where equal
    /// attributes can still carry different weights. Zero when welding may ignore it.
    var vertex: UInt32

    init(
        position: (Float, Float, Float),
        normal: (Float, Float, Float),
        uv: (Float, Float)?,
        color: (Float, Float, Float, Float)? = nil,
        vertex: UInt32 = 0
    ) {
        self.position = SIMD3(position.0.bitPattern, position.1.bitPattern, position.2.bitPattern)
        self.normal = SIMD3(normal.0.bitPattern, normal.1.bitPattern, normal.2.bitPattern)
        // Optional attributes are uniform across a primitive, so a zero
        // placeholder cannot collide
        self.uv = uv.map { SIMD2($0.0.bitPattern, $0.1.bitPattern) } ?? .zero
        self.color = color.map { SIMD4($0.0.bitPattern, $0.1.bitPattern, $0.2.bitPattern, $0.3.bitPattern) } ?? .zero
        self.vertex = vertex
    }
}

/// Welds triangle corners into unique vertices, numbering them in encounter order.
///
/// This runs once per triangle corner, where `Dictionary` spends most of the time
/// in `Hasher`, and where `ufbx_generate_indices` pays for writing every corner
/// before compacting. Open addressing over a plain FNV-1a hash of the attribute
/// bits measured faster than both.
struct VertexTable {
    /// Each key's vertex index biased by one, so that zero marks an empty slot.
    private var slots: [UInt32]
    private var keys: [VertexKey] = []

    /// Keeps the load factor at or below 3/4, where linear probing stays short.
    private static func slotCount(for capacity: Int) -> Int {
        var slots = 64
        while slots * 3 < capacity * 4 { slots <<= 1 }
        return slots
    }

    init(minimumCapacity: Int) {
        slots = [UInt32](repeating: 0, count: Self.slotCount(for: minimumCapacity))
        keys.reserveCapacity(minimumCapacity)
    }

    var count: Int { keys.count }

    /// The index of `key`, inserting it if it has not been seen yet.
    mutating func index(for key: VertexKey) -> (index: UInt32, isNew: Bool) {
        let mask = slots.count - 1
        var probe = Self.hash(of: key) & mask
        while true {
            let slot = slots[probe]
            guard slot != 0 else { break }
            if keys[Int(slot - 1)] == key {
                return (slot - 1, false)
            }
            probe = (probe + 1) & mask
        }
        if keys.count * 4 >= slots.count * 3 {
            grow()
            return index(for: key)
        }
        keys.append(key)
        slots[probe] = UInt32(keys.count)
        return (UInt32(keys.count - 1), true)
    }

    private static func hash(of key: VertexKey) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for lane in 0..<3 { hash = hash.mixed(with: key.position[lane]) }
        for lane in 0..<3 { hash = hash.mixed(with: key.normal[lane]) }
        for lane in 0..<2 { hash = hash.mixed(with: key.uv[lane]) }
        for lane in 0..<4 { hash = hash.mixed(with: key.color[lane]) }
        hash = hash.mixed(with: key.vertex)
        return Int(truncatingIfNeeded: hash ^ (hash >> 32))
    }

    private mutating func grow() {
        slots = [UInt32](repeating: 0, count: slots.count << 1)
        let mask = slots.count - 1
        for (offset, key) in keys.enumerated() {
            var probe = Self.hash(of: key) & mask
            while slots[probe] != 0 {
                probe = (probe + 1) & mask
            }
            slots[probe] = UInt32(offset) + 1
        }
    }
}

private extension UInt64 {
    func mixed(with word: UInt32) -> UInt64 {
        (self ^ UInt64(word)) &* 0x100_0000_01b3
    }
}
