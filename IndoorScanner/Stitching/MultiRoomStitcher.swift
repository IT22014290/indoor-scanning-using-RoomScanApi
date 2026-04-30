import Foundation
import RoomPlan
import simd

/// Stitches multiple CapturedRoom objects from sequential scans into a
/// single unified geometry, using shared wall detection and QR-relative transforms.
@MainActor
final class MultiRoomStitcher: ObservableObject {

    struct RoomEntry {
        let id: UUID
        var label: String
        var capturedRoom: CapturedRoom
        var qrRelativeTransform: simd_float4x4   // room-local origin → QR space
    }

    @Published private(set) var rooms: [RoomEntry] = []

    var totalFloorAreaM2: Double {
        rooms.reduce(0) { $0 + $1.capturedRoom.floorAreaM2 }
    }

    // MARK: - Room management

    @discardableResult
    func addRoom(_ room: CapturedRoom,
                 label: String,
                 qrRelativeTransform: simd_float4x4) -> UUID {
        let id = UUID()
        rooms.append(RoomEntry(id: id,
                               label: label,
                               capturedRoom: room,
                               qrRelativeTransform: qrRelativeTransform))
        return id
    }

    func reset() { rooms = [] }

    // MARK: - Geometry extraction for export

    struct MergedGeometry {
        var walls:   [SurfacePrimitive] = []
        var floors:  [SurfacePrimitive] = []
        var aisles:  [SurfacePrimitive] = []
        var doors:   [SurfacePrimitive] = []
        var windows: [SurfacePrimitive] = []
        var objects: [ObjectPrimitive]  = []
        var bounds:  BoundingBox3D = .zero
    }

    struct SurfacePrimitive {
        var transform: simd_float4x4    // in QR space
        var dimensions: simd_float3
        var category: String
        var roomID: UUID
    }

    struct ObjectPrimitive {
        var transform: simd_float4x4    // in QR space
        var dimensions: simd_float3
        var category: String
        var roomID: UUID
    }

    func buildMergedGeometry() -> MergedGeometry {
        var merged = MergedGeometry()
        var expandedBounds = false

        for entry in rooms {
            let room = entry.capturedRoom
            let toQR = entry.qrRelativeTransform

            // Walls
            for surface in room.walls {
                let t = toQR * surface.transform
                merged.walls.append(SurfacePrimitive(
                    transform: t,
                    dimensions: surface.dimensions,
                    category: "wall",
                    roomID: entry.id
                ))
                updateBounds(&merged.bounds, transform: t, dims: surface.dimensions,
                             expanded: &expandedBounds)
            }

            // Floors (iOS 17+ only; on iOS 16 we synthesise a floor from wall bounds)
            if #available(iOS 17.0, *) {
                for surface in room.floors {
                    let t = toQR * surface.transform
                    merged.floors.append(SurfacePrimitive(
                        transform: t,
                        dimensions: surface.dimensions,
                        category: "floor",
                        roomID: entry.id
                    ))
                }
            } else {
                // Synthesise a single flat floor from the wall bounding box
                let wallPositions = room.walls.map { (toQR * $0.transform).translation }
                if !wallPositions.isEmpty {
                    let xs = wallPositions.map { $0.x }
                    let zs = wallPositions.map { $0.z }
                    let cx = ((xs.max() ?? 0) + (xs.min() ?? 0)) / 2
                    let cz = ((zs.max() ?? 0) + (zs.min() ?? 0)) / 2
                    let w  = (xs.max() ?? 0) - (xs.min() ?? 0)
                    let d  = (zs.max() ?? 0) - (zs.min() ?? 0)
                    var t  = matrix_identity_float4x4
                    t.columns.3 = simd_float4(cx, 0, cz, 1)
                    merged.floors.append(SurfacePrimitive(
                        transform: t,
                        dimensions: simd_float3(w, 0.01, d),
                        category: "floor",
                        roomID: entry.id
                    ))
                }
            }

            // Doors
            for surface in room.doors {
                merged.doors.append(SurfacePrimitive(
                    transform: toQR * surface.transform,
                    dimensions: surface.dimensions,
                    category: "door",
                    roomID: entry.id
                ))
            }

            // Windows
            for surface in room.windows {
                merged.windows.append(SurfacePrimitive(
                    transform: toQR * surface.transform,
                    dimensions: surface.dimensions,
                    category: "window",
                    roomID: entry.id
                ))
            }

            // Objects
            for object in room.objects {
                let t = toQR * object.transform
                merged.objects.append(ObjectPrimitive(
                    transform: t,
                    dimensions: object.dimensions,
                    category: classifiedLabel(for: object),
                    roomID: entry.id
                ))
                updateBounds(&merged.bounds, transform: t, dims: object.dimensions,
                             expanded: &expandedBounds)
            }
        }

