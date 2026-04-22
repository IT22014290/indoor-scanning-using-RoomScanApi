import Foundation
import RoomPlan
import simd
import UIKit

/// Produces the full zip export bundle:
///   floor.obj, obstacles.obj, combined.obj, metadata.json, waypoints.json, thumbnail.png
struct OBJExporter {

    struct ExportInput {
        var locationUUID: String
        var qrSizeCm: Float
        var qrOriginLockedAt: Date?
        var unityCoordinateReady: Bool
        var rooms: [MultiRoomStitcher.RoomEntry]
        var mergedGeometry: MultiRoomStitcher.MergedGeometry
        var waypointGraph: WaypointGraph
        var thumbnailImage: UIImage?
        var previewUsdzURL: URL?
        var supplementalObstacleMesh: MeshPostProcessor.ProcessedMesh?
    }

    struct ExportResult {
        var bundleURL: URL
        var bundleDirectoryURL: URL
        var floorObjURL: URL
        var obstaclesObjURL: URL
        var metadataJsonURL: URL
        var waypointsJsonURL: URL
        var thumbnailPngURL: URL?
        var usdzURL: URL?
        var triangleCount: Int
        var bounds: BoundingBox3D
    }

    // MARK: - Main export

    static func export(_ input: ExportInput) throws -> ExportResult {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndoorScanExport_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Write MTL so OBJ exports keep distinct colors in viewers.
        let mtlURL = tmp.appendingPathComponent("materials.mtl")
        let mtlText = [
            "# IndoorScanner materials",
            "newmtl floor",
            "Kd 0.55 0.85 0.55",
            "Ka 0.10 0.10 0.10",
            "Ks 0.05 0.05 0.05",
            "Ns 12.0",
            "",
            "newmtl obstacle",
            "Kd 0.90 0.55 0.55",
            "Ka 0.10 0.10 0.10",
            "Ks 0.05 0.05 0.05",
            "Ns 12.0",
            "",
            "newmtl combined",
            "Kd 0.80 0.80 0.85",
            "Ka 0.10 0.10 0.10",
            "Ks 0.05 0.05 0.05",
            "Ns 12.0",
            ""
        ].joined(separator: "\n")
        try mtlText.write(to: mtlURL, atomically: true, encoding: .utf8)

        let geo = input.mergedGeometry
        let dedupWalls = deduplicateWalls(geo.walls)

        // 1. Floor mesh
        let floorMesh = MeshPostProcessor.unifyFloors(from: geo.floors)
        let floorMeshFinal = MeshPostProcessor.decimate(floorMesh, targetTriangles: 100_000)
        let floorObjURL = tmp.appendingPathComponent("floor.obj")
        try writeOBJ(floorMeshFinal, to: floorObjURL,
                     mtl: "floor", comment: "Floor — NavMesh walkable surface")

        // 2. Obstacle mesh
        let obstacleMesh = MeshPostProcessor.buildObstacleMesh(
            walls: dedupWalls, objects: geo.objects)
        let obstacleMerged = MeshPostProcessor.mergeMeshes(
            [obstacleMesh] + (input.supplementalObstacleMesh.map { [$0] } ?? [])
        )
        let obstacleMeshFinal = MeshPostProcessor.decimate(obstacleMerged, targetTriangles: 400_000)
        let obstaclesObjURL = tmp.appendingPathComponent("obstacles.obj")
        try writeOBJ(obstacleMeshFinal, to: obstaclesObjURL,
                     mtl: "obstacle", comment: "Obstacles — NavMesh carving")

        // 3. Combined mesh
        let combined = MeshPostProcessor.mergeMeshes([floorMeshFinal, obstacleMeshFinal])
        let combinedFinal = MeshPostProcessor.decimate(combined, targetTriangles: 500_000)
        try writeOBJ(combinedFinal, to: tmp.appendingPathComponent("combined.obj"),
                     mtl: "combined", comment: "Combined floor + obstacles")

        // 4. Metadata JSON
        let meta = buildMetadata(input: input, bounds: geo.bounds, triCount: combinedFinal.triangleCount)
        let metaData = try JSONEncoder().encode(meta)
        let metadataJsonURL = tmp.appendingPathComponent("metadata.json")
        try metaData.write(to: metadataJsonURL)

        // 5. Waypoints JSON
        let waypointData = try JSONEncoder().encode(input.waypointGraph)
        let waypointsJsonURL = tmp.appendingPathComponent("waypoints.json")
        try waypointData.write(to: waypointsJsonURL)

        // 6. Thumbnail
        var thumbnailPngURL: URL?
        if let img = input.thumbnailImage, let png = img.pngData() {
            let pngURL = tmp.appendingPathComponent("thumbnail.png")
            try png.write(to: pngURL)
            thumbnailPngURL = pngURL
        }

        // 7. Include USDZ preview when available
        var exportedUsdzURL: URL?
        if let previewUsdzURL = input.previewUsdzURL,
           FileManager.default.fileExists(atPath: previewUsdzURL.path) {
            let usdzURL = tmp.appendingPathComponent("preview.usdz")
            try? FileManager.default.removeItem(at: usdzURL)
            try FileManager.default.copyItem(at: previewUsdzURL, to: usdzURL)
            exportedUsdzURL = usdzURL
        }

        // 8. Zip the bundle
        NSLog("EXPORT_DEBUG ✅ Step 6: Zipping bundle")
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndoorScan_\(Date().ISO8601Format()).zip")
        try zipDirectory(tmp, to: zipURL)

        return ExportResult(bundleURL: zipURL,
                            bundleDirectoryURL: tmp,
                            floorObjURL: floorObjURL,
                            obstaclesObjURL: obstaclesObjURL,
                            metadataJsonURL: metadataJsonURL,
                            waypointsJsonURL: waypointsJsonURL,
                            thumbnailPngURL: thumbnailPngURL,
                            usdzURL: exportedUsdzURL,
                            triangleCount: combinedFinal.triangleCount,
                            bounds: geo.bounds)
    }

