import Cocoa
import FinderSync
import os

private let log = Logger(subsystem: "com.judedias.MacConvert.FinderExtension", category: "menu")

/// Adds "Convert to ▸" and "Optimize for Web" / "Compress Video" to Finder's right-click menu.
/// It does no work itself: it builds the menu and hands the selection to the app.
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Watch the whole disk (and mounted volumes) so the menu appears everywhere.
        var roots = [URL(fileURLWithPath: "/")]
        if let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            roots += volumes
        }
        FIFinderSyncController.default().directoryURLs = Set(roots)
        log.info("Started, watching \(roots.count) roots")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let files = selectedFiles()
        let targets = FormatCatalog.conversionTargets(for: files)
        log.info("Menu requested: \(files.count) convertible files, \(targets.count) targets")
        let combineTitle = FormatCatalog.combineTitle(for: files)
        let kind = FormatCatalog.sharedKind(of: files)
        guard (!targets.isEmpty && kind != nil) || combineTitle != nil else { return nil }

        let menu = NSMenu(title: "")
        if let kind, !targets.isEmpty { addConvertItems(to: menu, kind: kind, targets: targets) }
        if let combineTitle {
            let combine = NSMenuItem(title: combineTitle, action: #selector(combine(_:)), keyEquivalent: "")
            menu.addItem(combine)
        }
        return menu
    }

    private func addConvertItems(to menu: NSMenu, kind: MediaKind, targets: [OutputFormat]) {
        let convert = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Convert to")
        for (i, format) in targets.enumerated() {
            // From a video, audio formats mean "keep just the soundtrack"; from a PDF, images sit between documents and text.
            if i > 0, (kind == .video && format.kind == .audio && targets[i - 1].kind != .audio) || format == .txt
                || (kind == .pdf && format.kind == .image && targets[i - 1].kind != .image) {
                sub.addItem(.separator())
            }
            let title = kind == .video && format.kind == .audio ? "\(format.displayName) (audio only)" : format.displayName
            let item = NSMenuItem(title: title, action: #selector(convert(_:)), keyEquivalent: "")
            // Finder copies menu items, so only the tag survives the trip back.
            item.tag = OutputFormat.allCases.firstIndex(of: format)!
            sub.addItem(item)
        }
        convert.submenu = sub
        menu.addItem(convert)

        if let title = FormatCatalog.optimizeTitle(for: kind) {
            let optimize = NSMenuItem(title: title, action: #selector(optimize(_:)), keyEquivalent: "")
            menu.addItem(optimize)
        }
    }

    @objc func convert(_ sender: NSMenuItem) {
        let format = OutputFormat.allCases.indices.contains(sender.tag) ? OutputFormat.allCases[sender.tag] : nil
        handOff(.convert, format: format)
    }

    @objc func optimize(_ sender: NSMenuItem) {
        handOff(.optimize, format: nil)
    }

    @objc func combine(_ sender: NSMenuItem) {
        handOff(.combine, format: .pdf)
    }

    private func selectedFiles() -> [URL] {
        (FIFinderSyncController.default().selectedItemURLs() ?? []).filter(FormatCatalog.isConvertible)
    }

    private func handOff(_ mode: Handoff.Mode, format: OutputFormat?) {
        guard let url = Handoff.url(mode: mode, format: format, files: selectedFiles()) else { return }
        NSWorkspace.shared.open(url)
    }
}
