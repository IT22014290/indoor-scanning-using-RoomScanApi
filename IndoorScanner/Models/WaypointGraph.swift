import Foundation
import simd

struct Waypoint: Identifiable, Codable {
    let id: String
    var position: SIMD3<Float>
    var label: String

    enum CodingKeys: String, CodingKey { case id, position, label }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(["x": position.x, "y": position.y, "z": position.z], forKey: .position)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        let pos = try c.decode([String: Float].self, forKey: .position)
        position = SIMD3<Float>(pos["x"] ?? 0, pos["y"] ?? 0, pos["z"] ?? 0)
    }

    init(id: String, position: SIMD3<Float>, label: String) {
        self.id = id; self.position = position; self.label = label
    }
}

struct WaypointEdge: Codable {
    let from: String
    let to: String
    let distanceM: Float
}

struct WaypointGraph: Codable {
    var waypoints: [Waypoint] = []
    var edges: [WaypointEdge] = []

    mutating func addWaypoint(_ wp: Waypoint) { waypoints.append(wp) }

    mutating func connect(_ fromID: String, _ toID: String) {
        guard let a = waypoints.first(where: { $0.id == fromID }),
              let b = waypoints.first(where: { $0.id == toID }) else { return }
        let dist = simd_distance(a.position, b.position)
        edges.append(WaypointEdge(from: fromID, to: toID, distanceM: dist))
    }

    func shortestPath(from startID: String, to endID: String) -> [String] {
        var dist = [String: Float]()
        var prev = [String: String]()
        var unvisited = Set(waypoints.map { $0.id })

        waypoints.forEach { dist[$0.id] = .infinity }
        dist[startID] = 0

        // Build adjacency
        var adj = [String: [(String, Float)]]()
        for edge in edges {
            adj[edge.from, default: []].append((edge.to, edge.distanceM))
            adj[edge.to, default: []].append((edge.from, edge.distanceM))
        }

        while !unvisited.isEmpty {
            guard let u = unvisited.min(by: { (dist[$0] ?? .infinity) < (dist[$1] ?? .infinity) }),
                  dist[u] != .infinity else { break }
            unvisited.remove(u)
            for (v, w) in adj[u] ?? [] where unvisited.contains(v) {
                let alt = (dist[u] ?? .infinity) + w
                if alt < (dist[v] ?? .infinity) {
                    dist[v] = alt
                    prev[v] = u
                }
            }
        }

        var path = [String]()
        var cur: String? = endID
        while let c = cur {
            path.insert(c, at: 0)
            cur = prev[c]
            if c == startID { break }
        }
        return path.first == startID ? path : []
    }
}