    // MARK: - OBJ writer

    private static func writeOBJ(_ mesh: MeshPostProcessor.ProcessedMesh,
                                   to url: URL,
                                   mtl: String?,
                                   comment: String) throws {
        var lines = ["# \(comment)", "# IndoorScanner export", "# Coordinate: Y-up, 1 unit = 1 meter", ""]
        lines.append("mtllib materials.mtl")
        if let mtl {
            lines.append("usemtl \(mtl)")
        }
        for v in mesh.vertices {
            lines.append(String(format: "v %.5f %.5f %.5f", v.x, v.y, v.z))
        }
        lines.append("")
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = mesh.indices[i] + 1
            let i1 = mesh.indices[i+1] + 1
            let i2 = mesh.indices[i+2] + 1
            lines.append("f \(i0) \(i1) \(i2)")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Metadata

    private struct MetadataJSON: Encodable {
        var qrPayload: String
        var qrSizeCm: Float
        var scanDate: String
        var coordinateSystem: String
        var units: String
        var scaleToMeters: Float
        var qrOriginPosition: [String: Float]
        var qrOriginRotation: [String: Float]   // quaternion (x,y,z,w)
        var qrForwardVector: [String: Float]    // Unity-facing forward (+Z)
        var qrForwardVectorARKit: [String: Float]
        var handedness: String
        var unityCoordinateReady: Bool
        var originLockedAt: String?
        var origin: [String: Float]
        var bounds: BoundsJSON
        var rooms: [RoomJSON]
        var totalFloorAreaM2: Double
        var totalObjectCount: Int
        var aisleCount: Int
        var cylinderCount: Int
        var scanEngine: String
        var triangleCount: Int

        struct BoundsJSON: Encodable {
            var minX, maxX, minY, maxY, minZ, maxZ: Float
        }
        struct RoomJSON: Encodable {
            var id, label: String
            var floorAreaM2: Double
            var objectCount: Int
        }
    }

    private static func buildMetadata(input: ExportInput,
                                       bounds: BoundingBox3D,
                                       triCount: Int) -> MetadataJSON {
        let formatter = ISO8601DateFormatter()
        let roomsJSON = input.rooms.map {
            MetadataJSON.RoomJSON(
                id: $0.id.uuidString,
                label: $0.label,
                floorAreaM2: $0.capturedRoom.floorAreaM2,
                objectCount: $0.capturedRoom.objects.count
            )
        }
        return MetadataJSON(
            qrPayload: input.locationUUID,
            qrSizeCm: input.qrSizeCm,
            scanDate: formatter.string(from: Date()),
            coordinateSystem: "QR-relative, Y-up, +Z forward (Unity/AR Foundation)",
            units: "meters",
            scaleToMeters: 1.0,
            qrOriginPosition: qrOriginPosition(from: input),
            qrOriginRotation: qrOriginRotationQuat(from: input),
            qrForwardVector: qrForwardVector(from: input),
            qrForwardVectorARKit: qrForwardVectorARKit(from: input),
            handedness: "left-handed (Unity). Source captured in right-handed ARKit.",
            unityCoordinateReady: input.unityCoordinateReady,
            originLockedAt: input.qrOriginLockedAt.map { formatter.string(from: $0) },
            origin: ["x": 0, "y": 0, "z": 0],
            bounds: .init(minX: bounds.minX, maxX: bounds.maxX,
                          minY: bounds.minY, maxY: bounds.maxY,
                          minZ: bounds.minZ, maxZ: bounds.maxZ),
            rooms: roomsJSON,
            totalFloorAreaM2: input.rooms.reduce(0) { $0 + $1.capturedRoom.floorAreaM2 },
            totalObjectCount: input.mergedGeometry.objects.count,
            aisleCount: input.mergedGeometry.aisles.count,
            cylinderCount: input.mergedGeometry.objects.filter { $0.category == "obstacle.cylinder" }.count,
            scanEngine: "RoomPlan+ARKit",
            triangleCount: triCount
        )
    }

    private static func qrOriginPosition(from input: ExportInput) -> [String: Float] {
        // For export, QR is the origin of the aligned coordinate system.
        ["x": 0, "y": 0, "z": 0]
    }

    private static func qrOriginRotationQuat(from input: ExportInput) -> [String: Float] {
        // Since we align everything into QR space (origin inverse applied),
        // the QR rotation becomes identity in exported coordinates.
        ["x": 0, "y": 0, "z": 0, "w": 1]
    }

    private static func qrForwardVector(from input: ExportInput) -> [String: Float] {
        // Unity-facing convention (left-handed): +Z forward.
        ["x": 0, "y": 0, "z": 1]
    }

    private static func qrForwardVectorARKit(from input: ExportInput) -> [String: Float] {
        // ARKit/RoomPlan convention (right-handed): -Z forward.
        ["x": 0, "y": 0, "z": -1]
    }

    private static func deduplicateWalls(
        _ walls: [MultiRoomStitcher.SurfacePrimitive]
    ) -> [MultiRoomStitcher.SurfacePrimitive] {
        var kept = [MultiRoomStitcher.SurfacePrimitive]()
        for candidate in walls {
            let cPos = candidate.transform.translation
            let isDup = kept.contains { existing in
                let dist = simd_distance(cPos, existing.transform.translation)
                let parallel = abs(simd_dot(
                    candidate.transform.normalVector,
                    existing.transform.normalVector
                ))
                return dist < 0.10 && parallel > 0.98
            }
            if !isDup { kept.append(candidate) }
        }
        return kept
    }

    // MARK: - Zip utility

    private static func zipDirectory(_ sourceDir: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var zipError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: sourceDir,
                                options: .forUploading,
                                error: &zipError) { zippedURL in
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }
        if let zipError { throw zipError }
        if let copyError { throw copyError }
        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            throw NSError(
                domain: "IndoorScanner.Export",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create export zip archive."]
            )
        }
    }
}

// MARK: - WaypointGraph Encodable shim for export
extension WaypointGraph {
    struct ExportFormat: Encodable {
        var waypoints: [WPExport]
        var edges: [EdgeExport]

        struct WPExport: Encodable {
            var id, label: String
            var position: [String: Float]
        }
        struct EdgeExport: Encodable {
            var from, to: String
            var distanceM: Float
        }
    }

    var exportFormat: ExportFormat {
        ExportFormat(
            waypoints: waypoints.map {
                .init(id: $0.id, label: $0.label,
                      position: ["x": $0.position.x, "y": $0.position.y, "z": $0.position.z])
            },
            edges: edges.map { .init(from: $0.from, to: $0.to, distanceM: $0.distanceM) }
        )
    }
}

extension JSONEncoder {
    func encode(_ graph: WaypointGraph) throws -> Data {
        try encode(graph.exportFormat)
    }
}
