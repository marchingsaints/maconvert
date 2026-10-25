import AppKit
import UserNotifications

/// Tracks conversions app-wide, so a job keeps going (and reports back) after its panel closes.
@MainActor
final class JobCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = JobCenter()

    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var progress: Double = 0
    }

    @Published private(set) var jobs: [Job] = []
    /// Most recent outputs first.
    @Published private(set) var recent: [URL] = (UserDefaults.standard.stringArray(forKey: "recentOutputs") ?? []).map(URL.init(fileURLWithPath:))

    /// Overall progress of everything running, for the menu bar.
    var overallProgress: Double? {
        jobs.isEmpty ? nil : jobs.map(\.progress).reduce(0, +) / Double(jobs.count)
    }

    func start(_ title: String) -> UUID {
        let job = Job(title: title)
        jobs.append(job)
        return job.id
    }

    func update(_ id: UUID, progress: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].progress = progress
    }

    func cancelled(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    /// Records the outputs; if nobody is looking at the panel any more, says so with a notification.
    func finish(_ id: UUID, written: [URL], headline: String, detail: String?, panelVisible: Bool) {
        jobs.removeAll { $0.id == id }
        remember(written)
        if Preferences.revealWhenDone, !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
        guard !panelVisible else { return }
        notify(title: headline, body: detail ?? "", paths: written.map(\.path))
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: "recentOutputs")
    }

    private func remember(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var list = urls + recent.filter { !urls.contains($0) }
        list = Array(list.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(8))
        recent = list
        UserDefaults.standard.set(list.map(\.path), forKey: "recentOutputs")
    }

    // MARK: Notifications

    private func notify(title: String, body: String, paths: [String]) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["paths": paths]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Clicking the notification shows the new files.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        Task { @MainActor in
            let urls = paths.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
