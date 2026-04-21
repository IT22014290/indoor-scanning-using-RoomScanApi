import Foundation
import UIKit

/// Manages the on-device library of completed scans.
/// Each scan lives in Documents/SavedScans/<uuid>/
///   record.json      — SavedScanRecord metadata
///   bundle.zip       — full export bundle (OBJ + JSON + PNG)
///   thumbnail.png    — top-down preview image (copied from bundle)
@MainActor
final class ScanLibraryManager: ObservableObject {

    @Published private(set) var records: [SavedScanRecord] = []

    private let root: URL

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SavedScans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Save

    /// Copies the export zip into the library folder, extracts thumbnail, and persists metadata.
    func save(bundleURL: URL,
              locationUUID: String,
              locationName: String,
              floorAreaM2: Double,
              roomCount: Int,
              triangleCount: Int,
              thumbnail: UIImage?,
              usdzURL: URL?) async throws -> SavedScanRecord {

        let id         = UUID()
        let scanDir    = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)

        // Copy zip bundle
        let bundleDest = scanDir.appendingPathComponent("bundle.zip")
        try FileManager.default.copyItem(at: bundleURL, to: bundleDest)

        // Save thumbnail
        var thumbName: String? = nil
        if let img = thumbnail, let png = img.pngData() {
            let thumbURL = scanDir.appendingPathComponent("thumbnail.png")
            try png.write(to: thumbURL)
            thumbName = "thumbnail.png"
        }

        // Save RoomPlan USDZ preview if available
        var usdzName: String? = nil
        if let usdzURL, FileManager.default.fileExists(atPath: usdzURL.path) {
            let dest = scanDir.appendingPathComponent("preview.usdz")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: usdzURL, to: dest)
            usdzName = "preview.usdz"
        }

        let record = SavedScanRecord(
            id: id,
            locationUUID: locationUUID,
            locationName: locationName,
            floorAreaM2: floorAreaM2,
            roomCount: roomCount,
            triangleCount: triangleCount,
            bundleFileName: "bundle.zip",
            thumbnailFileName: thumbName,
            usdzFileName: usdzName
        )

        let data = try JSONEncoder().encode(record)
        try data.write(to: scanDir.appendingPathComponent("record.json"))

        records.insert(record, at: 0)
        return record
    }

    // MARK: - Delete

    func delete(_ record: SavedScanRecord) {
        let scanDir = root.appendingPathComponent(record.id.uuidString)
        try? FileManager.default.removeItem(at: scanDir)
        records.removeAll { $0.id == record.id }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets { delete(records[index]) }
    }

    // MARK: - URL helpers

    func bundleURL(for record: SavedScanRecord) -> URL {
        root.appendingPathComponent(record.id.uuidString)
            .appendingPathComponent(record.bundleFileName)
    }

    func thumbnailURL(for record: SavedScanRecord) -> URL? {
        guard let name = record.thumbnailFileName else { return nil }
        return root.appendingPathComponent(record.id.uuidString).appendingPathComponent(name)
    }

    func thumbnailImage(for record: SavedScanRecord) -> UIImage? {
        guard let url = thumbnailURL(for: record),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func usdzURL(for record: SavedScanRecord) -> URL? {
        guard let name = record.usdzFileName else { return nil }
        return root.appendingPathComponent(record.id.uuidString).appendingPathComponent(name)
    }

    // MARK: - Load from disk

    func load() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        var loaded = [SavedScanRecord]()
        for dir in contents {
            let recordURL = dir.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(SavedScanRecord.self, from: data)
            else { continue }
            loaded.append(record)
        }
        records = loaded.sorted { $0.scanDate > $1.scanDate }
    }
}
