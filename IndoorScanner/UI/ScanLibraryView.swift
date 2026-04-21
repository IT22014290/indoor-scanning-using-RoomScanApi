import SwiftUI
import QuickLook

/// Browse, share, and delete all saved scans.
struct ScanLibraryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var library: ScanLibraryManager
    @State private var selectedRecord: SavedScanRecord?
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if library.records.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(library.records) { record in
                            ScanRowView(record: record, library: library)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRecord = record }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        library.delete(record)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Saved Scans")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .disabled(library.records.isEmpty)
                }
            }
            .sheet(item: $selectedRecord) { record in
                ScanDetailView(record: record, library: library)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("No Saved Scans")
                .font(.title2.bold())
            Text("Complete a room scan to save your first 3D model here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Row

struct ScanRowView: View {
    let record: SavedScanRecord
    let library: ScanLibraryManager

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail
            Group {
                if let img = library.thumbnailImage(for: record) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 72, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.locationName)
                    .font(.headline)
                    .lineLimit(1)
                Text(record.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Label(record.formattedArea, systemImage: "square.dashed")
                    Label("\(record.roomCount) room(s)", systemImage: "door.left.hand.open")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail sheet

struct ScanDetailView: View {
    let record: SavedScanRecord
    let library: ScanLibraryManager
    @State private var showShareSheet = false
    @State private var showModelPreview = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Thumbnail header
                if let img = library.thumbnailImage(for: record) {
                    Section {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                }

                Section("Details") {
                    LabeledContent("Location", value: record.locationName)
                    LabeledContent("UUID", value: String(record.locationUUID.prefix(20)) + "…")
                    LabeledContent("Scanned", value: record.formattedDate)
                    LabeledContent("Floor area", value: record.formattedArea)
                    LabeledContent("Rooms", value: "\(record.roomCount)")
                    LabeledContent("Triangles", value: record.triangleCount.formatted())
                }

                Section("Export Bundle") {
                    fileRow("floor.obj",       "Walkable floor mesh")
                    fileRow("obstacles.obj",   "Walls + furniture")
                    fileRow("combined.obj",    "Merged mesh")
                    fileRow("metadata.json",   "Location + coordinates")
                    fileRow("waypoints.json",  "Navigation graph")
                    fileRow("preview.usdz",    "RoomPlan 3D model preview")
                    fileRow("thumbnail.png",   "Preview image")
                }

                Section {
                    if library.usdzURL(for: record) != nil {
                        Button {
                            showModelPreview = true
                        } label: {
                            Label("Preview 3D Model", systemImage: "view.3d")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share / AirDrop Bundle", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .sheet(isPresented: $showShareSheet) {
                        ShareSheet(items: [library.bundleURL(for: record)])
                    }

                    Button {
                        saveToFiles()
                    } label: {
                        Label("Save to Files", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        library.delete(record)
                        dismiss()
                    } label: {
                        Label("Delete Scan", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(record.locationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showModelPreview) {
                if let url = library.usdzURL(for: record) {
                    ModelPreviewSheet(url: url)
                }
            }
        }
    }

    private func fileRow(_ name: String, _ description: String) -> some View {
        HStack {
            Image(systemName: "doc")
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.monospaced())
                Text(description).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func saveToFiles() {
        let url = library.bundleURL(for: record)
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            root.present(picker, animated: true)
        }
    }
}

struct ModelPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickLookPreview(url: url)
                .ignoresSafeArea()
                .navigationTitle("3D Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { dismiss() }
                    }
                }
        }
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let itemURL: URL

        init(url: URL) {
            self.itemURL = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            itemURL as NSURL
        }
    }
}
