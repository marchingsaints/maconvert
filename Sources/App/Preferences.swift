import AppKit
import ServiceManagement

/// App-wide settings (the per-format choices live with ConvertModel).
enum Preferences {
    enum SaveLocation: String, CaseIterable, Identifiable {
        case beside, folder, ask
        var id: String { rawValue }
        var title: String {
            switch self {
            case .beside: "Next to the original"
            case .folder: "In a chosen folder"
            case .ask: "Ask every time"
            }
        }
    }

    static var saveLocation: SaveLocation {
        get { UserDefaults.standard.string(forKey: "saveLocation").flatMap(SaveLocation.init) ?? .beside }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "saveLocation") }
    }

    static var saveFolder: URL {
        get {
            UserDefaults.standard.string(forKey: "saveFolder").map(URL.init(fileURLWithPath:))
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Converted")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "saveFolder") }
    }

    static var revealWhenDone: Bool {
        get { UserDefaults.standard.bool(forKey: "revealWhenDone") }
        set { UserDefaults.standard.set(newValue, forKey: "revealWhenDone") }
    }

    static var showInMenuBar: Bool {
        get { UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showInMenuBar") }
    }

    static var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    /// Where this job's files go, asking first if that's the setting. Nil means "cancelled".
    @MainActor
    static func outputFolder() -> URL?? {
        switch saveLocation {
        case .beside:
            return .some(nil)
        case .folder:
            try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            return .some(saveFolder)
        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose where to save the converted files"
            NSApp.activate(ignoringOtherApps: true)
            return panel.runModal() == .OK ? .some(panel.url) : nil
        }
    }

    /// Forgets the options remembered per format (quality, sizes…), back to defaults.
    static func resetRememberedOptions() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("settings.") || key.hasPrefix("lastFormat.") || key.hasPrefix("lastPreset.") {
            d.removeObject(forKey: key)
        }
    }
}
