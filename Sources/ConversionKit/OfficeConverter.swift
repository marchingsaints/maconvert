import AppKit
import Foundation

/// Word, Excel, PowerPoint, Pages, Keynote and Numbers documents → PDF, by asking the
/// app that made them to export. The result is exactly what File ▸ Export would give.
enum OfficeConverter {
    enum Family { case text, slides, sheet }

    struct Engine {
        let name: String
        let bundleID: String
        let script: (_ src: String, _ dst: String) -> String
    }

    static func family(of url: URL) -> Family? {
        switch url.pathExtension.lowercased() {
        case "doc", "docx", "rtf", "odt", "pages", "dotx": .text
        case "ppt", "pptx", "key", "odp", "pps", "ppsx": .slides
        case "xls", "xlsx", "numbers", "ods", "xlsm": .sheet
        default: nil
        }
    }

    /// iWork files need iWork; for the rest, Microsoft Office renders Office files most faithfully.
    static func engine(for url: URL) -> Engine? {
        guard let family = family(of: url) else { return nil }
        let iWorkOnly = ["pages", "key", "numbers"].contains(url.pathExtension.lowercased())
        let candidates: [Engine] = switch family {
        case .text: (iWorkOnly ? [] : [word]) + [pages]
        case .slides: (iWorkOnly ? [] : [powerPoint]) + [keynote]
        case .sheet: (iWorkOnly ? [] : [excel]) + [numbers]
        }
        return candidates.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static func convert(_ src: URL, to dst: URL, cancel: CancelFlag) async throws {
        guard let engine = engine(for: src) else {
            throw ConversionError.missingTool(family(of: src) == .slides ? "PowerPoint or Keynote" : family(of: src) == .sheet ? "Excel or Numbers" : "Word or Pages")
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: engine.bundleID).isEmpty
        defer {
            // Leave things as we found them: quit the app if we launched it.
            if !wasRunning { _ = try? AppleScript.run("tell application id \"\(engine.bundleID)\" to quit saving no") }
        }
        if cancel.isSet { throw CancellationError() }
        _ = try AppleScript.run(engine.script(src.path, dst.path), timeout: 300)
        guard FileManager.default.fileExists(atPath: dst.path) else {
            throw ConversionError.toolFailed(engine.name, "it didn't save a PDF")
        }
    }

    // MARK: Engines

    private static let word = Engine(name: "Microsoft Word", bundleID: "com.microsoft.Word") { src, dst in """
        tell application id "com.microsoft.Word"
            set theDoc to open file name (POSIX file "\(src.appleScriptEscaped)" as text) with read only
            save as theDoc file name (POSIX file "\(dst.appleScriptEscaped)" as text) file format format PDF
            close theDoc saving no
        end tell
        """ }

    private static let excel = Engine(name: "Microsoft Excel", bundleID: "com.microsoft.Excel") { src, dst in """
        tell application id "com.microsoft.Excel"
            open workbook workbook file name "\(src.appleScriptEscaped)"
            set theBook to active workbook
            save workbook as theBook filename "\(dst.appleScriptEscaped)" file format PDF file format
            close active workbook saving no
        end tell
        """ }

    private static let powerPoint = Engine(name: "Microsoft PowerPoint", bundleID: "com.microsoft.Powerpoint") { src, dst in """
        tell application id "com.microsoft.Powerpoint"
            open (POSIX file "\(src.appleScriptEscaped)")
            set theDeck to active presentation
            save theDeck in (POSIX file "\(dst.appleScriptEscaped)") as save as PDF
            close theDeck saving no
        end tell
        """ }

    private static func iWork(_ name: String, _ bundleID: String) -> Engine {
        // Opening an Office file in iWork imports it, and the reference `open` returns can be
        // a placeholder until that finishes, so wait for the document and use it.
        Engine(name: name, bundleID: bundleID) { src, dst in """
            tell application id "\(bundleID)"
                set startCount to count of documents
                open (POSIX file "\(src.appleScriptEscaped)")
                repeat 150 times
                    if (count of documents) > startCount then exit repeat
                    delay 0.2
                end repeat
                set theDoc to front document
                export theDoc to (POSIX file "\(dst.appleScriptEscaped)") as PDF
                close theDoc saving no
            end tell
            """ }
    }

    private static let pages = iWork("Pages", "com.apple.iWork.Pages")
    private static let keynote = iWork("Keynote", "com.apple.iWork.Keynote")
    private static let numbers = iWork("Numbers", "com.apple.iWork.Numbers")
}

enum AppleScript {
    /// Runs a script through osascript, so macOS attributes the automation request to this app.
    @discardableResult
    static func run(_ source: String, timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "with timeout of \(Int(timeout)) seconds", "-e", source, "-e", "end timeout"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            // -1743: the user hasn't allowed this app to control the other one.
            if stderr.contains("-1743") { throw ConversionError.toolFailed("macOS", "MacConvert isn't allowed to control that app. Allow it in System Settings ▸ Privacy & Security ▸ Automation.") }
            throw ConversionError.toolFailed("AppleScript", stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private extension String {
    var appleScriptEscaped: String { replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}
