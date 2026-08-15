import Testing
@testable import FBXGLTF

struct VertexTableTests {
    /// Draws `count` corners from `distinct` deterministic pseudo-random vertices,
    /// returning each corner's key alongside the vertex it was drawn from.
    private func makeCorners(count: Int, distinct: Int) -> [(key: VertexKey, identity: Int)] {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / 1024
        }
        let pool = (0..<distinct).map { _ in
            VertexKey(position: (next(), next(), next()), normal: (next(), next(), next()), uv: (next(), next()))
        }
        return (0..<count).map { _ in
            let identity = Int(next()) % distinct
            return (pool[identity], identity)
        }
    }

    /// Equal corners must collapse to one index and distinct ones must not, with
    /// indices handed out in encounter order — including across the rehash that
    /// growing past the load factor triggers.
    @Test(arguments: [64, 4096])
    func numbersVerticesInEncounterOrder(minimumCapacity: Int) {
        let corners = makeCorners(count: 5_000, distinct: 700)
        var table = VertexTable(minimumCapacity: minimumCapacity)
        var expectedIndices: [Int: UInt32] = [:]

        for (key, identity) in corners {
            let (index, isNew) = table.index(for: key)
            if let existing = expectedIndices[identity] {
                #expect(index == existing)
                #expect(!isNew)
            } else {
                #expect(index == UInt32(expectedIndices.count))
                #expect(isNew)
                expectedIndices[identity] = index
            }
        }
        #expect(table.count == 700)
    }

    @Test func distinguishesVerticesThatDifferInASingleAttribute() {
        var table = VertexTable(minimumCapacity: 8)
        let base = table.index(for: VertexKey(position: (1, 2, 3), normal: (0, 1, 0), uv: (0.5, 0.5)))
        #expect(base.isNew)

        #expect(table.index(for: VertexKey(position: (1, 2, 3), normal: (0, 1, 0), uv: (0.5, 0.5))).index == base.index)
        #expect(table.index(for: VertexKey(position: (1, 2, 4), normal: (0, 1, 0), uv: (0.5, 0.5))).isNew)
        #expect(table.index(for: VertexKey(position: (1, 2, 3), normal: (0, -1, 0), uv: (0.5, 0.5))).isNew)
        #expect(table.index(for: VertexKey(position: (1, 2, 3), normal: (0, 1, 0), uv: (0.5, 0.25))).isNew)
        // A primitive without UVs uses the zero placeholder, which must not merge
        // with a vertex whose UV really is zero only when the rest also matches
        #expect(table.index(for: VertexKey(position: (1, 2, 3), normal: (0, 1, 0), uv: nil)).isNew)
        #expect(table.count == 5)
    }
}
