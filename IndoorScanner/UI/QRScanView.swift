import SwiftUI
import ARKit
import RealityKit

/// Presents a live AR camera view and detects the location QR code using Vision.
/// Once detected, transitions to scanning phase.
struct QRScanView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var calibrator = QROriginCalibrator()

    var body: some View {
        ZStack {
            QRARViewRepresentable(calibrator: calibrator)
                .ignoresSafeArea()

            VStack {
                Text("Scan Location QR Code")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 60)

                Spacer()

                // Viewfinder overlay
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 240, height: 240)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.3))
                    )

                Spacer()

                if calibrator.isCalibrated {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("QR detected — \(calibrator.detectedPayload ?? "")")
                            .foregroundColor(.white)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }

                Button("Cancel") { appState.phase = .idle }
                    .foregroundColor(.white)
                    .padding(.bottom, 40)
            }
        }
        .onChange(of: calibrator.isCalibrated) { calibrated in
            guard calibrated,
                  let payload = calibrator.detectedPayload else { return }
            appState.qrPayload = payload
            let currentName = appState.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentName.isEmpty || currentName == "Unknown Location" || currentName.hasPrefix("Location ") {
                appState.locationName = "Location \(payload.prefix(8))…"
            }
            // Brief delay to show the ✓ confirmation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                appState.phase = .scanning
            }
        }
        .onAppear { calibrator.qrPhysicalSizeCm = appState.qrSizeCm }
    }
}

// MARK: - ARView wrapper that pipes frames to QROriginCalibrator

struct QRARViewRepresentable: UIViewRepresentable {
    let calibrator: QROriginCalibrator

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        arView.session.run(config)
        arView.session.delegate = context.coordinator
        calibrator.attach(to: arView.session)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(calibrator: calibrator) }

    final class Coordinator: NSObject, ARSessionDelegate {
        let calibrator: QROriginCalibrator
        private var frameCounter = 0

        init(calibrator: QROriginCalibrator) {
            self.calibrator = calibrator
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            frameCounter += 1
            // Process every 6th frame (~5fps) to avoid overloading Vision
            guard frameCounter % 6 == 0 else { return }
            Task { @MainActor in
                self.calibrator.processFrame(frame)
            }
        }
    }
}
