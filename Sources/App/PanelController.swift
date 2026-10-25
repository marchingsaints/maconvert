import Cocoa
import SwiftUI

/// A compact floating panel that opens under the cursor, like a popover with no anchor.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var model: ConvertModel?

    func show(files: [URL], mode: Handoff.Mode, format: OutputFormat?) {
        guard !files.isEmpty else { return }
        panel?.close()

        let model = ConvertModel(files: files, mode: mode, format: format)
        self.model?.isPresented = false
        self.model = model
        let host = NSHostingController(rootView: ConvertView(model: model, close: { [weak self] in self?.dismiss() }))
        host.sizingOptions = .preferredContentSize

        let panel = FloatingPanel(contentViewController: host)
        panel.delegate = self
        model.onBusyChange = { [weak panel] in panel?.isBusy = $0 }
        self.panel = panel

        panel.layoutIfNeeded()
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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

    /// Just below and centred on the pointer, kept fully on screen.
    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 14
        x = min(max(x, bounds.minX), bounds.maxX - size.width)
        y = min(max(y, bounds.minY), bounds.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}

final class FloatingPanel: NSPanel {
    /// Set while converting so a stray click elsewhere doesn't hide progress.
    var isBusy = false

    init(contentViewController: NSViewController) {
        super.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .closable], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .clear
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
}
