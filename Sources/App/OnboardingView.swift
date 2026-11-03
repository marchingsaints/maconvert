import SwiftUI

/// First launch: one switch to flip, then you're done.
struct OnboardingView: View {
    let finish: () -> Void
    @State private var enabled = false
    @State private var triedEnabling = false

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 84, height: 84)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("MacConvert").font(.title.weight(.semibold))
                Text("Right-click any image in Finder to convert or optimize it.\nEverything happens on your Mac, nothing is uploaded.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "puzzlepiece.extension")
                    .font(.title2)
                    .foregroundStyle(enabled ? .green : .accentColor)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(enabled ? "Finder integration is on" : "Turn on Finder integration").font(.headline)
                    Text(enabled ? "Right-click an image to try it." : triedEnabling
                         ? "Tick MacConvert under Added Extensions in System Settings."
                         : "Adds Convert and Optimize to the right-click menu.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                if !enabled && triedEnabling {
                    Button("Open System Settings", action: FinderIntegration.openSystemSettings)
                }
                Spacer()
                if enabled {
                    Button("Done", action: finish).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Turn On", action: turnOn).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 420)
        .background(VisualEffect(material: .windowBackground).ignoresSafeArea())
        .animation(.snappy, value: enabled)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            FinderIntegration.check { enabled = $0 }
        }
        .onAppear { FinderIntegration.check { enabled = $0 } }
    }

    private func turnOn() {
        FinderIntegration.enable { on in
            enabled = on
            if !on {
                triedEnabling = true
                FinderIntegration.openSystemSettings()
            }
        }
    }
}
