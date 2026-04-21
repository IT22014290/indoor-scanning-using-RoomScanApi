import Foundation
import RoomPlan
import simd

protocol RoomScanSessionDelegate: AnyObject {
    func roomScanSession(_ session: RoomScanSession, didUpdate room: CapturedRoom)
    func roomScanSession(_ session: RoomScanSession, didFinalizeRoom room: CapturedRoom)
    func roomScanSession(_ session: RoomScanSession, didFail error: Error)
    func roomScanSession(_ session: RoomScanSession, didProvide instruction: RoomCaptureSession.Instruction)
}

@MainActor
final class RoomScanSession: NSObject, ObservableObject {

    @Published var isScanning        = false
    @Published var isProcessingRoom  = false
    @Published var currentRoom:  CapturedRoom?
    @Published var finalRoom:    CapturedRoom?
    @Published var currentInstruction: RoomCaptureSession.Instruction = .normal
    @Published var scanProgress: Double = 0.0
    @Published var captureDidEndCount: Int = 0

    weak var delegate: RoomScanSessionDelegate?
    private(set) var captureSession: RoomCaptureSession?

    private var lastWallCount   = 0
    private var lastObjectCount = 0

    func attach(to captureView: RoomCaptureView) {
        captureSession           = captureView.captureSession
        captureSession?.delegate = self
    }

    func start() {
        finalRoom        = nil
        isProcessingRoom = false
        captureDidEndCount = 0
        let config       = RoomCaptureSession.Configuration()
        captureSession?.run(configuration: config)
        isScanning   = true
        scanProgress = 0
    }

    func stop() {
        if #available(iOS 17.0, *) {
            captureSession?.stop(pauseARSession: false)
        } else {
            captureSession?.stop()
        }
        isScanning = false
    }

    // MARK: - Private

    private func estimateProgress(from room: CapturedRoom) -> Double {
        let walls   = room.walls.count
        let objects = room.objects.count
        let floors: Int
        if #available(iOS 17.0, *) { floors = room.floors.count } else { floors = walls > 2 ? 1 : 0 }

        if floors == 0 { return min(scanProgress + 0.01, 0.15) }

        let newGeometry = walls > lastWallCount || objects > lastObjectCount
        lastWallCount   = walls
        lastObjectCount = objects

        let base     = min(Double(walls)   / 8.0,  0.6)
        let objBonus = min(Double(objects) / 10.0, 0.3)
        let target   = min(base + objBonus + (newGeometry ? 0 : 0.05), 0.95)
        return max(scanProgress, target)
    }
}

// MARK: - RoomCaptureSessionDelegate

extension RoomScanSession: RoomCaptureSessionDelegate {

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didAdd room: CapturedRoom) {
        Task { @MainActor in
            self.currentRoom  = room
            self.scanProgress = self.estimateProgress(from: room)
            self.delegate?.roomScanSession(self, didUpdate: room)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didChange room: CapturedRoom) {
        Task { @MainActor in
            self.currentRoom  = room
            self.scanProgress = self.estimateProgress(from: room)
            self.delegate?.roomScanSession(self, didUpdate: room)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didRemove room: CapturedRoom) {}

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didEndWith data: CapturedRoomData,
                                    error: (any Error)?) {
        Task { @MainActor in
            self.isScanning       = false
            self.captureDidEndCount += 1
            if let error {
                self.isProcessingRoom = false
                self.delegate?.roomScanSession(self, didFail: error)
                return
            }
            self.isProcessingRoom = true
            self.scanProgress = 1.0

            // Build a final CapturedRoom from end-of-session data for a stable preview/export.
            let processedRoom: CapturedRoom?
            if #available(iOS 16.0, *) {
                let builder = RoomBuilder(options: [.beautifyObjects])
                processedRoom = try? await builder.capturedRoom(from: data)
            } else {
                processedRoom = nil
            }

            self.isProcessingRoom = false
            if let room = processedRoom ?? self.currentRoom {
                self.finalRoom = room
                self.currentRoom = room
                self.delegate?.roomScanSession(self, didFinalizeRoom: room)
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in
            self.currentInstruction = instruction
            self.delegate?.roomScanSession(self, didProvide: instruction)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didStartWith configuration: RoomCaptureSession.Configuration) {}
}

// MARK: - Instruction display text

extension RoomCaptureSession.Instruction {
    var displayText: String {
        switch self {
        case .normal:           return "Move slowly around the room"
        case .moveCloseToWall:  return "Move closer to the walls"
        case .moveAwayFromWall: return "Move away from the wall"
        case .slowDown:         return "Slow down"
        case .turnOnLight:      return "Turn on the lights"
        case .lowTexture:       return "Move to a more textured area"
        default:                return "Continue scanning"
        }
    }
}
