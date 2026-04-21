import Foundation
import simd

/// Generates a corridor-centred waypoint graph by sampling the free floor area
/// and connecting nodes that have clear line-of-sight between obstacles.
struct WaypointGenerator {

    struct Config {
        var gridSpacingM: Float = 1.5
        var agentRadiusM: Float = 0.4
        var floorY:       Float = 0.05
    }

    // MARK: - Main entry point

    static func generate(
        floorBounds: BoundingBox3D,
        obstacles: [MultiRoomStitcher.ObjectPrimitive],
        walls: [MultiRoomStitcher.SurfacePrimitive],
        config: Config = Config()
    ) -> WaypointGraph {

        let obstacleBounds = obstacles.map { AABB(transform: $0.transform, dims: $0.dimensions) }
        let wallBounds     = walls.map { AABB(transform: $0.transform, dims: $0.dimensions) }
        let allAABBs       = obstacleBounds + wallBounds

        // Sample grid over floor
        var candidates = [simd_float3]()
        var x = floorBounds.minX + config.gridSpacingM / 2
        while x < floorBounds.maxX {
            var z = floorBounds.minZ + config.gridSpacingM / 2
            while z < floorBounds.maxZ {
                let pt = simd_float3(x, config.floorY, z)
                if !isOccupied(pt, aabbs: allAABBs, radius: config.agentRadiusM) {
                    candidates.append(pt)
                }
                z += config.gridSpacingM
            }
            x += config.gridSpacingM
        }

        guard !candidates.isEmpty else { return WaypointGraph() }

        // Build waypoints
        var graph = WaypointGraph()
        for (i, pos) in candidates.enumerated() {
            graph.addWaypoint(Waypoint(id: "wp_\(String(format: "%04d", i))",
                                       position: pos,
                                       label: ""))
        }

        // Connect adjacent nodes with line-of-sight check
        let wps = graph.waypoints
        for i in 0..<wps.count {
            for j in (i+1)..<wps.count {
                let a = wps[i].position
                let b = wps[j].position
                let dist = simd_distance(a, b)
                guard dist <= config.gridSpacingM * 1.5 else { continue }
                if hasLineOfSight(from: a, to: b, aabbs: allAABBs) {
                    graph.connect(wps[i].id, wps[j].id)
                }
            }
        }

        // Prune isolated waypoints (no edges)
        let connected = Set(graph.edges.flatMap { [$0.from, $0.to] })
        graph.waypoints.removeAll { !connected.contains($0.id) }

        // Label corridor positions
        labelWaypoints(&graph, floorBounds: floorBounds)

        return graph
    }

    // MARK: - Private helpers

    private struct AABB {
        let minX, maxX, minY, maxY, minZ, maxZ: Float

        init(transform: simd_float4x4, dims: simd_float3) {
            let c = transform.translation
            let hx = dims.x / 2; let hy = dims.y / 2; let hz = dims.z / 2
            minX = c.x - hx; maxX = c.x + hx
            minY = c.y - hy; maxY = c.y + hy
            minZ = c.z - hz; maxZ = c.z + hz
        }

        func contains(_ p: simd_float3, radius: Float) -> Bool {
            p.x > minX - radius && p.x < maxX + radius &&
            p.z > minZ - radius && p.z < maxZ + radius
        }
    }

    private static func isOccupied(_ point: simd_float3,
                                    aabbs: [AABB],
                                    radius: Float) -> Bool {
        aabbs.contains { $0.contains(point, radius: radius) }
    }

    private static func hasLineOfSight(from a: simd_float3,
                                        to b: simd_float3,
                                        aabbs: [AABB]) -> Bool {
        let steps = 8
        for i in 1..<steps {
            let t = Float(i) / Float(steps)
            let sample = a + (b - a) * t
            if aabbs.contains(where: { $0.contains(sample, radius: 0.1) }) {
                return false
            }
        }
        return true
    }

    private static func labelWaypoints(_ graph: inout WaypointGraph,
                                        floorBounds: BoundingBox3D) {
        let width  = floorBounds.maxX - floorBounds.minX
        let depth  = floorBounds.maxZ - floorBounds.minZ
        let colCount = max(1, Int(width / 3.0))

        for i in 0..<graph.waypoints.count {
            let p = graph.waypoints[i].position
            let normX = (p.x - floorBounds.minX) / max(width, 1)
            let col = min(Int(normX * Float(colCount)) + 1, colCount)
            let normZ = (p.z - floorBounds.minZ) / max(depth, 1)
            let section = normZ < 0.33 ? "Start" : normZ < 0.66 ? "Mid" : "End"
            graph.waypoints[i] = Waypoint(id: graph.waypoints[i].id,
                                           position: p,
                                           label: "Aisle \(col) \(section)")
        }
    }
}
