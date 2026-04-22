import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var i18n: LocalizationManager
    @State private var showLanguageSheet = false

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
        .overlay(alignment: .topLeading) {
            Button {
                showLanguageSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text(i18n.language.displayName)
                        .font(.caption)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
            .padding(.top, 56)
            .padding(.leading, 16)
        }
        .sheet(isPresented: $showLanguageSheet) {
            NavigationStack {
                List(AppLanguage.allCases) { lang in
                    Button {
                        i18n.language = lang
                    } label: {
                        HStack {
                            Text(lang.displayName)
                            Spacer()
                            if i18n.language == lang {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                .navigationTitle(i18n.t("language"))
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Idle screen

struct IdleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var i18n: LocalizationManager
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
                        Text(i18n.t("my_scans"))
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
                Text(i18n.t("indoor_scanner"))
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                Text(i18n.t("tagline"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            Spacer()

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(i18n.t("project_name"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(i18n.t("enter_project_name"), text: $projectName)
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
                    Label(i18n.t("scan_location_qr"), systemImage: "qrcode.viewfinder")
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
                    Label(i18n.t("quick_scan"), systemImage: "camera.viewfinder")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                HStack {
                    Text(i18n.t("qr_physical_size"))
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
        return trimmed.isEmpty ? i18n.t("untitled_project") : trimmed
    }
}

// MARK: - Processing view

struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var i18n: LocalizationManager

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
        if p < 0.2  { return i18n.t("merge_rooms") }
        if p < 0.4  { return i18n.t("flatten_floor") }
        if p < 0.6  { return i18n.t("gen_obstacles") }
        if p < 0.75 { return i18n.t("compute_waypoints") }
        if p < 0.9  { return i18n.t("saving_library") }
        return i18n.t("render_preview")
    }
}

// MARK: - Error view

struct ErrorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var i18n: LocalizationManager
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text(i18n.t("something_wrong"))
                .font(.title2.bold())
                .foregroundColor(.white)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(i18n.t("start_over")) { appState.reset() }
                .buttonStyle(.borderedProminent)
                .tint(.white)
        }
    }
}