        // Shift all geometry so the floor sits at Y=0.
        // RoomPlan places Y=0 at the phone's position when scanning starts (roughly waist
        // height), so floors have a negative Y and walls straddle the origin. We compute
        // the offset from the lowest floor center and apply it uniformly before snapping.
        let floorYs = merged.floors.map { $0.transform.columns.3.y }
        if let lowestFloorY = floorYs.min(), abs(lowestFloorY) > 0.01 {
            let yShift = -lowestFloorY
            merged.walls   = merged.walls.map   { var s = $0; s.transform.columns.3.y += yShift; return s }
            merged.objects = merged.objects.map { var o = $0; o.transform.columns.3.y += yShift; return o }
            merged.doors   = merged.doors.map   { var s = $0; s.transform.columns.3.y += yShift; return s }
            merged.windows = merged.windows.map { var s = $0; s.transform.columns.3.y += yShift; return s }
            merged.bounds.minY += yShift
            merged.bounds.maxY += yShift
        }

        // Snap all floor transforms to Y=0 (unified floor plane)
        merged.floors = merged.floors.map { floor in
            var f = floor
            f.transform.columns.3.y = 0
            return f
        }
        merged.aisles = detectAisles(from: merged.floors)

        return merged
    }

    // MARK: - Duplicate wall removal
    /// Removes walls detected from both sides (within 5cm and same orientation).
    func deduplicate(walls: [SurfacePrimitive]) -> [SurfacePrimitive] {
        var kept = [SurfacePrimitive]()
        for candidate in walls {
            let cPos = candidate.transform.translation
            let isDuplicate = kept.contains { existing in
                let ePos = existing.transform.translation
                let dist = simd_distance(cPos, ePos)
                let parallelism = abs(simd_dot(
                    candidate.transform.normalVector,
                    existing.transform.normalVector
                ))
                return dist < 0.10 && parallelism > 0.98
            }
            if !isDuplicate { kept.append(candidate) }
        }
        return kept
    }

    // MARK: - Private

    private func updateBounds(_ bounds: inout BoundingBox3D,
                               transform: simd_float4x4,
                               dims: simd_float3,
                               expanded: inout Bool) {
        let pos = transform.translation
        let corners: [simd_float3] = [
            pos + simd_float3( dims.x/2,  dims.y/2,  dims.z/2),
            pos + simd_float3(-dims.x/2, -dims.y/2, -dims.z/2)
        ]
        for c in corners {
            if !expanded {
                bounds = BoundingBox3D(minX: c.x, maxX: c.x,
                                       minY: c.y, maxY: c.y,
                                       minZ: c.z, maxZ: c.z)
                expanded = true
            } else {
                bounds.expand(by: c)
            }
        }
    }

    /// Heuristic aisle detector: long, narrow floor segments are tagged as aisles.
    private func detectAisles(from floors: [SurfacePrimitive]) -> [SurfacePrimitive] {
        floors.compactMap { floor in
            let width = min(floor.dimensions.x, floor.dimensions.z)
            let length = max(floor.dimensions.x, floor.dimensions.z)
            let aspect = length / max(width, 0.01)
            guard width >= 0.9, width <= 3.0, length >= 2.0, aspect >= 1.8 else {
                return nil
            }
            var aisle = floor
            aisle.category = "aisle"
            aisle.dimensions.y = max(aisle.dimensions.y, 0.03)
            return aisle
        }
    }

    /// Promote small storage boxes to bins for retail/warehouse style scenes.
    private func classifiedLabel(for object: CapturedRoom.Object) -> String {
        if object.category == .storage {
            let d = object.dimensions
            let width = d.x
            let depth = d.z
            let height = d.y
            let horizontalMax = max(width, depth)
            let horizontalMin = min(width, depth)
            let maxSide = max(horizontalMax, height)
            let minSide = min(horizontalMin, height)

            // Rounded bin heuristic: cylindrical-like footprint (x ~= z), medium height.
            let footprintRatio = horizontalMax / max(horizontalMin, 0.01)
            let isRoundedBin =
                footprintRatio <= 1.20 &&
                horizontalMax >= 0.20 && horizontalMax <= 0.90 &&
                height >= 0.25 && height <= 1.20
            if isRoundedBin {
                return "rounded_bin"
            }

            // Generic bin heuristic: small-to-medium storage volume.
            if maxSide <= 1.0 && minSide >= 0.2 {
                return "bin"
            }
        }
        return object.category.label
    }
}

// MARK: - simd_float4x4 helpers
extension simd_float4x4 {
    var translation: simd_float3 {
        simd_float3(columns.3.x, columns.3.y, columns.3.z)
    }
    var normalVector: simd_float3 {
        simd_normalize(simd_float3(columns.2.x, columns.2.y, columns.2.z))
    }
}

extension CapturedRoom.Object.Category {
    var label: String {
        switch self {
        case .table:        return "table"
        case .chair:        return "chair"
        case .sofa:         return "sofa"
        case .fireplace:    return "fireplace"
        case .television:   return "television"
        case .washerDryer:  return "washerdryer"
        case .storage:      return "storage"
        case .refrigerator: return "refrigerator"
        case .stove:        return "stove"
        case .bathtub:      return "bathtub"
        case .sink:         return "sink"
        case .toilet:       return "toilet"
        case .bed:          return "bed"
        case .stairs:       return "stairs"
        default:            return "unknown"
        }
    }
}
