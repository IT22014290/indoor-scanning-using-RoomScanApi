import Foundation
import ARKit
import Vision
import simd

protocol QROriginCalibratorDelegate: AnyObject {
    func calibrator(_ cal: QROriginCalibrator, didDetectQR payload: String,
                    worldTransform: simd_float4x4)
    func calibratorDidLoseTracking(_ cal: QROriginCalibrator)
}

/// Detects a QR code using Vision and estimates its 3D pose via ARKit image tracking.
/// The QR world transform becomes the coordinate origin for all exported geometry.
@MainActor
final class QROriginCalibrator: NSObject, ObservableObject {

    @Published var isCalibrated = false
    @Published var detectedPayload: String?
    @Published var qrWorldTransform: simd_float4x4 = matrix_identity_float4x4

    weak var delegate: QROriginCalibratorDelegate?
    var qrPhysicalSizeCm: Float = 20.0

    private weak var arSession: ARSession?
    private var detectionRequest: VNDetectBarcodesRequest?
    private var referenceImage: ARReferenceImage?
    private var isTracking = false

    // MARK: - Public API

    func attach(to session: ARSession) {
        arSession = session
    }

    /// Process a camera frame to detect the QR code using Vision.
    func processFrame(_ frame: ARFrame) {
        guard !isCalibrated else { return }

        let pixelBuffer = frame.capturedImage
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        let request = VNDetectBarcodesRequest { [weak self] req, _ in
            guard let self,
                  let results = req.results as? [VNBarcodeObservation],
                  let qr = results.first(where: { $0.symbology == .qr }),
                  let payload = qr.payloadStringValue else { return }

            Task { @MainActor in
                await self.handleDetectedQR(payload: payload,
                                            observation: qr,
                                            frame: frame)
            }
        }
        request.symbologies = [.qr]
        try? handler.perform([request])
    }

    // MARK: - Private

    private func handleDetectedQR(payload: String,
                                   observation: VNBarcodeObservation,
                                   frame: ARFrame) async {
        guard !isCalibrated else { return }

        // Estimate QR centre in the image
        let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                               height: CVPixelBufferGetHeight(frame.capturedImage))
        let normCentre = CGPoint(
            x: (observation.boundingBox.minX + observation.boundingBox.maxX) / 2,
            y: (observation.boundingBox.minY + observation.boundingBox.maxY) / 2
        )

        // Ray-cast onto ARPlaneAnchor or estimate from camera intrinsics
        let query = frame.raycastQuery(from: normCentre,
                                       allowing: .existingPlaneGeometry,
                                       alignment: .any)
        let results = arSession?.raycast(query) ?? []

        if let hit = results.first {
            // Build QR-aligned transform: Z = outward normal of the wall/floor
            let hitTransform = hit.worldTransform
            finalizeOrigin(worldTransform: hitTransform, payload: payload)
        } else {
            // Fallback: project onto estimated distance from QR pixel size
            let qrSizeM = qrPhysicalSizeCm / 100.0
            let focalLength = frame.camera.intrinsics[0][0]
            let pixelSize = Float(observation.boundingBox.width) * Float(imageSize.width)
            let estimatedDist = (qrSizeM * focalLength) / max(pixelSize, 1)

            let cameraTransform = frame.camera.transform
            let forwardVec = -simd_float3(cameraTransform.columns.2.x,
                                          cameraTransform.columns.2.y,
                                          cameraTransform.columns.2.z)
            let cameraPos = simd_float3(cameraTransform.columns.3.x,
                                        cameraTransform.columns.3.y,
                                        cameraTransform.columns.3.z)
            let qrPos = cameraPos + forwardVec * estimatedDist

            var t = matrix_identity_float4x4
            t.columns.3 = simd_float4(qrPos.x, qrPos.y, qrPos.z, 1)
            finalizeOrigin(worldTransform: t, payload: payload)
        }
    }

    private func finalizeOrigin(worldTransform: simd_float4x4, payload: String) {
        qrWorldTransform = worldTransform
        detectedPayload = payload
        isCalibrated = true
        delegate?.calibrator(self, didDetectQR: payload, worldTransform: worldTransform)
    }

    /// Converts any world-space transform into QR-relative coordinates.
    func toQRSpace(_ worldTransform: simd_float4x4) -> simd_float4x4 {
        simd_inverse(qrWorldTransform) * worldTransform
    }

    func toQRSpace(_ worldPos: simd_float3) -> simd_float3 {
        let p = simd_inverse(qrWorldTransform) * simd_float4(worldPos.x, worldPos.y, worldPos.z, 1)
        return simd_float3(p.x, p.y, p.z)
    }
}
