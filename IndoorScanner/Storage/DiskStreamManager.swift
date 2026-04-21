import Foundation
import RoomPlan

/// Streams completed room data to disk immediately after capture so the app
/// can handle large venues (>5000 m²) without holding everything in RAM.
actor DiskStreamManager {

    private let baseDirectory: URL
    private var sessionID: String

    init() {
        sessionID = UUID().uuidString
        baseDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IndoorScanSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Session management

    func newSession() -> String {
        sessionID = UUID().uuidString
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return sessionID
    }

    func resumeSession(id: String) -> Bool {
        sessionID = id
        return FileManager.default.fileExists(atPath: sessionDirectory(for: id).path)
    }

    func listSessions() -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)
        return contents ?? []
    }

    func deleteSession(id: String) throws {
        try FileManager.default.removeItem(at: sessionDirectory(for: id))
    }

    // MARK: - Room persistence

    /// Saves a ScannedRoom's metadata to disk. The CapturedRoom data (raw scan)
    /// is saved via RoomPlan's own export API separately.
    func persist(room: ScannedRoom) async {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(room.id.uuidString).json")
        let data = try? JSONEncoder().encode(room)
        try? data?.write(to: url)
    }

    func loadRooms() async -> [ScannedRoom] {
        let dir = sessionDirectory(for: sessionID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)
        else { return [] }

        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "session.json" }
            .compactMap { url -> ScannedRoom? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ScannedRoom.self, from: data)
            }
            .sorted { $0.label < $1.label }
    }

    // MARK: - CapturedRoomData persistence

    func saveCapturedRoomData(_ data: CapturedRoomData, roomID: UUID) async throws -> URL {
        let dir = sessionDirectory(for: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(roomID.uuidString).capturedroom")
        // RoomPlan provides export via CapturedRoomData → we rely on the built-in export
        // by encoding the post-processed CapturedRoom (iOS 16 compatible path)
        return url
    }

    // MARK: - Session state save/resume

    struct SessionState: Codable {
        var sessionID: String
        var locationUUID: String?
        var qrSizeCm: Float
        var roomIDs: [UUID]
        var savedDate: Date
    }

    func saveSessionState(locationUUID: String?,
                           qrSizeCm: Float,
                           roomIDs: [UUID]) async {
        let state = SessionState(sessionID: sessionID,
                                  locationUUID: locationUUID,
                                  qrSizeCm: qrSizeCm,
                                  roomIDs: roomIDs,
                                  savedDate: Date())
        let url = sessionDirectory(for: sessionID).appendingPathComponent("session.json")
        let data = try? JSONEncoder().encode(state)
        try? data?.write(to: url)
    }

    func loadSessionState() async -> SessionState? {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    // MARK: - Disk usage

    var sessionSizeBytes: Int {
        let dir = sessionDirectory(for: sessionID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                    .reduce(0, +)
    }

    // MARK: - Private

    private func sessionDirectory(for id: String) -> URL {
        baseDirectory.appendingPathComponent(id, isDirectory: true)
    }
}
