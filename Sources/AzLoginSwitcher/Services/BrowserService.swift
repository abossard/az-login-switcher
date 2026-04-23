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
    
    /// All browsers installed that can handle https URLs, sorted by name
    @MainActor
    static func installedBrowsers() -> [BrowserInfo] {
        let httpsURL = URL(string: "https://example.com")!
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: httpsURL)
        
        return appURLs.compactMap { appURL in
            guard let bundle = Bundle(url: appURL),
                  let bundleID = bundle.bundleIdentifier else { return nil }
            
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                     ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                     ?? appURL.deletingPathExtension().lastPathComponent
            
            return BrowserInfo(id: bundleID, name: name, appURL: appURL)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    
    /// Get browser icon (16x16) for display in UI — call from view layer only
    @MainActor
    static func icon(for browser: BrowserInfo, size: CGFloat = 16) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: browser.appURL.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
