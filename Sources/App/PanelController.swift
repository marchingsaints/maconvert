import Cocoa
import SwiftUI

/// A compact dialog that opens in the middle of the screen, with a title bar and a close button.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var model: ConvertModel?
    /// Once you drag the dialog somewhere, it stays there instead of re-centring as it changes size.
    private var movedByUser = false

    func show(files: [URL], mode: Handoff.Mode, format: OutputFormat?) {
        guard !files.isEmpty else { return }
        panel?.close()

        let model = ConvertModel(files: files, mode: mode, format: format)
        self.model?.isPresented = false
        self.model = model
        let host = NSHostingController(rootView: ConvertView(model: model, close: { [weak self] in self?.dismiss() }))
        host.sizingOptions = .preferredContentSize

        let panel = FloatingPanel(contentViewController: host)
        panel.title = model.windowTitle
        panel.delegate = self
        model.onBusyChange = { [weak panel] in panel?.isBusy = $0 }
        self.panel = panel
        movedByUser = false

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Centre only once the window has its final size (title bar included), still invisible.
        panel.layoutIfNeeded()
        center(panel)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, !self.movedByUser else { return }
            self.center(panel)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        // A running job keeps going after this and reports back through JobCenter.
        model?.isPresented = false
        model = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.close() })
    }

    /// Clicking back into Finder dismisses the panel, like a menu would. A conversion in
    /// progress carries on in the background.
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? FloatingPanel, window === panel else { return }
        // Choosing a folder ("Ask every time") briefly takes focus; that isn't clicking away.
        if NSApp.modalWindow != nil || model?.isChoosingFolder == true { return }
        dismiss()
    }

    /// The close button closes the dialog like clicking away does; a job keeps running.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? FloatingPanel, window === panel else { return }
        panel = nil
        model?.isPresented = false
        model = nil
    }

    /// Sent when you start dragging the dialog (not when it moves because its size changed).
    func windowWillMove(_ notification: Notification) {
        movedByUser = true
    }

    /// The dialog's height changes with its options (and while it converts); keep it centred
    /// unless you've moved it yourself.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? FloatingPanel, window === panel, !movedByUser, window.isVisible else { return }
        center(window)
    }

    /// The exact middle of the screen the pointer is on (where you right-clicked).
    private func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
    }
}

final class FloatingPanel: NSPanel {
    /// Set while converting so a stray click elsewhere doesn't hide progress.
    var isBusy = false

    init(contentViewController: NSViewController) {
        super.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .closable], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        // A real title bar (title text and a close button), blended into the panel's material.
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        isMovableByWindowBackground = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .clear
        // Only the close button: nothing to minimise or zoom in a small dialog.
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
}
