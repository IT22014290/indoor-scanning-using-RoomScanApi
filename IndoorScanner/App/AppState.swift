import SwiftUI
import Combine
import RoomPlan
import simd

enum AppPhase: Equatable {
    case idle
    case qrScanning
    case scanning
    case processing
    case preview
    case exporting
    case error(String)
}

@MainActor
class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var qrPayload: String?
    @Published var qrSizeCm: Float = 20.0
    // QR-based global origin in ARKit/RoomPlan world space
    @Published var qrWorldTransform: simd_float4x4 = matrix_identity_float4x4
    @Published var qrForwardVector: simd_float3 = simd_float3(0, 0, -1)
    @Published var qrOriginLockedAt: Date?
    @Published var locationName: String = "Unknown Location"
    @Published var scanProgress: Double = 0.0
    @Published var processingProgress: Double = 0.0
    @Published var roomCount: Int = 0
    @Published var triangleCount: Int = 0
    @Published var aisleCount: Int = 0
    @Published var exportURL: URL?
    @Published var exportDirectoryURL: URL?
    @Published var exportOBJURL: URL?
    @Published var exportJSONURL: URL?
    @Published var exportPNGURL: URL?
    @Published var exportUSDZURL: URL?
    @Published var currentInstruction: String = ""
    @Published var scannedRooms: [ScannedRoom] = []
    @Published var activeRoomID: UUID?
    @Published var totalFloorArea: Double = 0.0

    @Published var savedRecord: SavedScanRecord?
    @Published var saveError: String?
    @Published var previewUsdzURL: URL?             // USDZ from CapturedRoom.encode — exact RoomPlan rendering

    let diskStreamManager = DiskStreamManager()
    let multiRoomStitcher = MultiRoomStitcher()
    let scanLibrary = ScanLibraryManager()

    func addCompletedRoom(_ room: ScannedRoom) {
        scannedRooms.append(room)
        roomCount = scannedRooms.count
        totalFloorArea = scannedRooms.reduce(0) { $0 + $1.floorAreaM2 }
        Task { await diskStreamManager.persist(room: room) }
    }

    func reset() {
        phase = .idle
        qrPayload = nil
        scannedRooms = []
        roomCount = 0
        triangleCount = 0
        aisleCount = 0
        exportURL = nil
        exportDirectoryURL = nil
        exportOBJURL = nil
        exportJSONURL = nil
        exportPNGURL = nil
        exportUSDZURL = nil
        totalFloorArea = 0
        scanProgress = 0
        processingProgress = 0
        savedRecord = nil
        saveError = nil
        previewUsdzURL = nil
        qrWorldTransform = matrix_identity_float4x4
        qrForwardVector = simd_float3(0, 0, -1)
        qrOriginLockedAt = nil
        multiRoomStitcher.reset()
    }
}
