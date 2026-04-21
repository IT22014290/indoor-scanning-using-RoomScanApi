import SwiftUI
import RoomPlan
import ARKit

/// Main scanning screen: RoomPlan capture view + HUD overlay.
struct ScanningView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var scanSession = RoomScanSession()
    @StateObject private var meshSupplementor = ARMeshSupplementor()
    @State private var showAddRoomConfirm = false
    @State private var showQualityAlert = false
    @State private var roomLabel = ""

    // Pending action set when user taps stop — executed once RoomBuilder finishes
    @State private var pendingAddNextRoom = false
    @State private var pendingPreviewScan = false
    @State private var pendingExportScan  = false
    
    private func exportDebug(_ message: String) {
        NSLog("EXPORT_DEBUG %@", message)
    }

    var body: some View {
        ZStack {
            RoomPlanCaptureViewRepresentable(scanSession: scanSession, meshSupplementor: meshSupplementor)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomBar
            }

            // RoomBuilder processing overlay
            if scanSession.isProcessingRoom {
                processingOverlay
            }
        }
        .onAppear { scanSession.start() }
        .onDisappear {
            if scanSession.isScanning { scanSession.stop() }
        }
        .onChange(of: scanSession.currentInstruction) { instruction in
            appState.currentInstruction = instruction.displayText
        }
        .onChange(of: scanSession.scanProgress) { p in
            appState.scanProgress = p
        }
        // Capture-end is the reliable event after stop().
        .onChange(of: scanSession.captureDidEndCount) { _ in
            if pendingAddNextRoom {
                pendingAddNextRoom = false
                commitCurrentRoomAndContinue()
            } else if pendingPreviewScan {
                pendingPreviewScan = false
                commitCurrentRoomAndPreview()
            } else if pendingExportScan {
                pendingExportScan = false
                commitCurrentRoomAndExport()
            }
        }
        // React when RoomBuilder finishes — this is where we commit the room
        .onChange(of: scanSession.isProcessingRoom) { isProcessing in
            guard !isProcessing else { return }
            if pendingAddNextRoom {
                pendingAddNextRoom = false
                commitCurrentRoomAndContinue()
            } else if pendingPreviewScan {
                pendingPreviewScan = false
                commitCurrentRoomAndPreview()
            } else if pendingExportScan {
                pendingExportScan = false
                commitCurrentRoomAndExport()
            }
        }
        .alert("Save Room", isPresented: $showAddRoomConfirm) {
            TextField("Room label (e.g. Main Hall)", text: $roomLabel)
            Button("Save & Add Next") { triggerAddNextRoom() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name this area before starting the next room.")
        }
        .alert("Scan Incomplete", isPresented: $showQualityAlert) {
            Button("Continue Scanning") { scanSession.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The captured model is too sparse for accurate preview/export. Scan walls and floor again from multiple angles, then process.")
        }
    }

    // MARK: - Processing overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                    .tint(.white)
                Text("Processing scan…")
                    .foregroundColor(.white)
                    .font(.subheadline)
                Text("Building clean 3D model")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - HUD

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.locationName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(appState.roomCount) room(s) captured")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.0f%%", appState.scanProgress * 100))
                    .font(.title2.monospacedDigit().bold())
                    .foregroundColor(.white)
                Text(appState.currentInstruction)
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal)
        .padding(.top, 60)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if !appState.currentInstruction.isEmpty {
                Text(appState.currentInstruction)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }

            HStack(spacing: 16) {
                Button { showAddRoomConfirm = true } label: {
                    Label("Add Next Room", systemImage: "plus.circle")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .disabled(scanSession.isProcessingRoom)

                Spacer()

                Button { triggerPreviewScan() } label: {
                    Text("Preview")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .disabled(scanSession.isProcessingRoom)

                Button { triggerExportScan() } label: {
                    Text("Export")
                        .font(.headline)
                        .foregroundColor(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .disabled(scanSession.isProcessingRoom)
            }

            Button("Cancel Scan") {
                scanSession.stop()
                appState.reset()
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 48)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom))
    }

    // MARK: - Trigger actions (stop scan → wait for RoomBuilder)

    private func triggerAddNextRoom() {
        pendingAddNextRoom = true
        scanSession.stop()   // fires didEndWith → RoomBuilder → isProcessingRoom = false
    }

    private func triggerPreviewScan() {
        exportDebug("Button tapped: Preview")
        if scanSession.isScanning {
            pendingPreviewScan = true
            scanSession.stop()
        } else {
            commitCurrentRoomAndPreview()
        }
    }

    private func triggerExportScan() {
        exportDebug("Button tapped: Export")
        if scanSession.isScanning {
            pendingExportScan = true
            scanSession.stop()
        } else {
            commitCurrentRoomAndExport()
        }
    }

    // MARK: - Commit actions (called after RoomBuilder completes)

    /// Commits the just-finished room and restarts scanning for the next one.
    private func commitCurrentRoomAndContinue() {
        guard let room = scanSession.finalRoom else {
            scanSession.start()
            return
        }
        let label = roomLabel.isEmpty ? "Room \(appState.roomCount + 1)" : roomLabel
        addRoomToState(room, label: label)
        roomLabel = ""
        scanSession.start()
    }

    /// Commits the just-finished room then runs post-processing + export.
    private func commitCurrentRoomAndExport() {
        guard let room = scanSession.finalRoom else {
            exportDebug("No finalRoom available after stop; returning to scan")
            showQualityAlert = true
            return
        }
        let label = roomLabel.isEmpty ? "Room \(appState.roomCount + 1)" : roomLabel
        addRoomToState(room, label: label)
        runExport()
    }

    /// Commits the just-finished room and opens model preview without running export/save.
    private func commitCurrentRoomAndPreview() {
        guard let room = scanSession.finalRoom else {
            exportDebug("No finalRoom available for preview; returning to scan")
            showQualityAlert = true
            return
        }
        let label = roomLabel.isEmpty ? "Room \(appState.roomCount + 1)" : roomLabel
        addRoomToState(room, label: label)

        let usdzURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview_\(UUID().uuidString).usdz")
        do {
            try room.export(to: usdzURL)
            appState.previewUsdzURL = usdzURL
            appState.phase = .preview
        } catch {
            appState.phase = .error("RoomPlan USDZ preview failed: \(error.localizedDescription)")
        }
    }

    private func addRoomToState(_ room: CapturedRoom, label: String) {
        let scannedRoom = ScannedRoom(
            label: label,
            floorAreaM2: room.floorAreaM2,
            objectCount: room.objects.count,
            qrRelativeTransform: matrix_identity_float4x4
        )
        appState.addCompletedRoom(scannedRoom)
        appState.multiRoomStitcher.addRoom(room,
                                            label: label,
                                            qrRelativeTransform: matrix_identity_float4x4)
    }

    private func runExport() {
        appState.phase = .processing
        Task { await runPostProcessing() }
    }

    private func runPostProcessing() async {
        exportDebug("✅ Step 1: Start post-processing")
        let stitcher = appState.multiRoomStitcher
        let stepLabels = ["Merging rooms", "Flattening floor", "Generating obstacles",
                          "Computing waypoints", "Decimating mesh", "Rendering preview"]
        for (i, _) in stepLabels.enumerated() {
            await MainActor.run { appState.processingProgress = Double(i) / Double(stepLabels.count) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Encode rooms to USDZ using RoomPlan's own encoder — preserves exact visual style
        exportDebug("✅ Step 2: Merging rooms")
        let mergedGeo = stitcher.buildMergedGeometry()

        // ARKit mesh supplement (LiDAR) for irregular obstacles
        exportDebug("✅ Step 2b: Extracting ARKit mesh obstacles")
        let raw = meshSupplementor.extractObstacleFaces(excludingBounds: mergedGeo.bounds)
        let supplementalMesh: MeshPostProcessor.ProcessedMesh? = {
            guard !raw.isEmpty else { return nil }
            // Merge all raw chunks into one mesh
            var combinedVerts = [simd_float3]()
            var combinedIdx = [UInt32]()
            var base: UInt32 = 0
            for chunk in raw {
                combinedVerts.append(contentsOf: chunk.vertices)
                combinedIdx.append(contentsOf: chunk.indices.map { $0 + base })
                base += UInt32(chunk.vertices.count)
            }
            let m = MeshPostProcessor.ProcessedMesh(vertices: combinedVerts, indices: combinedIdx)
            return MeshPostProcessor.decimate(m, targetTriangles: 150_000, mergeTolerance: 0.01)
        }()

        exportDebug("✅ Step 3: Generating waypoints")
        let waypointGraph = WaypointGenerator.generate(
            floorBounds: mergedGeo.bounds,
            obstacles: mergedGeo.objects,
            walls: mergedGeo.walls
        )

        exportDebug("✅ Step 4: Exporting USDZ")
        let usdzURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview_\(UUID().uuidString).usdz")
        let roomToExport = stitcher.rooms.count == 1
            ? stitcher.rooms.first?.capturedRoom
            : stitcher.rooms.last?.capturedRoom
        if let room = roomToExport {
            do {
                try room.export(to: usdzURL)
                await MainActor.run { appState.previewUsdzURL = usdzURL }
                exportDebug("USDZ export success: \(usdzURL.lastPathComponent)")
            } catch {
                exportDebug("USDZ export failed: \(error.localizedDescription)")
                await MainActor.run { appState.phase = .error("RoomPlan USDZ export failed: \(error.localizedDescription)") }
                return
            }
        } else {
            exportDebug("USDZ skipped: no room available to export")
            await MainActor.run { appState.phase = .error("No final RoomPlan room available for USDZ export.") }
            return
        }

        let computedFloorArea = mergedGeo.floors.reduce(0.0) {
            $0 + Double($1.dimensions.x * $1.dimensions.z)
        }
        let thumbnail = ExportValidator.renderThumbnail(geometry: mergedGeo)

        let input = OBJExporter.ExportInput(
            locationUUID: appState.qrPayload ?? "unknown",
            qrSizeCm: appState.qrSizeCm,
            rooms: stitcher.rooms,
            mergedGeometry: mergedGeo,
            waypointGraph: waypointGraph,
            thumbnailImage: thumbnail,
            previewUsdzURL: appState.previewUsdzURL,
            supplementalObstacleMesh: supplementalMesh
        )

        do {
            exportDebug("✅ Step 5: Exporting OBJ bundle")
            let result = try OBJExporter.export(input)
            await MainActor.run {
                appState.exportURL          = result.bundleURL
                appState.exportDirectoryURL = result.bundleDirectoryURL
                appState.exportOBJURL       = result.floorObjURL
                appState.exportJSONURL      = result.metadataJsonURL
                appState.exportPNGURL       = result.thumbnailPngURL
                appState.exportUSDZURL      = result.usdzURL
                appState.aisleCount         = mergedGeo.aisles.count
                appState.triangleCount      = result.triangleCount
            }

            await MainActor.run {
                appState.phase = .exporting
                if computedFloorArea > 0 {
                    appState.totalFloorArea = computedFloorArea
                }
            }

            // Auto-save to library (non-blocking for preview/export success)
            do {
                exportDebug("✅ Step 7: Saving to library")
                let record = try await appState.scanLibrary.save(
                    bundleURL: result.bundleURL,
                    locationUUID: appState.qrPayload ?? "unknown",
                    locationName: appState.locationName,
                    floorAreaM2: computedFloorArea > 0 ? computedFloorArea : appState.totalFloorArea,
                    roomCount: appState.roomCount,
                    triangleCount: result.triangleCount,
                    thumbnail: input.thumbnailImage,
                    usdzURL: result.usdzURL
                )
                await MainActor.run {
                    appState.savedRecord = record
                    appState.saveError = nil
                }
            } catch {
                await MainActor.run {
                    appState.saveError = "Export created, but saving to My Scans failed: \(error.localizedDescription)"
                }
                exportDebug("Save to library failed: \(error.localizedDescription)")
            }
            exportDebug("✅ Step 8: Switching to preview")
        } catch {
            exportDebug("❌ Export pipeline failed: \(error.localizedDescription)")
            await MainActor.run { appState.phase = .error(error.localizedDescription) }
        }
    }
}

// MARK: - RoomCaptureView wrapper

struct RoomPlanCaptureViewRepresentable: UIViewRepresentable {
    @ObservedObject var scanSession: RoomScanSession
    let meshSupplementor: ARMeshSupplementor

    func makeUIView(context: Context) -> RoomCaptureView {
        let captureView = RoomCaptureView(frame: .zero)
        scanSession.attach(to: captureView)
        // Attach LiDAR mesh capture to RoomPlan's underlying ARSession when available.
        meshSupplementor.attach(to: captureView.captureSession.arSession)
        return captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
