import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Az Login Switcher") {
                image.isTemplate = true
                button.image = image
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        let shell = ShellExecutor()
        let azCLI = AzCLI(shell: shell)
        let pimService = PIMService(shell: shell)
        let loginLauncher = TerminalLoginLauncher()
        let logger = ActionLogger()
        
        let runner = ActionRunner(
            azCLI: azCLI,
            pimService: pimService,
            loginLauncher: loginLauncher,
            logger: logger
        )
        
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 500, height: 500)
        popover.contentViewController = NSHostingController(rootView: MainView(runner: runner))
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}
