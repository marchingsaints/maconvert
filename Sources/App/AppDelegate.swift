import Cocoa
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let panel = PanelController()
    private var onboarding: NSWindow?
    private var settingsWindow: NSWindow?
    private var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateStatusItem()
        _ = Updater.shared
        Updater.refreshFinderAfterUpdate()
        // Menu bar progress follows running jobs; the icon can be turned off in Settings.
        JobCenter.shared.$jobs.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshProgress() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &observers)

        // pluginkit can be slow on a Mac that has never run the extension, so it is asked off the main thread.
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            showOnboarding()
        } else {
            FinderIntegration.check { [weak self] on in if !on { self?.showOnboarding() } }
        }
    }

    /// Opening the app again (from Applications or Spotlight) shows Settings, which is the
    /// way back in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Finder extension → macconvert://run?… lands here, as do files opened with the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let request = Handoff.parse(url), !request.files.isEmpty {
                panel.show(files: request.files, mode: request.mode, format: request.format)
            } else if url.isFileURL {
                open(files: urls.filter(\.isFileURL))
                return
            }
        }
    }

    /// Files from a drop or "Open With": convert if they're one kind, combine images/PDFs if mixed.
    private func open(files: [URL]) {
        let usable = files.filter(FormatCatalog.isConvertible)
        guard !usable.isEmpty else { NSSound.beep(); return }
        if FormatCatalog.sharedKind(of: usable) != nil {
            panel.show(files: usable, mode: .convert, format: nil)
        } else if FormatCatalog.combineTitle(for: usable) != nil {
            panel.show(files: usable, mode: .combine, format: .pdf)
        } else {
            // A mix of kinds: take the largest group.
            let groups = Dictionary(grouping: usable) { FormatCatalog.kind(of: $0)! }
            panel.show(files: groups.values.max { $0.count < $1.count }!, mode: .convert, format: nil)
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        if !Preferences.showInMenuBar {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "MacConvert: drop files here to convert them"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            let drop = DropTarget(frame: button.bounds) { [weak self] files in self?.open(files: files) }
            drop.autoresizingMask = [.width, .height]
            button.addSubview(drop)
        }
        statusItem = item
        refreshProgress()
    }

    private func refreshProgress() {
        guard let button = statusItem?.button else { return }
        if let progress = JobCenter.shared.overallProgress {
            button.title = " \(Int((progress * 100).rounded()))%"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        } else {
            button.title = ""
        }
    }

    /// Rebuilt each time it opens, so running jobs and Recent are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Convert Files…", action: #selector(pickToConvert), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Optimize or Compress…", action: #selector(pickToOptimize), keyEquivalent: "").target = self

        let jobs = JobCenter.shared.jobs
        if !jobs.isEmpty {
            menu.addItem(.separator())
            for job in jobs {
                let item = NSMenuItem(title: "\(job.title): \(Int((job.progress * 100).rounded()))%", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        let recent = JobCenter.shared.recent.filter { FileManager.default.fileExists(atPath: $0.path) }
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for url in recent {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.toolTip = url.deletingLastPathComponent().path
            sub.addItem(item)
        }
        if recent.isEmpty {
            sub.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            sub.addItem(.separator())
            sub.addItem(withTitle: "Clear Recent", action: #selector(clearRecent), keyEquivalent: "").target = self
        }
        recentItem.submenu = sub
        menu.addItem(.separator())
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About MacConvert", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacConvert", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func clearRecent() { JobCenter.shared.clearRecent() }

    @objc private func pickToConvert() { pick(.convert) }
    @objc private func pickToOptimize() { pick(.optimize) }

    private func pick(_ mode: Handoff.Mode) {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.image, .movie, .audio, .pdf] + ["docx", "doc", "pptx", "ppt", "xlsx", "xls", "pages", "key", "numbers"].compactMap { UTType(filenameExtension: $0) }
        open.prompt = mode == .convert ? "Convert" : "Optimize"
        guard open.runModal() == .OK else { return }
        if mode == .convert { self.open(files: open.urls) } else { panel.show(files: open.urls, mode: mode, format: nil) }
    }

    // MARK: Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MacConvert Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(showOnboarding: { [weak self] in self?.showOnboarding() }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(string: "Converts and optimizes files right from Finder, entirely on your Mac.\n\n",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "Designed and built by Jude Dias\n\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]))
        let notice = """
        Includes open-source software:
        FFmpeg (LGPL 2.1) · LAME (LGPL 2) · mpg123 (LGPL 2.1) · libwebp (BSD) · libvpx (BSD) · Opus (BSD)
        Updates by Sparkle (MIT). Licence texts are in MacConvert.app/Contents/Resources/Licenses.
        """
        credits.append(NSAttributedString(string: notice, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func showOnboarding() {
        if onboarding == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: OnboardingView { [weak window] in
                UserDefaults.standard.set(true, forKey: "onboarded")
                window?.close()
            })
            window.center()
            onboarding = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.makeKeyAndOrderFront(nil)
    }
}

/// Lets files be dropped on the menu bar icon. It sits over the button and hands clicks to it.
final class DropTarget: NSView {
    private let onDrop: ([URL]) -> Void

    init(frame: NSRect, onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks belong to the menu bar button underneath.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    private func files(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = files(sender).contains(where: FormatCatalog.isConvertible)
        (superview as? NSButton)?.highlight(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { (superview as? NSButton)?.highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (superview as? NSButton)?.highlight(false)
        let urls = files(sender)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDrop(urls) }
        return true
    }
}

enum FinderIntegration {
    static var extensionID: String { (Bundle.main.bundleIdentifier ?? "com.judedias.MacConvert") + ".FinderExtension" }

    /// pluginkit lists enabled extensions with a leading "+". It runs off the main thread with a
    /// time limit, so a slow first run can never freeze the app.
    static func check(_ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let on = pluginkit(["-m", "-i", extensionID]).trimmingCharacters(in: .whitespaces).hasPrefix("+")
            Task { @MainActor in done(on) }
        }
    }

    static func enable(_ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = pluginkit(["-e", "use", "-i", extensionID])
            let on = pluginkit(["-m", "-i", extensionID]).trimmingCharacters(in: .whitespaces).hasPrefix("+")
            Task { @MainActor in done(on) }
        }
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }

    private static func pluginkit(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return "" }
        if finished.wait(timeout: .now() + 5) == .timedOut { p.terminate(); return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
