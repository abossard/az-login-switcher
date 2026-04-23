import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var clickOutsideMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Az Login Switcher") {
                image.isTemplate = true
                button.image = image
            }
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        let shell = ShellExecutor()
        let azCLI = AzCLI(shell: shell)
        let pimService = PIMService(shell: shell)
        let logger = ActionLogger()

        let runner = ActionRunner(
            azCLI: azCLI,
            pimService: pimService,
            logger: logger
        )

        panel = MenuBarPanel(contentView: MainView(runner: runner))
    }

    @objc func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main!
        let screenFrame = screen.visibleFrame

        // Size the panel to fit content, capped at 80% screen height
        let maxHeight = screenFrame.height * 0.8
        panel.setContentSize(NSSize(width: 500, height: min(500, maxHeight)))

        var origin = NSPoint(
            x: buttonRect.midX - panel.frame.width / 2,
            y: buttonRect.minY - panel.frame.height - 4
        )
        // Clamp to screen edges
        origin.x = max(screenFrame.minX + 8,
                       min(origin.x, screenFrame.maxX - panel.frame.width - 8))
        if origin.y < screenFrame.minY + 8 {
            origin.y = buttonRect.maxY + 4
        }

        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)

        // Click-outside-to-close via global monitor
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            // Global monitor: locationInWindow is already in screen coordinates
            let clickLocation = event.locationInWindow
            if let button = self.statusItem.button,
               let buttonWindow = button.window {
                let buttonRect = buttonWindow.convertToScreen(
                    button.convert(button.bounds, to: nil))
                if buttonRect.contains(clickLocation) {
                    return
                }
            }
            self.hidePanel()
        }

        // Local monitor for clicks inside our app but outside the panel
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if event.window === self.statusItem.button?.window { return event }
            self.hidePanel()
            return event
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
