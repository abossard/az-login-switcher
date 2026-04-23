import Foundation
import AppKit

/// Pure metadata about an installed browser — NO NSImage (not Sendable)
struct BrowserInfo: Identifiable, Hashable, Sendable {
    let id: String          // bundle identifier (e.g., "com.google.Chrome")
    let name: String        // display name (e.g., "Google Chrome")
    let appURL: URL         // file:///Applications/Google Chrome.app
}

enum BrowserError: Error, LocalizedError {
    case browserNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .browserNotFound(let id): return "Browser not found: \(id)"
        }
    }
}

/// Detects installed browsers and opens URLs in specific browsers.
/// Icons are NOT part of BrowserInfo (NSImage is not Sendable).
/// Views resolve icons via BrowserService.icon(for:) on @MainActor.
struct BrowserService {
    
    /// Preferred browsers to show (in order). Only these are displayed.
    private static let preferredBrowserIds: [String] = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
    ]

    /// Installed browsers from the preferred list, in preferred order
    @MainActor
    static func installedBrowsers() -> [BrowserInfo] {
        let httpsURL = URL(string: "https://example.com")!
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: httpsURL)
        
        let all = appURLs.compactMap { appURL -> BrowserInfo? in
            guard let bundle = Bundle(url: appURL),
                  let bundleID = bundle.bundleIdentifier else { return nil }
            
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                     ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                     ?? appURL.deletingPathExtension().lastPathComponent
            
            return BrowserInfo(id: bundleID, name: name, appURL: appURL)
        }
        
        // Return only preferred browsers, in preferred order
        return preferredBrowserIds.compactMap { prefId in
            all.first { $0.id == prefId }
        }
    }
    
    /// The user's default browser
    @MainActor
    static func defaultBrowser() -> BrowserInfo? {
        let httpsURL = URL(string: "https://example.com")!
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL),
              let bundle = Bundle(url: appURL),
              let bundleID = bundle.bundleIdentifier else { return nil }
        
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                 ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                 ?? appURL.deletingPathExtension().lastPathComponent
        
        return BrowserInfo(id: bundleID, name: name, appURL: appURL)
    }
    
    /// Open URL in a specific browser
    @MainActor
    static func open(_ url: URL, in browser: BrowserInfo) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: browser.appURL, configuration: config)
    }
    
    /// Open URL in default browser
    @MainActor
    static func openDefault(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
    
    /// Get browser icon for display in UI — properly rendered at target size
    @MainActor
    static func icon(for browser: BrowserInfo, size: CGFloat = 16) -> NSImage {
        let original = NSWorkspace.shared.icon(forFile: browser.appURL.path)
        // Use the original at its natural resolution — SwiftUI will scale it
        // Just set the logical size for layout
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            original.draw(in: rect)
            return true
        }
        result.isTemplate = false
        return result
    }
}
