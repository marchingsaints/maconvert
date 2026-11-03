import AppKit
import SwiftUI

struct SettingsView: View {
    let showOnboarding: () -> Void

    @State private var location = Preferences.saveLocation
    @State private var folder = Preferences.saveFolder
    @State private var reveal = Preferences.revealWhenDone
    @State private var menuBar = Preferences.showInMenuBar
    @State private var login = Preferences.openAtLogin
    @State private var finderOn = false
    @State private var resetDone = false
    @State private var autoUpdate = true

    var body: some View {
        Form {
            Section {
                Picker("Save converted files", selection: $location) {
                    ForEach(Preferences.SaveLocation.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: location) { Preferences.saveLocation = $0 }
                if location == .folder {
                    LabeledContent("Folder") {
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 16, height: 16)
                            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }
                Toggle("Show in Finder when done", isOn: $reveal)
                    .onChange(of: reveal) { Preferences.revealWhenDone = $0 }
            } header: {
                Text("Saving")
            } footer: {
                Text("Files never overwrite each other: a clash becomes “photo 2.jpg”.").font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at login", isOn: $login)
                    .onChange(of: login) { Preferences.openAtLogin = $0; login = Preferences.openAtLogin }
                Toggle("Show in menu bar", isOn: $menuBar)
                    .onChange(of: menuBar) { Preferences.showInMenuBar = $0 }
                if !menuBar {
                    Text("To get back here, open MacConvert from Applications or Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { Updater.shared.automaticChecks = $0 }
                LabeledContent("Remembered options") {
                    Button(resetDone ? "Reset ✓" : "Reset") {
                        Preferences.resetRememberedOptions()
                        resetDone = true
                    }
                    .disabled(resetDone)
                }
            }

            Section("Finder") {
                LabeledContent {
                    if finderOn {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Turn On…", action: showOnboarding)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Right-click menu")
                        Text("Convert, Optimize, Compress and Combine on files in Finder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            FinderIntegration.check { finderOn = $0 }
            login = Preferences.openAtLogin
        }
        .onAppear { FinderIntegration.check { finderOn = $0 }; autoUpdate = Updater.shared.automaticChecks }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        Preferences.saveFolder = url
    }
}
