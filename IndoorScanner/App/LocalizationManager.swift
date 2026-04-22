import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case sinhala = "si"
    case tamil = "ta"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .sinhala: return "සිංහල"
        case .tamil: return "தமிழ்"
        }
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "app.language") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "app.language")
        self.language = AppLanguage(rawValue: saved ?? "") ?? .english
    }

    func t(_ key: String) -> String {
        translations[key]?[language] ?? translations[key]?[.english] ?? key
    }

    private let translations: [String: [AppLanguage: String]] = [
        "my_scans": [.english: "My Scans", .sinhala: "මගේ ස්කෑන්", .tamil: "என் ஸ்கான்கள்"],
        "indoor_scanner": [.english: "Indoor Scanner", .sinhala: "ඇතුළත ස්කෑනර්", .tamil: "உள் ஸ்கேனர்"],
        "tagline": [.english: "Scan rooms to generate NavMesh-ready 3D models", .sinhala: "NavMesh සඳහා සූදානම් 3D ආකෘති සෑදීමට කාමර ස්කෑන් කරන්න", .tamil: "NavMesh-க்கு தயார் 3D மாதிரிகளை உருவாக்க அறைகளை ஸ்கேன் செய்யுங்கள்"],
        "project_name": [.english: "Project Name", .sinhala: "ව්‍යාපෘති නම", .tamil: "திட்டப் பெயர்"],
        "enter_project_name": [.english: "Enter project name", .sinhala: "ව්‍යාපෘති නම ඇතුල් කරන්න", .tamil: "திட்டப் பெயரை உள்ளிடவும்"],
        "scan_location_qr": [.english: "Scan Location QR Code", .sinhala: "ස්ථානයේ QR කේතය ස්කෑන් කරන්න", .tamil: "இடத்தின் QR குறியீட்டை ஸ்கேன் செய்யவும்"],
        "quick_scan": [.english: "Quick Scan (no QR)", .sinhala: "ක්ෂණික ස්කෑන් (QR නැතිව)", .tamil: "விரைவு ஸ்கேன் (QR இல்லை)"],
        "qr_physical_size": [.english: "QR physical size:", .sinhala: "QR භෞතික ප්‍රමාණය:", .tamil: "QR இயற்பரிமாணம்:"],
        "untitled_project": [.english: "Untitled Project", .sinhala: "නම නොදුන් ව්‍යාපෘතිය", .tamil: "பெயரற்ற திட்டம்"],
        "language": [.english: "Language", .sinhala: "භාෂාව", .tamil: "மொழி"],
        "processing_scan": [.english: "Processing scan…", .sinhala: "ස්කෑන් සැකසෙමින්…", .tamil: "ஸ்கேன் செயலாக்கம்…"],
        "build_clean_model": [.english: "Building clean 3D model", .sinhala: "පිරිසිදු 3D ආකෘතිය තනයි", .tamil: "சுத்தமான 3D மாதிரி உருவாக்கப்படுகிறது"],
        "merge_rooms": [.english: "Merging rooms…", .sinhala: "කාමර ඒකාබද්ධ කරමින්…", .tamil: "அறைகள் ஒன்றிணைக்கப்படுகிறது…"],
        "flatten_floor": [.english: "Flattening floor…", .sinhala: "බිම සමාන කරමින්…", .tamil: "தரை சமப்படுத்தப்படுகிறது…"],
        "gen_obstacles": [.english: "Generating obstacles…", .sinhala: "බාධක සාදමින්…", .tamil: "தடைகள் உருவாக்கப்படுகிறது…"],
        "compute_waypoints": [.english: "Computing waypoints…", .sinhala: "මාර්ග ලක්ෂ ගණනය කරමින්…", .tamil: "வழிநெடுப் புள்ளிகள் கணக்கிடப்படுகிறது…"],
        "saving_library": [.english: "Saving to library…", .sinhala: "පුස්තකාලයට සුරකිමින්…", .tamil: "நூலகத்தில் சேமிக்கப்படுகிறது…"],
        "render_preview": [.english: "Rendering preview…", .sinhala: "පෙරදසුන තනමින්…", .tamil: "முன்னோட்டம் உருவாக்கப்படுகிறது…"],
        "something_wrong": [.english: "Something went wrong", .sinhala: "යම් දෝෂයක් ඇතිවුණා", .tamil: "ஏதோ தவறு ஏற்பட்டது"],
        "start_over": [.english: "Start Over", .sinhala: "නැවත ආරම්භ කරන්න", .tamil: "மீண்டும் தொடங்கு"],
        "scan_incomplete": [.english: "Scan Incomplete", .sinhala: "ස්කෑන් අසම්පූර්ණයි", .tamil: "ஸ்கேன் முழுமையில்லை"],
        "continue_scanning": [.english: "Continue Scanning", .sinhala: "ස්කෑන් කරගෙන යන්න", .tamil: "ஸ்கேன் தொடரவும்"],
        "cancel": [.english: "Cancel", .sinhala: "අවලංගු කරන්න", .tamil: "ரத்து செய்"],
        "preview": [.english: "Preview", .sinhala: "පෙරදසුන", .tamil: "முன்னோட்டம்"],
        "export": [.english: "Export", .sinhala: "අපනයනය", .tamil: "ஏற்றுமதி"],
        "add_next_room": [.english: "Add Next Room", .sinhala: "ඊළඟ කාමරය එක් කරන්න", .tamil: "அடுத்த அறையை சேர்க்கவும்"],
        "rooms_captured": [.english: "room(s) captured", .sinhala: "කාමර සටහන් වී ඇත", .tamil: "அறை(கள்) பதிவு செய்யப்பட்டது"],
        "cancel_scan": [.english: "Cancel Scan", .sinhala: "ස්කෑන් අවලංගු කරන්න", .tamil: "ஸ்கேன் ரத்து செய்"],
        "saved_scans": [.english: "Saved Scans", .sinhala: "සුරකින ලද ස්කෑන්", .tamil: "சேமிக்கப்பட்ட ஸ்கான்கள்"],
        "close": [.english: "Close", .sinhala: "වසන්න", .tamil: "மூடு"],
        "no_saved_scans": [.english: "No Saved Scans", .sinhala: "සුරකින ලද ස්කෑන් නැත", .tamil: "சேமித்த ஸ்கான்கள் இல்லை"],
        "preview_3d_model": [.english: "Preview 3D Model", .sinhala: "3D ආකෘතිය පෙරදසුන", .tamil: "3D மாதிரி முன்னோட்டம்"],
        "done": [.english: "Done", .sinhala: "අවසන්", .tamil: "முடிந்தது"],
        "back": [.english: "Back", .sinhala: "ආපසු", .tamil: "பின்செல்"],
        "export_bundle": [.english: "Export Bundle", .sinhala: "අපනයන පැකේජය", .tamil: "ஏற்றுமதி தொகுப்பு"],
        "export_summary": [.english: "Export Summary", .sinhala: "අපනයන සාරාංශය", .tamil: "ஏற்றுமதி சுருக்கம்"],
        "bundle_contents": [.english: "Bundle Contents", .sinhala: "පැකේජ අන්තර්ගතය", .tamil: "தொகுப்பு உள்ளடக்கம்"],
        "export_formats": [.english: "Export Formats", .sinhala: "අපනයන ආකෘති", .tamil: "ஏற்றுமதி வடிவங்கள்"],
        "transfer": [.english: "Transfer", .sinhala: "මාරු කිරීම", .tamil: "மாற்று"],
        "share_airdrop": [.english: "Share / AirDrop", .sinhala: "බෙදාගන්න / AirDrop", .tamil: "பகிர் / AirDrop"],
        "save_to_files": [.english: "Save to Files", .sinhala: "Files වෙත සුරකින්න", .tamil: "Files-ல் சேமி"]
    ]
}

