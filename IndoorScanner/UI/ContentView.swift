import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch appState.phase {
            case .idle:
                IdleView()
            case .qrScanning:
                QRScanView()
            case .scanning:
                ScanningView()
            case .processing:
                ProcessingView()
            case .preview:
                ModelPreviewView()
            case .exporting:
                ExportView()
            case .error(let msg):
                ErrorView(message: msg)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.phase)
    }
}

// MARK: - Idle screen

struct IdleView: View {
    @EnvironmentObject var appState: AppState
    @State private var showLibrary = false
    @State private var projectName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with library button
            HStack {
                Spacer()
                Button {
                    showLibrary = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                        Text("My Scans")
                            .fontWeight(.medium)
                        if appState.scanLibrary.records.count > 0 {
                            Text("\(appState.scanLibrary.records.count)")
                                .font(.caption2.bold())
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white)
                                .clipShape(Capsule())
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)

            Spacer()

            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.white)

            VStack(spacing: 8) {
                Text("Indoor Scanner")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                Text("Scan rooms to generate NavMesh-ready 3D models")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            Spacer()

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Enter project name", text: $projectName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    appState.locationName = resolvedProjectName
                    appState.phase = .qrScanning
                } label: {
                    Label("Scan Location QR Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                // Skip QR — scan directly (for testing)
                Button {
                    appState.qrPayload = "test-\(UUID().uuidString)"
                    appState.locationName = resolvedProjectName
                    appState.phase = .scanning
                } label: {
                    Label("Quick Scan (no QR)", systemImage: "camera.viewfinder")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                HStack {
                    Text("QR physical size:")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                    Spacer()
                    Text("\(Int(appState.qrSizeCm)) cm")
                        .foregroundColor(.white)
                        .font(.footnote.monospacedDigit())
                    Stepper("", value: $appState.qrSizeCm, in: 5...50, step: 5)
                        .labelsHidden()
                        .tint(.white)
                }
                .padding(.horizontal)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .sheet(isPresented: $showLibrary) {
            ScanLibraryView(library: appState.scanLibrary)
                .environmentObject(appState)
        }
        .onAppear {
            if projectName.isEmpty {
                projectName = appState.locationName == "Unknown Location" ? "" : appState.locationName
            }
        }
    }
    
    private var resolvedProjectName: String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Project" : trimmed
    }
}

// MARK: - Processing view

struct ProcessingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundColor(.white)

            ProgressView(value: appState.processingProgress)
                .tint(.white)
                .padding(.horizontal, 40)

            Text(processingLabel)
                .foregroundColor(.secondary)
                .font(.subheadline)

            Spacer()
        }
    }

    private var processingLabel: String {
        let p = appState.processingProgress
        if p < 0.2  { return "Merging rooms…" }
        if p < 0.4  { return "Flattening floor…" }
        if p < 0.6  { return "Generating obstacles…" }
        if p < 0.75 { return "Computing waypoints…" }
        if p < 0.9  { return "Saving to library…" }
        return "Rendering preview…"
    }
}

// MARK: - Error view

struct ErrorView: View {
    @EnvironmentObject var appState: AppState
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text("Something went wrong")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Start Over") { appState.reset() }
                .buttonStyle(.borderedProminent)
                .tint(.white)
        }
    }
}
