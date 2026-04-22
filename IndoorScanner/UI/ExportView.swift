import SwiftUI

/// Export management sheet: shows bundle info, share options, upload actions.
struct ExportView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var i18n: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []

    var body: some View {
        NavigationStack {
            List {
                // Saved confirmation banner
                if appState.savedRecord != nil {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i18n.t("my_scans"))
                                    .font(.headline)
                                Text("Access it anytime from the home screen")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let saveError = appState.saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }

                Section(i18n.t("export_summary")) {
                    LabeledContent("Location", value: appState.locationName)
                    LabeledContent("UUID", value: String((appState.qrPayload ?? "—").prefix(24)))
                    LabeledContent("Rooms scanned", value: "\(appState.roomCount)")
                    LabeledContent("Aisles detected", value: "\(appState.aisleCount)")
                    LabeledContent("Total floor area",
                                   value: String(format: "%.1f m²", appState.totalFloorArea))
                    LabeledContent("Triangle count", value: appState.triangleCount.formatted())
                }

                Section(i18n.t("bundle_contents")) {
                    fileRow(name: "floor.obj",       desc: "Walkable floor surface")
                    fileRow(name: "obstacles.obj",   desc: "Walls + furniture boxes")
                    fileRow(name: "combined.obj",    desc: "Floor + obstacles merged")
                    fileRow(name: "materials.mtl",   desc: "OBJ colors/materials")
                    fileRow(name: "metadata.json",   desc: "Location + coordinate data")
                    fileRow(name: "waypoints.json",  desc: "Navigation waypoint graph")
                    fileRow(name: "preview.usdz",    desc: "Exact RoomPlan USDZ output")
                    fileRow(name: "thumbnail.png",   desc: "Top-down preview image")
                }

                Section(i18n.t("export_formats")) {
                    if let objURL = appState.exportOBJURL {
                        Button {
                            shareItems = [objURL]
                            showShareSheet = true
                        } label: {
                            Label("Export OBJ", systemImage: "cube")
                        }
                    }

                    if let jsonURL = appState.exportJSONURL {
                        Button {
                            shareItems = [jsonURL]
                            showShareSheet = true
                        } label: {
                            Label("Export JSON", systemImage: "curlybraces")
                        }
                    }
                    
                    if let pngURL = appState.exportPNGURL {
                        Button {
                            shareItems = [pngURL]
                            showShareSheet = true
                        } label: {
                            Label("Export PNG", systemImage: "photo")
                        }
                    }

                    if let usdzURL = appState.exportUSDZURL {
                        Button {
                            shareItems = [usdzURL]
                            showShareSheet = true
                        } label: {
                            Label("Export USDZ", systemImage: "shippingbox")
                        }
                    } else {
                        Label("USDZ unavailable for this scan", systemImage: "exclamationmark.circle")
                            .foregroundColor(.secondary)
                    }
                }

                Section(i18n.t("transfer")) {
                    // Prefer the library bundle URL so it persists after reset
                    let shareURL = appState.savedRecord.map {
                        appState.scanLibrary.bundleURL(for: $0)
                    } ?? appState.exportURL

                    if let url = shareURL {
                        Button {
                            shareItems = [url]
                            showShareSheet = true
                        } label: {
                            Label(i18n.t("share_airdrop"), systemImage: "square.and.arrow.up")
                        }

                        Button { saveToFiles(url: url) } label: {
                            Label(i18n.t("save_to_files"), systemImage: "folder.badge.plus")
                        }
                    } else {
                        Label("Export bundle not ready", systemImage: "exclamationmark.circle")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(i18n.t("export_bundle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(i18n.t("done")) {
                        dismiss()
                        appState.phase = .idle
                        appState.reset()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(i18n.t("back")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
    }

    private func fileRow(name: String, desc: String) -> some View {
        HStack {
            Image(systemName: "doc")
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.monospaced())
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func saveToFiles(url: URL) {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            root.present(picker, animated: true)
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
