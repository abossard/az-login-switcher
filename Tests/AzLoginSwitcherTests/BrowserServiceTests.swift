import Foundation
import Testing
@testable import AzLoginSwitcher

@Suite("BrowserService Tests")
struct BrowserServiceTests {
    enum MissingBrowserScenario: CaseIterable, Sendable {
        case configuredBrowserUnavailable
        case omittedWithoutEdge
    }

    private static let safari = BrowserInfo(
        id: "com.apple.Safari",
        name: "Safari",
        appURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )
    private static let chrome = BrowserInfo(
        id: "com.google.Chrome",
        name: "Google Chrome",
        appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
    )
    private static let edge = BrowserInfo(
        id: "com.microsoft.edgemac",
        name: "Microsoft Edge",
        appURL: URL(fileURLWithPath: "/Applications/Microsoft Edge.app")
    )

    @Test("omitted login browser prefers installed Edge")
    func omittedLoginBrowserPrefersInstalledEdge() {
        let installedBrowsers = [Self.safari, Self.chrome, Self.edge]

        let resolved = BrowserService.resolveLoginBrowser(
            configured: nil,
            installedBrowsers: installedBrowsers
        )

        #expect(resolved?.id == "com.microsoft.edgemac")
    }

    @Test("configured installed browser wins over Edge")
    func configuredInstalledBrowserWinsOverEdge() {
        let installedBrowsers = [Self.edge, Self.chrome]

        let resolved = BrowserService.resolveLoginBrowser(
            configured: .chrome,
            installedBrowsers: installedBrowsers
        )

        #expect(resolved?.id == "com.google.Chrome")
    }

    @Test(
        "unavailable browser selection preserves system default",
        arguments: MissingBrowserScenario.allCases
    )
    func unavailableBrowserSelectionPreservesSystemDefault(
        scenario: MissingBrowserScenario
    ) {
        let configured: LoginBrowser?
        let installedBrowsers: [BrowserInfo]
        switch scenario {
        case .configuredBrowserUnavailable:
            configured = .firefox
            installedBrowsers = [Self.edge, Self.chrome]
        case .omittedWithoutEdge:
            configured = nil
            installedBrowsers = [Self.safari, Self.chrome]
        }

        let resolved = BrowserService.resolveLoginBrowser(
            configured: configured,
            installedBrowsers: installedBrowsers
        )

        #expect(resolved == nil)
    }
}
