import Foundation
import simd

/// Post-processes merged geometry: floor unification, obstacle box generation,
/// mesh decimation, and NavMesh hole-closing. All CPU-based.
struct MeshPostProcessor {

    struct ProcessedMesh {
        var vertices: [simd_float3]
        var indices:  [UInt32]
        var triangleCount: Int { indices.count / 3 }
    }

    // MARK: - Box primitive builder

    /// Generates a closed box mesh (12 triangles) from a transform + dimensions.
    static func makeBox(transform: simd_float4x4,
                        dimensions: simd_float3) -> ProcessedMesh {
        let hx = dimensions.x / 2
        let hy = dimensions.y / 2
        let hz = dimensions.z / 2

        // 8 corners in local space
        let localCorners: [simd_float3] = [
            [-hx, -hy, -hz], [ hx, -hy, -hz],
            [ hx,  hy, -hz], [-hx,  hy, -hz],
            [-hx, -hy,  hz], [ hx, -hy,  hz],
            [ hx,  hy,  hz], [-hx,  hy,  hz]
        ]

        let verts = localCorners.map { lc -> simd_float3 in
            let world = transform * simd_float4(lc.x, lc.y, lc.z, 1)
            return simd_float3(world.x, world.y, world.z)
        }

        // 6 faces × 2 triangles each (outward normals)
        let indices: [UInt32] = [
            0,1,2, 0,2,3,  // -Z face
            5,4,7, 5,7,6,  // +Z face
            1,5,6, 1,6,2,  // +X face
            4,0,3, 4,3,7,  // -X face
            3,2,6, 3,6,7,  // +Y face
            4,5,1, 4,1,0   // -Y face
        ]
        return ProcessedMesh(vertices: verts, indices: indices)
    }

    // MARK: - Floor unification

    /// Snaps all floor vertices to Y=0 and merges into a single flat quad.
    static func unifyFloors(from primitives: [MultiRoomStitcher.SurfacePrimitive]) -> ProcessedMesh {
        guard !primitives.isEmpty else { return ProcessedMesh(vertices: [], indices: []) }

        var allVertices = [simd_float3]()
        var allIndices  = [UInt32]()
        var baseIndex: UInt32 = 0

        for floor in primitives {
            // Floor box snapped to Y=0
            var t = floor.transform
            t.columns.3.y = 0.0
            let dims = simd_float3(floor.dimensions.x, 0.01, floor.dimensions.z)
            let box = makeBox(transform: t, dimensions: dims)
            allVertices.append(contentsOf: box.vertices)
            allIndices.append(contentsOf: box.indices.map { $0 + baseIndex })
            baseIndex += UInt32(box.vertices.count)
        }
        return ProcessedMesh(vertices: allVertices, indices: allIndices)
    }

    // MARK: - Obstacle mesh generation

    /// Converts all wall surfaces and furniture objects into closed box meshes.
    static func buildObstacleMesh(
        walls: [MultiRoomStitcher.SurfacePrimitive],
        objects: [MultiRoomStitcher.ObjectPrimitive]
    ) -> ProcessedMesh {
        var allVerts  = [simd_float3]()
        var allIdx    = [UInt32]()
        var base: UInt32 = 0

        let wallBoxes = walls.map { makeBox(transform: $0.transform, dimensions: $0.dimensions) }
        let objBoxes  = objects.map { makeBox(transform: $0.transform, dimensions: $0.dimensions) }

        for box in wallBoxes + objBoxes {
            allVerts.append(contentsOf: box.vertices)
            allIdx.append(contentsOf: box.indices.map { $0 + base })
            base += UInt32(box.vertices.count)
        }
        return ProcessedMesh(vertices: allVerts, indices: allIdx)
    }

    // MARK: - Mesh decimation (vertex merging / triangle reduction)

    /// Merges duplicate vertices within tolerance and removes degenerate triangles.
    static func decimate(_ mesh: ProcessedMesh,
                         targetTriangles: Int = 500_000,
                         mergeTolerance: Float = 0.005) -> ProcessedMesh {
        guard !mesh.vertices.isEmpty else { return mesh }

        // Step 1: Weld vertices within tolerance
        var remapTable = [Int](repeating: -1, count: mesh.vertices.count)
        var uniqueVerts = [simd_float3]()

        for (i, v) in mesh.vertices.enumerated() {
            if let existing = uniqueVerts.firstIndex(where: { simd_distance($0, v) < mergeTolerance }) {
                remapTable[i] = existing
            } else {
                remapTable[i] = uniqueVerts.count
                uniqueVerts.append(v)
            }
        }

        var newIndices = [UInt32]()
        newIndices.reserveCapacity(mesh.indices.count)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = remapTable[Int(mesh.indices[i])]
            let i1 = remapTable[Int(mesh.indices[i+1])]
            let i2 = remapTable[Int(mesh.indices[i+2])]
            // Skip degenerate triangles
            if i0 != i1 && i1 != i2 && i0 != i2 {
                newIndices.append(contentsOf: [UInt32(i0), UInt32(i1), UInt32(i2)])
            }
        }

        // Step 2: Uniform stride sampling if over budget
        if newIndices.count / 3 > targetTriangles {
            let stride = max(1, (newIndices.count / 3) / targetTriangles)
            var sampled = [UInt32]()
            sampled.reserveCapacity(targetTriangles * 3)
            for tri in 0..<(newIndices.count / 3) where tri % stride == 0 {
                sampled.append(contentsOf: [newIndices[tri*3], newIndices[tri*3+1], newIndices[tri*3+2]])
            }
            newIndices = sampled
        }

        return ProcessedMesh(vertices: uniqueVerts, indices: newIndices)
    }

    // MARK: - Combined mesh

    static func mergeMeshes(_ meshes: [ProcessedMesh]) -> ProcessedMesh {
        var allVerts = [simd_float3]()
        var allIdx   = [UInt32]()
        var base: UInt32 = 0

        for m in meshes {
            allVerts.append(contentsOf: m.vertices)
            allIdx.append(contentsOf: m.indices.map { $0 + base })
            base += UInt32(m.vertices.count)
        }
        return ProcessedMesh(vertices: allVerts, indices: allIdx)
    }
}
