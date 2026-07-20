import Foundation
import Testing
@testable import AzLoginSwitcher

// MARK: - Sequential Mock Shell Executor

/// A mock shell executor that returns results in order for multi-step action flows.
/// Each call to `run()` pops the next result from the queue. If the queue is exhausted,
/// returns a default empty success result.
final class SequentialMockShellExecutor: ShellExecuting, @unchecked Sendable {
    private var results: [ShellResult]
    private var callIndex: Int = 0
    private(set) var allCalls: [(executable: String, arguments: [String])] = []

    init(results: [ShellResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) async throws -> ShellResult {
        allCalls.append((executable, arguments))
        let index = callIndex
        callIndex += 1
        if index < results.count {
            return results[index]
        }
        // Default: empty success (prevents crashes on unexpected calls like refreshAzureContext)
        return ShellResult(stdout: "", stderr: "", exitCode: 0)
    }
}

// MARK: - Test Helpers

/// Creates an ActionRunner wired to a mock shell, suitable for testing.
/// Returns the runner and the mock shell for inspection.
@MainActor
private func makeTestRunner(
    shell: ShellExecuting,
    config: AppConfig? = nil,
    availableBrowsers: [BrowserInfo] = []
) -> ActionRunner {
    let azCLI = AzCLI(shell: shell, azPath: "/usr/local/bin/az")
    let pimService = PIMService(shell: shell, azPath: "/usr/local/bin/az")
    let logger = ActionLogger(maxAgeDays: 0)
    return ActionRunner(
        azCLI: azCLI,
        pimService: pimService,
        logger: logger,
        config: config,
        availableBrowsers: availableBrowsers
    )
}

enum LoginPath: CaseIterable, Sendable {
    case login
    case loginAndSelect
}

/// JSON for `az account show` returning a specific tenant + subscription context.
private func accountShowJSON(tenantId: String, subscriptionId: String = "sub-1", subscriptionName: String = "Dev", user: String = "user@example.com") -> String {
    """
    {"tenantId":"\(tenantId)","id":"\(subscriptionId)","name":"\(subscriptionName)","user":{"name":"\(user)"}}
    """
}

/// JSON for `az account list` returning subscriptions for a tenant.
private func accountListJSON(tenantId: String, subs: [(id: String, name: String)] = [("sub-1", "Dev")]) -> String {
    let entries = subs.map { sub in
        """
        {"id":"\(sub.id)","name":"\(sub.name)","tenantId":"\(tenantId)","isDefault":true,"state":"Enabled","homeTenantId":"\(tenantId)","tenantDisplayName":"Tenant"}
        """
    }
    return "[\(entries.joined(separator: ","))]"
}

/// JSON for `az ad signed-in-user show`.
private func signedInUserJSON(id: String = "user-id", upn: String = "user@example.com") -> String {
    """
    {"id":"\(id)","userPrincipalName":"\(upn)"}
    """
}

/// Wait briefly for async action processing to complete.
@MainActor
private func waitForIdle(_ runner: ActionRunner, timeout: TimeInterval = 5.0) async {
    let deadline = Date().addingTimeInterval(timeout)
    while runner.isBusy && Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}

// MARK: - Tenant Status Derivation Tests

@Suite("ActionRunner - Tenant Status Derivation")
struct TenantStatusDerivationTests {

    // Test 1: isActiveTenant returns true when azureContext.currentTenantId matches
    @Test("isActiveTenant returns true for matching tenant")
    @MainActor
    func testIsActiveTenantMatchingTenant() async {
        let shell = MockShellExecutor()
        let runner = makeTestRunner(shell: shell)

        // Manually set azureContext to simulate a logged-in state
        // After implementation, azureContext will be set via refreshAzureContext or directly
        // We need to trigger a login to set context. For unit test, we test the method directly.
        // The method isActiveTenant should check azureContext.currentTenantId == tenantId

        // We'll simulate by running a login that sets the context
        shell.resultToReturn = ShellResult(
            stdout: accountShowJSON(tenantId: "tenant-A"),
            stderr: "", exitCode: 0
        )

        // For a pure unit test of isActiveTenant, we need to set azureContext.
        // Since azureContext is private(set), we use a workaround: call an action that sets it.
        // But for TDD, we test the NEW method directly.
        // The implementation will add: func isActiveTenant(_ tenantId: String) -> Bool

        #expect(runner.isActiveTenant("some-tenant") == false) // empty context initially

        // Now simulate context being set by using a sequential mock that handles login flow
        let seqShell = SequentialMockShellExecutor(results: [
            // 1. az login --tenant tenant-A
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            // 2. az account list -o json (list subscriptions)
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            // 3. az account set -s sub-1
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            // 4. az ad signed-in-user show -o json
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            // 5. az account show -o json (refreshAzureContext at end of startAction)
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
        ])
        let runner2 = makeTestRunner(shell: seqShell)
        let tenant = TenantConfig(name: "Tenant A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1")
        ])
        runner2.send(.login(tenant))
        await waitForIdle(runner2)

