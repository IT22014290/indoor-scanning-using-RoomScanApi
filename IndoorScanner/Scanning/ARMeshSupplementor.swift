import Foundation
import ARKit
import simd

/// Captures ARKit LiDAR mesh anchors for objects RoomPlan does not classify.
/// This supplementary pass fills gaps (bins, pillars, display stands).
@MainActor
final class ARMeshSupplementor: NSObject, ObservableObject {

    @Published var meshAnchorCount: Int = 0

    private var arSession: ARSession?
    private(set) var meshAnchors: [ARMeshAnchor] = []

    // World transform of the QR code origin, set by QROriginCalibrator
    var qrWorldTransform: simd_float4x4 = matrix_identity_float4x4

    func attach(to session: ARSession) {
        arSession = session
        arSession?.delegate = self
    }

    func clearMesh() {
        meshAnchors = []
        meshAnchorCount = 0
    }

    // MARK: - Geometry extraction

    struct DetectedObstacle {
        var transform: simd_float4x4
        var dimensions: simd_float3
        var category: String
    }

    /// Returns vertices from all mesh anchors transformed into QR-relative space.
    func extractObstacleFaces(
        excludingBounds roomBounds: BoundingBox3D
    ) -> [(vertices: [simd_float3], indices: [UInt32])] {

        let qrInverse = simd_inverse(qrWorldTransform)
        var results: [(vertices: [simd_float3], indices: [UInt32])] = []

        for anchor in meshAnchors {
            let anchorToQR = qrInverse * anchor.transform

            let geometry = anchor.geometry
            let vertexBuffer = geometry.vertices
            let faceBuffer = geometry.faces

            // Extract vertices
            var verts = [simd_float3]()
            verts.reserveCapacity(vertexBuffer.count)
            for i in 0..<vertexBuffer.count {
                let v = geometry.vertex(at: UInt32(i))
                let world = (anchorToQR * simd_float4(v.0, v.1, v.2, 1)).xyz
                verts.append(world)
            }

            // Filter: only include faces whose centroid is outside RoomPlan coverage
            var filteredIndices = [UInt32]()
            for f in 0..<faceBuffer.count {
                let (i0, i1, i2) = geometry.vertexIndicesOf(faceWithIndex: f)
                let centroid = (verts[Int(i0)] + verts[Int(i1)] + verts[Int(i2)]) / 3
                // Keep only faces that are NOT on flat floor/ceiling planes
                // (RoomPlan handles walls/floor – we want leftover obstacles)
                let isFloorOrCeiling = abs(centroid.y) < 0.05 || abs(centroid.y - 2.5) < 0.1
                if !isFloorOrCeiling {
                    filteredIndices.append(contentsOf: [i0, i1, i2])
                }
            }

            if !filteredIndices.isEmpty {
                results.append((vertices: verts, indices: filteredIndices))
            }
        }
        return results
    }

    /// Heuristic detection of cylindrical/unclassified obstacles from LiDAR mesh chunks.
    func detectSupplementalObstacles(
        excludingBounds roomBounds: BoundingBox3D
    ) -> [DetectedObstacle] {
        let chunks = extractObstacleFaces(excludingBounds: roomBounds)
        var results: [DetectedObstacle] = []

        for chunk in chunks {
            guard !chunk.vertices.isEmpty else { continue }
            let xs = chunk.vertices.map(\.x)
            let ys = chunk.vertices.map(\.y)
            let zs = chunk.vertices.map(\.z)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max(),
                  let minZ = zs.min(), let maxZ = zs.max() else { continue }

            let width = maxX - minX
            let depth = maxZ - minZ
            let height = maxY - minY
            if height < 0.25 || width < 0.10 || depth < 0.10 { continue }

            let footprintRatio = max(width, depth) / max(min(width, depth), 0.001)
            let isCylinderLike =
                footprintRatio <= 1.25 &&
                height >= 0.35 && height <= 3.00 &&
                width >= 0.15 && width <= 1.20 &&
                depth >= 0.15 && depth <= 1.20

            let center = simd_float3((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
            var t = matrix_identity_float4x4
            t.columns.3 = simd_float4(center.x, center.y, center.z, 1)
            let dims = simd_float3(width, height, depth)

            results.append(
                DetectedObstacle(
                    transform: t,
                    dimensions: dims,
                    category: isCylinderLike ? "obstacle.cylinder" : "obstacle.unknown"
                )
            )
        }

        return results
    }
}

// MARK: - ARSessionDelegate
extension ARMeshSupplementor: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        Task { @MainActor in
            self.meshAnchors.append(contentsOf: meshes)
            self.meshAnchorCount = self.meshAnchors.count
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let updated = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !updated.isEmpty else { return }
        Task { @MainActor in
            for anchor in updated {
                if let idx = self.meshAnchors.firstIndex(where: { $0.identifier == anchor.identifier }) {
                    self.meshAnchors[idx] = anchor
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let removed = Set(anchors.compactMap { $0 as? ARMeshAnchor }.map { $0.identifier })
        guard !removed.isEmpty else { return }
        Task { @MainActor in
            self.meshAnchors.removeAll { removed.contains($0.identifier) }
            self.meshAnchorCount = self.meshAnchors.count
        }
    }
}

// MARK: - ARMeshGeometry helpers
private extension ARMeshGeometry {
    func vertex(at index: UInt32) -> (Float, Float, Float) {
        let source = vertices
        let stride = source.stride
        let offset = source.offset
        let ptr = source.buffer.contents().advanced(by: offset + Int(index) * stride)
        return ptr.load(as: (Float, Float, Float).self)
    }

    func vertexIndicesOf(faceWithIndex index: Int) -> (UInt32, UInt32, UInt32) {
        let source = faces
        let stride = source.bytesPerIndex
        let base = source.buffer.contents().advanced(by: index * 3 * stride)
        if stride == 4 {
            let i0 = base.load(as: UInt32.self)
            let i1 = base.advanced(by: stride).load(as: UInt32.self)
            let i2 = base.advanced(by: stride * 2).load(as: UInt32.self)
            return (i0, i1, i2)
        } else {
            let i0 = UInt32(base.load(as: UInt16.self))
            let i1 = UInt32(base.advanced(by: stride).load(as: UInt16.self))
            let i2 = UInt32(base.advanced(by: stride * 2).load(as: UInt16.self))
            return (i0, i1, i2)
        }
    }
}

private extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}
