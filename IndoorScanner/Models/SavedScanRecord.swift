import Foundation

/// Persisted metadata for one completed scan.
struct SavedScanRecord: Identifiable, Codable {
    let id: UUID
    var locationUUID: String
    var locationName: String
    var scanDate: Date
    var floorAreaM2: Double
    var roomCount: Int
    var triangleCount: Int
    var bundleFileName: String       // zip filename inside the scan's folder
    var thumbnailFileName: String?   // png filename inside the scan's folder
    var usdzFileName: String?        // RoomPlan USDZ filename inside the scan's folder

    init(id: UUID = UUID(),
         locationUUID: String,
         locationName: String,
         scanDate: Date = Date(),
         floorAreaM2: Double,
         roomCount: Int,
         triangleCount: Int,
         bundleFileName: String,
         thumbnailFileName: String? = "thumbnail.png",
         usdzFileName: String? = nil) {
        self.id                = id
        self.locationUUID      = locationUUID
        self.locationName      = locationName
        self.scanDate          = scanDate
        self.floorAreaM2       = floorAreaM2
        self.roomCount         = roomCount
        self.triangleCount     = triangleCount
        self.bundleFileName    = bundleFileName
        self.thumbnailFileName = thumbnailFileName
        self.usdzFileName      = usdzFileName
    }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: scanDate)
    }

    var formattedArea: String {
        String(format: "%.1f m²", floorAreaM2)
    }
}
