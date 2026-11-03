import AppKit
import Sparkle

/// Checks the appcast named in Info.plist (SUFeedURL) for newer versions and installs them.
/// Updates are signed with the EdDSA key whose public half is SUPublicEDKey.
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Finder keeps running the old extension after the app is replaced, so the right-click menu
    /// would vanish until Finder restarts. The first launch of a new build restarts it once.
    static func refreshFinderAfterUpdate() {
        let key = "lastRunBuild"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        guard let previous, previous != current else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["Finder"]
            try? p.run()
        }
    }
}