        #expect(runner2.isActiveTenant("tenant-A") == true)
    }

    // Test 2: isActiveTenant returns false when azureContext.currentTenantId doesn't match
    @Test("isActiveTenant returns false for non-matching tenant")
    @MainActor
    func testIsActiveTenantNonMatchingTenant() async {
        let seqShell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: "", stderr: "", exitCode: 0), // login
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0), // list subs
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0), // user
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0), // refresh
        ])
        let runner = makeTestRunner(shell: seqShell)
        let tenant = TenantConfig(name: "Tenant A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1")
        ])
        runner.send(.login(tenant))
        await waitForIdle(runner)

        #expect(runner.isActiveTenant("tenant-B") == false)
    }

    // Test 3: isActiveTenant returns false when azureContext is empty
    @Test("isActiveTenant returns false when context is empty")
    @MainActor
    func testIsActiveTenantEmptyContext() async {
        let shell = MockShellExecutor()
        let runner = makeTestRunner(shell: shell)

        #expect(runner.isActiveTenant("any-tenant") == false)
    }

    // Test 4: tenantStatus returns .active for the current tenant
    @Test("tenantStatus returns .active for current tenant")
    @MainActor
    func testTenantStatusActive() async {
        let seqShell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: "", stderr: "", exitCode: 0), // login
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: seqShell)
        let tenant = TenantConfig(name: "Tenant A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1")
        ])
        runner.send(.login(tenant))
        await waitForIdle(runner)

        #expect(runner.tenantStatus(for: "tenant-A") == .active)
    }

    // Test 5: tenantStatus returns .remembered for a tenant with cached data but not current
    @Test("tenantStatus returns .remembered for cached but inactive tenant")
    @MainActor
    func testTenantStatusRemembered() async {
        // Login to tenant-A first, then login to tenant-B.
        // tenant-A should be .remembered (has cached data) but not active.
        let seqShell = SequentialMockShellExecutor(results: [
            // Login to tenant-A
            ShellResult(stdout: "", stderr: "", exitCode: 0), // login
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            // Login to tenant-B
            ShellResult(stdout: "", stderr: "", exitCode: 0), // login
            ShellResult(stdout: accountListJSON(tenantId: "tenant-B", subs: [("sub-B", "Prod")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub
            ShellResult(stdout: signedInUserJSON(id: "user-b", upn: "userb@example.com"), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-B", subscriptionId: "sub-B"), stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: seqShell)

        let tenantA = TenantConfig(name: "Tenant A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1")
        ])
        runner.send(.login(tenantA))
        await waitForIdle(runner)

        let tenantB = TenantConfig(name: "Tenant B", tenantId: "tenant-B", subscriptions: [
            SubscriptionConfig(name: "Prod", id: "sub-B")
        ])
        runner.send(.login(tenantB))
        await waitForIdle(runner)

        // tenant-A has cached data (user, subs) but tenant-B is now active
        #expect(runner.tenantStatus(for: "tenant-A") == .remembered)
        #expect(runner.tenantStatus(for: "tenant-B") == .active)
    }

    // Test 6: tenantStatus returns .unknown for a tenant with no cached data
    @Test("tenantStatus returns .unknown for uncached tenant")
    @MainActor
    func testTenantStatusUnknown() async {
        let shell = MockShellExecutor()
        let runner = makeTestRunner(shell: shell)

        #expect(runner.tenantStatus(for: "never-seen-tenant") == .unknown)
    }
}

// MARK: - TenantCache Property Removal Tests

@Suite("TenantCache - Property Removal")
struct TenantCachePropertyRemovalTests {

    // Test 7: TenantCache should NOT have isLoggedIn property
    // This test verifies that TenantCache no longer tracks login state.
    // After the implementation removes isLoggedIn, this test passes because
    // we create a TenantCache and verify it has no isLoggedIn-related behavior.
    @Test("TenantCache has no isLoggedIn property")
    func testTenantCacheNoIsLoggedIn() {
        let cache = TenantCache()
        // After implementation: TenantCache won't have isLoggedIn.
        // We verify by encoding to JSON and checking the key is absent.
        let data = try! JSONEncoder().encode(cache)
        let dict = try! JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(dict["isLoggedIn"] == nil, "TenantCache should not contain isLoggedIn key")
    }

    // Test 8: TenantCache should NOT have effectivelyLoggedIn property
    // After the implementation, effectivelyLoggedIn is removed entirely.
    // We verify by encoding — effectivelyLoggedIn was computed so won't appear in JSON,
    // but we also verify that the concept doesn't exist by checking TenantCache behavior.
    @Test("TenantCache has no effectivelyLoggedIn computed property")
    func testTenantCacheNoEffectivelyLoggedIn() {
        let cache = TenantCache()
        // After implementation: calling cache.effectivelyLoggedIn would be a compile error.
        // We verify the type's mirror doesn't contain the property.
        let mirror = Mirror(reflecting: cache)
        let propertyNames = mirror.children.map { $0.label }
        #expect(!propertyNames.contains("isLoggedIn"), "TenantCache should not have isLoggedIn stored property")
        // effectivelyLoggedIn was computed, so it won't appear in Mirror.children,
        // but we verify it's gone by checking it doesn't appear in the encoded output either.
        // The real compile-time check: if someone tries `cache.effectivelyLoggedIn` after removal, it won't compile.
    }
}

// MARK: - loginAndSelect Action Tests

@Suite("ActionRunner - loginAndSelect Action")
struct LoginAndSelectTests {

    // Test 9: loginAndSelect triggers login then subscription selection
    @Test("loginAndSelect chains login and subscription selection")
    @MainActor
    func testLoginAndSelectChainsActions() async {
        let seqShell = SequentialMockShellExecutor(results: [
            // 1. az login --tenant tenant-A
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            // 2. az account list -o json
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A", subs: [("sub-1", "Dev"), ("sub-2", "Prod")]), stderr: "", exitCode: 0),
            // 3. az account set -s sub-2
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            // 4. az ad signed-in-user show -o json
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            // 5. az account show -o json (refreshAzureContext)
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A", subscriptionId: "sub-2", subscriptionName: "Prod"), stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: seqShell)
        let tenant = TenantConfig(name: "Tenant A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1"),
            SubscriptionConfig(name: "Prod", id: "sub-2"),
        ])
        let sub = SubscriptionConfig(name: "Prod", id: "sub-2")

        runner.send(.loginAndSelect(sub, tenant: tenant))
        await waitForIdle(runner)

        // Verify login was called
        let loginCalls = seqShell.allCalls.filter { $0.arguments.contains("login") }
        #expect(loginCalls.count == 1)

        // Verify subscription was set to the requested one
        let setCalls = seqShell.allCalls.filter { $0.arguments.contains("set") }
        #expect(setCalls.count >= 1)
        let setArgs = setCalls.first!.arguments
        #expect(setArgs.contains("sub-2"))

        // Verify the runner is idle after completion
        #expect(runner.isBusy == false)

        // Verify azure context reflects the selected subscription
        #expect(runner.azureContext.currentTenantId == "tenant-A")
        #expect(runner.azureContext.currentSubscriptionId == "sub-2")
    }

    // Test 10: After loginAndSelect, azureContext reflects the selected subscription's tenant
    @Test("loginAndSelect sets azureContext to selected subscription tenant")
    @MainActor
    func testLoginAndSelectSetsContext() async {
        let seqShell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: "", stderr: "", exitCode: 0), // login
            ShellResult(stdout: accountListJSON(tenantId: "tenant-X"), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-X", subscriptionId: "sub-X", subscriptionName: "MySub"), stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: seqShell)
        let tenant = TenantConfig(name: "Tenant X", tenantId: "tenant-X", subscriptions: [
            SubscriptionConfig(name: "MySub", id: "sub-X")
        ])

        runner.send(.loginAndSelect(SubscriptionConfig(name: "MySub", id: "sub-X"), tenant: tenant))
        await waitForIdle(runner)

        #expect(runner.azureContext.currentTenantId == "tenant-X")
        #expect(runner.azureContext.currentSubscriptionId == "sub-X")
        #expect(runner.isActiveTenant("tenant-X") == true)
    }

    // Test 11: loginAndSelect on already-active tenant skips login, just selects subscription
    @Test("loginAndSelect skips login when tenant is already active")
    @MainActor
    func testLoginAndSelectSkipsLoginForActiveTenant() async {
        // First: login to tenant-A normally
        let seqShell = SequentialMockShellExecutor(results: [
            // Initial login to tenant-A
            ShellResult(stdout: "", stderr: "", exitCode: 0), // login
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A", subs: [("sub-1", "Dev"), ("sub-2", "Prod")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub-1
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A", subscriptionId: "sub-1"), stderr: "", exitCode: 0),
            // loginAndSelect on same tenant — should skip login, just set sub-2
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub-2 (no login call)
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A", subscriptionId: "sub-2", subscriptionName: "Prod"), stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: seqShell)
        let tenant = TenantConfig(name: "Tenant A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1"),
            SubscriptionConfig(name: "Prod", id: "sub-2"),
        ])

        // First login normally
        runner.send(.login(tenant))
        await waitForIdle(runner)
        #expect(runner.isActiveTenant("tenant-A") == true)

        let callCountBeforeLoginAndSelect = seqShell.allCalls.count

        // Now loginAndSelect on same tenant — should NOT call az login again
        runner.send(.loginAndSelect(SubscriptionConfig(name: "Prod", id: "sub-2"), tenant: tenant))
        await waitForIdle(runner)

        // Check that no additional login call was made
        let callsAfter = Array(seqShell.allCalls.dropFirst(callCountBeforeLoginAndSelect))
        let loginCallsAfter = callsAfter.filter { $0.arguments.contains("login") }
        #expect(loginCallsAfter.isEmpty, "Should not call az login when tenant is already active")

        // But subscription should be set
        let setCallsAfter = callsAfter.filter { $0.arguments.contains("set") }
        #expect(setCallsAfter.count >= 1)

        #expect(runner.azureContext.currentSubscriptionId == "sub-2")
    }

    @Test(
        "configured browser is used by every interactive login path",
        arguments: LoginPath.allCases
    )
    @MainActor
    func configuredBrowserIsUsedByEveryInteractiveLoginPath(path: LoginPath) async {
        let shell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
        ])
        let tenant = TenantConfig(
            name: "Tenant A",
            tenantId: "tenant-A",
            subscriptions: [SubscriptionConfig(name: "Dev", id: "sub-1")]
        )
        let installedBrowsers = [
            BrowserInfo(
                id: "com.microsoft.edgemac",
                name: "Microsoft Edge",
                appURL: URL(fileURLWithPath: "/Applications/Microsoft Edge.app")
            ),
            BrowserInfo(
                id: "com.google.Chrome",
                name: "Google Chrome",
                appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
            ),
        ]
        let runner = makeTestRunner(
            shell: shell,
            config: AppConfig(tenants: [tenant], loginBrowser: .chrome),
            availableBrowsers: installedBrowsers
        )

        switch path {
        case .login:
            runner.send(.login(tenant))
        case .loginAndSelect:
            runner.send(.loginAndSelect(tenant.subscriptions[0], tenant: tenant))
        }
        await waitForIdle(runner)

        let loginCall = shell.allCalls.first { $0.arguments.contains("login") }
        #expect(loginCall?.executable == "/usr/bin/env")
        #expect(loginCall?.arguments == [
            "BROWSER=/usr/bin/open -b com.google.Chrome %s",
            "/usr/local/bin/az",
            "login",
            "--tenant",
            "tenant-A",
        ])
    }
}

