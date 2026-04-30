import Foundation
import RoomPlan
import simd

/// A fully processed room result ready for stitching and export.
struct ScannedRoom: Identifiable, Codable {
    let id: UUID
    var label: String
    var floorAreaM2: Double
    var objectCount: Int
    var capturedRoomURL: URL?          // on-disk CapturedRoom JSON (iOS 16 export)
    var qrRelativeTransform: simd_float4x4

    init(id: UUID = UUID(),
         label: String,
         floorAreaM2: Double,
         objectCount: Int,
         capturedRoomURL: URL? = nil,
         qrRelativeTransform: simd_float4x4 = matrix_identity_float4x4) {
        self.id = id
        self.label = label
        self.floorAreaM2 = floorAreaM2
        self.objectCount = objectCount
        self.capturedRoomURL = capturedRoomURL
        self.qrRelativeTransform = qrRelativeTransform
    }

    // MARK: Codable support for simd_float4x4
    enum CodingKeys: String, CodingKey {
        case id, label, floorAreaM2, objectCount, capturedRoomURL, transformColumns
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(floorAreaM2, forKey: .floorAreaM2)
        try c.encode(objectCount, forKey: .objectCount)
        try c.encodeIfPresent(capturedRoomURL, forKey: .capturedRoomURL)
        let cols = [
            [qrRelativeTransform.columns.0.x, qrRelativeTransform.columns.0.y,
             qrRelativeTransform.columns.0.z, qrRelativeTransform.columns.0.w],
            [qrRelativeTransform.columns.1.x, qrRelativeTransform.columns.1.y,
             qrRelativeTransform.columns.1.z, qrRelativeTransform.columns.1.w],
            [qrRelativeTransform.columns.2.x, qrRelativeTransform.columns.2.y,
             qrRelativeTransform.columns.2.z, qrRelativeTransform.columns.2.w],
            [qrRelativeTransform.columns.3.x, qrRelativeTransform.columns.3.y,
             qrRelativeTransform.columns.3.z, qrRelativeTransform.columns.3.w]
        ]
        try c.encode(cols, forKey: .transformColumns)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        floorAreaM2 = try c.decode(Double.self, forKey: .floorAreaM2)
        objectCount = try c.decode(Int.self, forKey: .objectCount)
        capturedRoomURL = try c.decodeIfPresent(URL.self, forKey: .capturedRoomURL)
        let cols = try c.decode([[Float]].self, forKey: .transformColumns)
        qrRelativeTransform = simd_float4x4(columns: (
            simd_float4(cols[0][0], cols[0][1], cols[0][2], cols[0][3]),
            simd_float4(cols[1][0], cols[1][1], cols[1][2], cols[1][3]),
            simd_float4(cols[2][0], cols[2][1], cols[2][2], cols[2][3]),
            simd_float4(cols[3][0], cols[3][1], cols[3][2], cols[3][3])
        ))
    }
}

// MARK: - Bounds helper
struct BoundingBox3D: Codable {
    var minX, maxX: Float
    var minY, maxY: Float
    var minZ, maxZ: Float

    static let zero = BoundingBox3D(minX: 0, maxX: 0, minY: 0, maxY: 0, minZ: 0, maxZ: 0)

    mutating func expand(by point: simd_float3) {
        minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
        minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        minZ = Swift.min(minZ, point.z); maxZ = Swift.max(maxZ, point.z)
    }

    static func union(_ a: BoundingBox3D, _ b: BoundingBox3D) -> BoundingBox3D {
        BoundingBox3D(
            minX: min(a.minX, b.minX), maxX: max(a.maxX, b.maxX),
            minY: min(a.minY, b.minY), maxY: max(a.maxY, b.maxY),
            minZ: min(a.minZ, b.minZ), maxZ: max(a.maxZ, b.maxZ)
        )
    }
}

// MARK: - CapturedRoom geometry helpers
extension CapturedRoom {
    var floorAreaM2: Double {
        if #available(iOS 17.0, *) {
            return floors.reduce(0.0) { total, floor in
                let d = floor.dimensions
                let sorted = [d.x, d.y, d.z].sorted(by: >)
                return total + Double(sorted[0] * sorted[1])
            }
        } else {
            // iOS 16 fallback: estimate floor area from wall bounding box
            guard !walls.isEmpty else { return 0 }
            let positions = walls.map { $0.transform.translation }
            let xs = positions.map { $0.x }
            let zs = positions.map { $0.z }
            let w = Double((xs.max() ?? 0) - (xs.min() ?? 0))
            let d = Double((zs.max() ?? 0) - (zs.min() ?? 0))
            return max(w * d, 0)
        }
    }
}
