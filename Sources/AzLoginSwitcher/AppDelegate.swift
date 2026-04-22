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
        let urlOpener = DefaultURLOpener()
        let loginLauncher = TerminalLoginLauncher()
        
        let appState = AppState(
            azCLI: azCLI,
            pimService: pimService,
            urlOpener: urlOpener,
            loginLauncher: loginLauncher
        )
        
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 350, height: 400)
        popover.contentViewController = NSHostingController(rootView: MainView(appState: appState))
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