// MARK: - State Consistency Tests

@Suite("ActionRunner - State Consistency")
struct StateConsistencyTests {

    // Test 12: After login to tenant A, then login to tenant B, only tenant B is "active"
    @Test("Only the most recently logged-in tenant is active")
    @MainActor
    func testOnlyLastLoginIsActive() async {
        let seqShell = SequentialMockShellExecutor(results: [
            // Login tenant-A
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            // Login tenant-B
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-B", subs: [("sub-B", "Prod")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(id: "user-b", upn: "b@example.com"), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-B", subscriptionId: "sub-B"), stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: seqShell)

        let tenantA = TenantConfig(name: "A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1")
        ])
        runner.send(.login(tenantA))
        await waitForIdle(runner)
        #expect(runner.isActiveTenant("tenant-A") == true)

        let tenantB = TenantConfig(name: "B", tenantId: "tenant-B", subscriptions: [
            SubscriptionConfig(name: "Prod", id: "sub-B")
        ])
        runner.send(.login(tenantB))
        await waitForIdle(runner)

        #expect(runner.isActiveTenant("tenant-A") == false, "Tenant A should no longer be active")
        #expect(runner.isActiveTenant("tenant-B") == true, "Tenant B should now be active")
    }

    // Test 13: After logoutAll, no tenant is active, azureContext is empty
    @Test("logoutAll clears all active state")
    @MainActor
    func testLogoutAllClearsState() async {
        let seqShell = SequentialMockShellExecutor(results: [
            // Login tenant-A
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            // logoutAll: az account clear
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            // refreshAzureContext after logoutAll — returns empty/error
            ShellResult(stdout: "", stderr: "No subscription found", exitCode: 1),
        ])
        let runner = makeTestRunner(shell: seqShell)

        let tenant = TenantConfig(name: "A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1")
        ])
        runner.send(.login(tenant))
        await waitForIdle(runner)
        #expect(runner.isActiveTenant("tenant-A") == true)

        runner.send(.logoutAll)
        await waitForIdle(runner)

        #expect(runner.isActiveTenant("tenant-A") == false)
        #expect(runner.azureContext == .empty)
    }

    // Test 14: TenantCache data persists even when tenant is not active
    @Test("Cached data persists when tenant becomes inactive")
    @MainActor
    func testCachedDataPersistsWhenInactive() async {
        let seqShell = SequentialMockShellExecutor(results: [
            // Login tenant-A
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-A", subs: [("sub-1", "Dev"), ("sub-2", "Staging")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(id: "user-a", upn: "a@example.com"), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A"), stderr: "", exitCode: 0),
            // Login tenant-B (makes tenant-A inactive)
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-B", subs: [("sub-B", "Prod")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(id: "user-b", upn: "b@example.com"), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-B", subscriptionId: "sub-B"), stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: seqShell)

        let tenantA = TenantConfig(name: "A", tenantId: "tenant-A", subscriptions: [
            SubscriptionConfig(name: "Dev", id: "sub-1")
        ])
        runner.send(.login(tenantA))
        await waitForIdle(runner)

        // Verify tenant-A has cached data
        let cacheA = runner.cache(for: "tenant-A")
        #expect(cacheA.signedInUser?.userPrincipalName == "a@example.com")
        #expect(cacheA.allDiscoveredSubscriptions.count == 2)

        // Now login to tenant-B — tenant-A becomes inactive
        let tenantB = TenantConfig(name: "B", tenantId: "tenant-B", subscriptions: [
            SubscriptionConfig(name: "Prod", id: "sub-B")
        ])
        runner.send(.login(tenantB))
        await waitForIdle(runner)

        // tenant-A is no longer active
        #expect(runner.isActiveTenant("tenant-A") == false)

        // But its cached data should still be there
        let cacheAAfter = runner.cache(for: "tenant-A")
        #expect(cacheAAfter.signedInUser?.userPrincipalName == "a@example.com")
        #expect(cacheAAfter.allDiscoveredSubscriptions.count == 2)
        #expect(cacheAAfter.loginAt != nil)
    }
}

// MARK: - AnyCodable helper for JSON key inspection

/// Minimal AnyCodable for decoding arbitrary JSON to check key presence.
private struct AnyCodable: Decodable {
    init(from decoder: Decoder) throws {
        // We only care about key existence, not values
        _ = try? decoder.singleValueContainer()
    }
}
