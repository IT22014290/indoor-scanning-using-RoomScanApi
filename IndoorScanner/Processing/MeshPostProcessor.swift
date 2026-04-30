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

    // MARK: - Chair mesh builder

    /// Generates a recognisable chair mesh composed of:
    ///   • 4 legs (thin vertical boxes from floor up to seat height)
    ///   • 1 seat slab (flat box at seat height)
    ///   • 1 backrest panel (tall box at the rear of the seat)
    /// All parts are expressed in the chair's local frame and then
    /// transformed into world space using the RoomPlan-supplied transform.
    /// `dimensions` = RoomPlan bounding-box of the whole chair (width × height × depth).
    static func makeChair(transform: simd_float4x4,
                          dimensions: simd_float3) -> ProcessedMesh {
        let w  = dimensions.x          // full width
        let h  = dimensions.y          // full height (floor → top of back)
        let d  = dimensions.z          // full depth (seat depth)

        // Proportional geometry derived from overall bounding box.
        let legR:      Float = min(w, d) * 0.08    // leg half-thickness
        let seatH:     Float = h * 0.42            // height of the seat surface
        let seatThick: Float = h * 0.08            // seat slab thickness
        let backH:     Float = h - seatH           // backrest height above seat
        let backThick: Float = d * 0.12            // backrest slab depth

        // Helper — build a box and accumulate into parts.
        var allVerts = [simd_float3]()
        var allIdx   = [UInt32]()
        var base: UInt32 = 0

        func addPart(cx: Float, cy: Float, cz: Float,
                     sx: Float, sy: Float, sz: Float) {
            // Local-space box, then apply chair transform.
            let localT = simd_float4x4(columns: (
                simd_float4(1, 0, 0, 0),
                simd_float4(0, 1, 0, 0),
                simd_float4(0, 0, 1, 0),
                simd_float4(cx, cy, cz, 1)
            ))
            let worldT = transform * localT
            let part = makeBox(transform: worldT,
                               dimensions: simd_float3(sx, sy, sz))
            allVerts.append(contentsOf: part.vertices)
            allIdx.append(contentsOf: part.indices.map { $0 + base })
            base += UInt32(part.vertices.count)
        }

        // --- 4 legs (placed at the four corners of the seat footprint) ---
        let lx = w * 0.5 - legR    // x offset of leg centre from chair centre
        let lz = d * 0.5 - legR    // z offset
        let legCY = seatH * 0.5 - h * 0.5   // centre in local Y (chair origin at bbox centre)
        for (sx, sz): (Float, Float) in [(-lx, -lz), (lx, -lz), (lx, lz), (-lx, lz)] {
            addPart(cx: sx, cy: legCY, cz: sz,
                    sx: legR * 2, sy: seatH, sz: legR * 2)
        }

        // --- Seat slab ---
        let seatCY = seatH - seatThick * 0.5 - h * 0.5
        addPart(cx: 0, cy: seatCY, cz: 0,
                sx: w, sy: seatThick, sz: d)

        // --- Backrest panel (at rear of seat, Z = -d/2 side) ---
        let backCY = seatH + backH * 0.5 - h * 0.5
        let backCZ = -(d * 0.5 - backThick * 0.5)
        addPart(cx: 0, cy: backCY, cz: backCZ,
                sx: w, sy: backH, sz: backThick)

        return ProcessedMesh(vertices: allVerts, indices: allIdx)
    }

    // MARK: - Floor unification

    /// Snaps all floor vertices to Y=0 and merges into a single flat quad.
    static func unifyFloors(from primitives: [MultiRoomStitcher.SurfacePrimitive]) -> ProcessedMesh {
        guard !primitives.isEmpty else { return ProcessedMesh(vertices: [], indices: []) }

        var allVertices = [simd_float3]()
        var allIndices  = [UInt32]()
        var baseIndex: UInt32 = 0

        for floor in primitives {
            // Floor is always horizontal at Y=0 — strip rotation, keep only XZ center.
            // Keeping the original rotation causes the slab to stand vertical when
            // RoomPlan's surface normal isn't aligned with the world Y axis.
            var flatTransform = matrix_identity_float4x4
            flatTransform.columns.3 = simd_float4(
                floor.transform.columns.3.x, 0.0, floor.transform.columns.3.z, 1.0)
            // Use the two largest axes so floors rotated off the X-Z plane don't collapse.
            let raw = [floor.dimensions.x, floor.dimensions.y, floor.dimensions.z].sorted(by: >)
            let dims = simd_float3(raw[0], 0.01, raw[1])
            let box = makeBox(transform: flatTransform, dimensions: dims)
            allVertices.append(contentsOf: box.vertices)
            allIndices.append(contentsOf: box.indices.map { $0 + baseIndex })
            baseIndex += UInt32(box.vertices.count)
        }
        return ProcessedMesh(vertices: allVertices, indices: allIndices)
    }

    // MARK: - Obstacle mesh generation

    /// Converts wall surfaces and furniture objects into meshes.
    /// Chairs use a recognisable chair mesh; all other objects use a box.
    static func buildObstacleMesh(
        walls: [MultiRoomStitcher.SurfacePrimitive],
        objects: [MultiRoomStitcher.ObjectPrimitive]
    ) -> ProcessedMesh {
        var allVerts  = [simd_float3]()
        var allIdx    = [UInt32]()
        var base: UInt32 = 0

        var meshes = [ProcessedMesh]()

        // Walls → boxes
        for wall in walls {
            meshes.append(makeBox(transform: wall.transform, dimensions: wall.dimensions))
        }

        // Objects → category-specific mesh
        for obj in objects {
            let mesh: ProcessedMesh
            switch obj.category {
            case "chair":
                mesh = makeChair(transform: obj.transform, dimensions: obj.dimensions)
            default:
                mesh = makeBox(transform: obj.transform, dimensions: obj.dimensions)
            }
            meshes.append(mesh)
        }

        for m in meshes {
            allVerts.append(contentsOf: m.vertices)
            allIdx.append(contentsOf: m.indices.map { $0 + base })
            base += UInt32(m.vertices.count)
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

    // MARK: - Floor mesh from wall footprint

    /// Builds a floor mesh whose polygon exactly matches the outer bottom boundary of walls.
    /// Strategy (in priority order):
    ///   1. Ordered wall-chain polygon — exact concave shape (L, T, U rooms).
    ///      Gap-tolerant: door openings are bridged rather than causing a full abort.
    ///   2. Convex hull of outer-face wall corners — reliable fallback.
    ///   3. unifyFloors from RoomPlan floor surfaces — absolute fallback.
    /// Triangulates with ear clipping so concave polygons are handled correctly.
    /// The floor is placed at the bottom of the walls (minimum wall base Y).
    static func buildFloorFromWalls(
        walls: [MultiRoomStitcher.SurfacePrimitive],
        fallbackFloors: [MultiRoomStitcher.SurfacePrimitive]
    ) -> ProcessedMesh {
        // Use outer-face corners only — these define the true room perimeter.
        let outerPts = wallOuterBottomCorners(walls)
        guard outerPts.count >= 3 else { return unifyFloors(from: fallbackFloors) }
        let dedupPts = deduplicatePoints2D(outerPts, tolerance: 0.05)

        // Floor is always at Y=0 — MultiRoomStitcher.buildMergedGeometry() already
        // normalises all geometry so the floor plane sits exactly at Y=0.
        let floorY: Float = 0.0

        var polygon: [SIMD2<Float>]
        if let chain = buildWallChainTolerant(walls: walls, snapTolerance: 0.30), chain.count >= 3 {
            polygon = chain
        } else if let hull = convexHull2D(dedupPts), hull.count >= 3 {
            polygon = hull
        } else {
            return unifyFloors(from: fallbackFloors)
        }

        ensureCCW(&polygon)
        let indices = earClip(polygon)
        guard !indices.isEmpty else { return unifyFloors(from: fallbackFloors) }

        return ProcessedMesh(
            vertices: polygon.map { simd_float3($0.x, floorY, $0.y) },
            indices: indices
        )
    }

    /// Polygon area in square metres via the shoelace formula.
    /// Pass the XZ polygon produced by buildFloorFromWalls.
    static func polygonAreaM2(_ pts: [SIMD2<Float>]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var sum: Double = 0
        for i in 0..<pts.count {
            let j = (i + 1) % pts.count
            sum += Double(pts[i].x) * Double(pts[j].y)
                 - Double(pts[j].x) * Double(pts[i].y)
        }
        return abs(sum) * 0.5
    }

    // MARK: - Floor polygon helpers

    /// Returns the 2 outer-face bottom corners of every wall, projected onto XZ.
    /// "Outer face" = local Z = +ht (the face pointing away from the room interior).
    /// This gives a point cloud that lies on the true outer perimeter of the room,
    /// so a convex hull correctly covers the floor area beneath the walls.
    private static func wallOuterBottomCorners(
        _ walls: [MultiRoomStitcher.SurfacePrimitive]
    ) -> [SIMD2<Float>] {
        var pts = [SIMD2<Float>]()
        pts.reserveCapacity(walls.count * 4)
        for wall in walls {
            let hw = wall.dimensions.x / 2   // half-width  (local X)
            let ht = wall.dimensions.z / 2   // half-thickness (local Z)
            // Include both inner AND outer face corners so the hull covers
            // the full wall footprint (needed when walls are thick).
            for (lx, lz): (Float, Float) in [(-hw, -ht), (hw, -ht), (hw, ht), (-hw, ht)] {
                let w = wall.transform * simd_float4(lx, 0, lz, 1)
                pts.append(SIMD2(w.x, w.z))
            }
        }
        return pts
    }

    /// Gap-tolerant wall-chain builder.
    ///
    /// Unlike the strict version, this one does NOT abort when a wall can't be
    /// attached at the snap tolerance — it simply skips the gap (door openings,
    /// missing walls) and continues picking the next nearest unused wall.
    /// The chain is then closed by connecting tail back to head.
    ///
    /// Returns nil only when there are fewer than 3 walls.
    private static func buildWallChainTolerant(
        walls: [MultiRoomStitcher.SurfacePrimitive],
        snapTolerance: Float
    ) -> [SIMD2<Float>]? {
        guard walls.count >= 3 else { return nil }

        // Each wall contributes one inner-face segment (local Z = 0 mid-plane).
        // We use the outer-face midpoint so the polygon sits outside the walls.
        struct Seg { var a, b: SIMD2<Float>; var used = false }
        var segs: [Seg] = walls.map { wall in
            let hw = wall.dimensions.x / 2
            let ht = wall.dimensions.z / 2   // push to outer face
            // Outer-face left / right endpoints
            let wl = wall.transform * simd_float4(-hw, 0,  ht, 1)
            let wr = wall.transform * simd_float4( hw, 0,  ht, 1)
            return Seg(a: SIMD2(wl.x, wl.z), b: SIMD2(wr.x, wr.z))
        }

        // Sort segments so we start at the bottommost-left wall — deterministic.
        let startIdx = segs.indices.min(by: {
            let ca = (segs[$0].a + segs[$0].b) * 0.5
            let cb = (segs[$1].a + segs[$1].b) * 0.5
            return ca.y < cb.y || (ca.y == cb.y && ca.x < cb.x)
        }) ?? 0

        // Rotate so startIdx is first.
        var ordered = Array(segs[startIdx...]) + Array(segs[..<startIdx])
        ordered[0].used = true
        var chain: [SIMD2<Float>] = [ordered[0].a, ordered[0].b]
        var tail = ordered[0].b

        // Gap tolerance: allow jumps up to 3× snapTolerance across door openings.
        let gapTolerance: Float = snapTolerance * 3.0

        for _ in 1..<ordered.count {
            var bestDist = Float.greatestFiniteMagnitude
            var bestIdx  = -1
            var useAEnd  = false

            for i in 0..<ordered.count where !ordered[i].used {
                let da = simd_length(ordered[i].a - tail)
                let db = simd_length(ordered[i].b - tail)
                if da < bestDist { bestDist = da; bestIdx = i; useAEnd = false }
                if db < bestDist { bestDist = db; bestIdx = i; useAEnd = true  }
            }

            // Skip if the nearest wall is too far away even for a gap.
            guard bestIdx >= 0, bestDist <= gapTolerance else { break }

            ordered[bestIdx].used = true
            let next: SIMD2<Float> = useAEnd ? ordered[bestIdx].a : ordered[bestIdx].b
            chain.append(next)
            tail = next
        }

        // Close the loop: remove the closing duplicate if tail ≈ head.
        if chain.count > 3, simd_length(tail - chain[0]) < gapTolerance {
            chain.removeLast()
        }

        return chain.count >= 3 ? chain : nil
    }

    /// Removes any 2D point within `tolerance` metres of an already-kept point.
    private static func deduplicatePoints2D(
        _ pts: [SIMD2<Float>], tolerance: Float
    ) -> [SIMD2<Float>] {
        var unique = [SIMD2<Float>]()
        unique.reserveCapacity(pts.count)
        for p in pts where !unique.contains(where: { simd_length($0 - p) < tolerance }) {
            unique.append(p)
        }
        return unique
    }

    /// Reverses the polygon in-place if it is wound clockwise.
    /// Ear clipping assumes CCW winding.
    private static func ensureCCW(_ pts: inout [SIMD2<Float>]) {
        var sum: Double = 0
        for i in 0..<pts.count {
            let j = (i + 1) % pts.count
            sum += Double(pts[i].x) * Double(pts[j].y)
                 - Double(pts[j].x) * Double(pts[i].y)
        }
        if sum < 0 { pts.reverse() }
    }

    /// Ear-clipping triangulation for a simple polygon (convex or concave).
    /// Requires CCW winding. Returns indices into the polygon's vertex array.
    private static func earClip(_ polygon: [SIMD2<Float>]) -> [UInt32] {
        let n = polygon.count
        guard n >= 3 else { return [] }
        if n == 3 { return [0, 1, 2] }

        var remaining = Array(0..<n)
        var result    = [UInt32]()
        result.reserveCapacity((n - 2) * 3)
        var budget = n * n + 1   // O(n²) worst case; prevents infinite loop

        while remaining.count > 3, budget > 0 {
            budget -= 1
            let m = remaining.count
            var clipped = false

            for i in 0..<m {
                let iPrev = (i + m - 1) % m
                let iNext = (i + 1) % m
                let pPrev = polygon[remaining[iPrev]]
                let pCurr = polygon[remaining[i]]
                let pNext = polygon[remaining[iNext]]

                // Cross product of the two edge vectors at pCurr.
                // Positive → left turn → convex vertex in a CCW polygon.
                let ux = pCurr.x - pPrev.x, uy = pCurr.y - pPrev.y
                let vx = pNext.x - pCurr.x, vy = pNext.y - pCurr.y
                guard ux * vy - uy * vx > 1e-9 else { continue }

                // No other polygon vertex may lie inside this candidate ear.
                var isEar = true
                for j in 0..<m {
                    if j == iPrev || j == i || j == iNext { continue }
                    if pointInTriangle2D(polygon[remaining[j]], pPrev, pCurr, pNext) {
                        isEar = false; break
                    }
                }
                guard isEar else { continue }

                result.append(contentsOf: [
                    UInt32(remaining[iPrev]),
                    UInt32(remaining[i]),
                    UInt32(remaining[iNext])
                ])
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }

        if remaining.count == 3 {
            result.append(contentsOf: remaining.map { UInt32($0) })
        }
        return result
    }

    private static func pointInTriangle2D(
        _ p: SIMD2<Float>,
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>
    ) -> Bool {
        func side(_ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ q: SIMD2<Float>) -> Float {
            (p2.x - p1.x) * (q.y - p1.y) - (p2.y - p1.y) * (q.x - p1.x)
        }
        let d1 = side(a, b, p), d2 = side(b, c, p), d3 = side(c, a, p)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    // Alpha-shape removed: it produces self-intersecting polygons when the
    // 4-corner wall points (inner + outer face interleaved) are passed in.
    // The gap-tolerant wall-chain + convex-hull fallback are sufficient.

    // Graham-scan convex hull — fallback when the wall chain fails to close.
    private static func convexHull2D(_ points: [SIMD2<Float>]) -> [SIMD2<Float>]? {
        guard points.count >= 3 else { return nil }
        guard let pivot = points.min(by: { $0.y < $1.y || ($0.y == $1.y && $0.x < $1.x) })
        else { return nil }

        var usedPivot = false
        let rest = points.filter { p in
            if !usedPivot, p == pivot { usedPivot = true; return false }
            return true
        }
        let sorted = rest.sorted { a, b in
            let c = (a.x - pivot.x) * (b.y - pivot.y) - (a.y - pivot.y) * (b.x - pivot.x)
            return abs(c) < 1e-6
                ? simd_length(a - pivot) < simd_length(b - pivot)
                : c > 0
        }
        var hull: [SIMD2<Float>] = [pivot]
        for p in sorted {
            while hull.count >= 2 {
                let o = hull[hull.count - 2], a = hull.last!
                let cross = (a.x - o.x) * (p.y - o.y) - (a.y - o.y) * (p.x - o.x)
                if cross <= 0 { hull.removeLast() } else { break }
            }
            hull.append(p)
        }
        return hull.count >= 3 ? hull : nil
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
