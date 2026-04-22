import SwiftUI

@main
struct IndoorScannerApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var i18n = LocalizationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(i18n)
                .preferredColorScheme(.dark)
        }
    }
}
