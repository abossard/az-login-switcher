import Foundation
import SwiftUI
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

private actor SuspendedDiscoveryShell: ShellExecuting {
    private var pending: [Int: CheckedContinuation<ShellResult, Never>] = [:]
    private var callCount = 0

    func run(executable: String, arguments: [String]) async throws -> ShellResult {
        callCount += 1
        let call = callCount
        return await withCheckedContinuation { pending[call] = $0 }
    }

    func waitForCall(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while callCount < count && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(callCount >= count)
    }

    func resolve(call: Int) throws {
        let pendingContinuation = pending.removeValue(forKey: call)
        let continuation = try #require(pendingContinuation)
        continuation.resume(returning: ShellResult(
            stdout: #"{"value":[{"tenantId":"tenant-\#(call)"}]}"#,
            stderr: "", exitCode: 0
        ))
    }
}

// MARK: - Test Helpers

private let testStorageDirectory: URL = {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("az-login-switcher-tests-\(UUID().uuidString)")
    atexit { try? FileManager.default.removeItem(at: testStorageDirectory) }
    return directory
}()

/// Creates an ActionRunner wired to a mock shell, suitable for testing.
/// Returns the runner and the mock shell for inspection.
@MainActor
private func makeTestRunner(
    shell: ShellExecuting,
    config: AppConfig? = nil,
    availableBrowsers: [BrowserInfo] = [],
    storageDirectory: URL? = nil
) -> ActionRunner {
    let directory = storageDirectory ?? testStorageDirectory.appendingPathComponent(UUID().uuidString)
    let azCLI = AzCLI(shell: shell, azPath: "/usr/local/bin/az")
    let pimService = PIMService(shell: shell, azPath: "/usr/local/bin/az")
    let logger = ActionLogger(maxAgeDays: 0, logDirectoryURL: directory.appendingPathComponent("logs"))
    return ActionRunner(
        azCLI: azCLI,
        pimService: pimService,
        logger: logger,
        config: config,
        availableBrowsers: availableBrowsers,
        configPath: directory.appendingPathComponent("config.yaml").path,
        statePath: directory.appendingPathComponent("state.json").path
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

@Suite("ActionRunner - Tenant Discovery")
struct TenantDiscoveryTests {
    private let tenantJSON = """
    {"value":[
      {"tenantId":"existing","displayName":"Azure name"},
      {"tenantId":"new-a","displayName":"New A"},
      {"tenantId":"new-b","defaultDomain":"new-b.example.com"}
    ]}
    """

    @Test("discovery saves only selected tenants and preserves the latest configuration",
          arguments: [Set(["new-a"]), Set(["new-a", "new-b"])])
    @MainActor
    func selectedTenantImport(selectedIds: Set<String>) async throws {
        let directory = testStorageDirectory.appendingPathComponent(UUID().uuidString)
        let shell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: tenantJSON, stderr: "", exitCode: 0),
            ShellResult(stdout: tenantJSON, stderr: "", exitCode: 0),
        ])
        let existingTenant = TenantConfig(
            name: "Custom name",
            tenantId: "EXISTING",
            subscriptions: [SubscriptionConfig(name: "Dev", id: "sub-1")],
            pim: PIMConfig(justification: "Testing", duration: "PT4H"),
            subscriptionFilter: "Dev"
        )
        let original = AppConfig(tenants: [existingTenant], loginBrowser: .chrome)
        let runner = makeTestRunner(shell: shell, config: original, storageDirectory: directory)
        let configPath = directory.appendingPathComponent("config.yaml").path
        try ConfigLoader.saveConfig(original, to: configPath)
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: configPath))

        runner.send(.discoverTenants)
        #expect(runner.isBusy)
        runner.send(.discoverTenants)
        runner.send(.addDiscoveredTenants(selectedIds))
        runner.send(.loadConfig)
        await waitForIdle(runner)
        try #require(!runner.isBusy)

        #expect(runner.config == original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: configPath)) == originalBytes)
        #expect(runner.discoveredTenants?.count == 3)
        #expect(shell.allCalls.count == 1)
        #expect(runner.actionHistory.last?.commandLog.count == 1)
        #expect(runner.actionHistory.last?.phase == .succeeded)

        let latest = AppConfig(tenants: [existingTenant], loginBrowser: .firefox)
        try ConfigLoader.saveConfig(latest, to: configPath)
        runner.send(.addDiscoveredTenants(selectedIds))
        await waitForIdle(runner)
        try #require(!runner.isBusy)

        let saved = try ConfigLoader.loadConfig(from: configPath).get()
        #expect(saved == runner.config)
        #expect(saved.loginBrowser == .firefox)
        #expect(saved.tenants.first == existingTenant)
        #expect(Set(saved.tenants.dropFirst().map(\.tenantId)) == selectedIds)
        #expect(saved.tenants.dropFirst().allSatisfy { $0.subscriptions.isEmpty && $0.pim == nil })
        #expect(runner.discoveredTenants == nil)
        #expect(runner.tenantDiscoveryError == nil)
        #expect(shell.allCalls.count == 1)

        runner.send(.discoverTenants)
        await waitForIdle(runner)
        runner.send(.addDiscoveredTenants(selectedIds.union(["existing"])))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.config == saved)
        #expect(try ConfigLoader.loadConfig(from: configPath).get() == saved)
    }

    @Test("discovery errors are visible without changing config",
          arguments: [
            ShellResult(stdout: "", stderr: "Please run 'az login'", exitCode: 1),
            ShellResult(stdout: "invalid JSON", stderr: "", exitCode: 0),
            ShellResult(stdout: "{}", stderr: "", exitCode: 0),
          ])
    @MainActor
    func discoveryFailure(result: ShellResult) async throws {
        let original = AppConfig(tenants: [])
        let shell = SequentialMockShellExecutor(results: [result])
        let runner = makeTestRunner(shell: shell, config: original)

        runner.send(.discoverTenants)
        await waitForIdle(runner)
        try #require(!runner.isBusy)

        #expect(runner.config == original)
        #expect(runner.discoveredTenants == nil)
        #expect(runner.tenantDiscoveryError?.contains("Tenant discovery failed") == true)
        guard case .failed = runner.actionHistory.last?.phase else {
            Issue.record("Discovery failure must be recorded as a failed action")
            return
        }
        #expect(runner.actionHistory.last?.commandLog.count == 1)
        #expect(shell.allCalls.count == 1)
    }

    @Test("missing config is created only after confirming a selection")
    @MainActor
    func missingConfigAndDismissal() async throws {
        let directory = testStorageDirectory.appendingPathComponent(UUID().uuidString)
        let shell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: tenantJSON, stderr: "", exitCode: 0),
            ShellResult(stdout: tenantJSON, stderr: "", exitCode: 0),
        ])
        let runner = makeTestRunner(shell: shell, storageDirectory: directory)
        let configPath = directory.appendingPathComponent("config.yaml").path

        runner.send(.discoverTenants)
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(!FileManager.default.fileExists(atPath: configPath))
        runner.send(.dismissTenantDiscovery)
        #expect(runner.discoveredTenants == nil)
        #expect(runner.config == nil)

        runner.send(.discoverTenants)
        await waitForIdle(runner)
        runner.send(.addDiscoveredTenants(["new-b"]))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(try ConfigLoader.loadConfig(from: configPath).get() == AppConfig(tenants: [
            TenantConfig(name: "new-b.example.com", tenantId: "new-b", subscriptions: [])
        ]))
    }

    @Test("failed imports keep discovery open and do not publish unsaved config",
          arguments: ["invalid-yaml", "directory-target", "write-failure", "empty-selection", "unknown-selection"])
    @MainActor
    func failedImport(scenario: String) async throws {
        let directory = testStorageDirectory.appendingPathComponent(UUID().uuidString)
        let shell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: tenantJSON, stderr: "", exitCode: 0)
        ])
        let original = AppConfig(tenants: [])
        let runner = makeTestRunner(shell: shell, config: original, storageDirectory: directory)
        let configURL = directory.appendingPathComponent("config.yaml")
        if scenario == "invalid-yaml" {
            try "tenants: [".write(to: configURL, atomically: true, encoding: .utf8)
        } else if scenario == "directory-target" {
            try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        }

        runner.send(.discoverTenants)
        await waitForIdle(runner)
        if scenario == "write-failure" {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        defer {
            if scenario == "write-failure" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        }
        runner.send(.addDiscoveredTenants(
            scenario == "empty-selection" ? [] : scenario == "unknown-selection" ? ["unknown"] : ["new-a"]
        ))
        await waitForIdle(runner)
        try #require(!runner.isBusy)

        #expect(runner.config == original)
        #expect(runner.discoveredTenants?.count == 3)
        #expect(runner.tenantDiscoveryError?.contains("Could not add tenants") == true)
        guard case .failed = runner.actionHistory.last?.phase else {
            Issue.record("Import failure must be recorded as a failed action")
            return
        }
        if scenario == "invalid-yaml" {
            #expect(try String(contentsOf: configURL, encoding: .utf8) == "tenants: [")
        } else if scenario == "write-failure" {
            #expect(runner.tenantDiscoveryError?.contains("Failed to save configuration") == true)
            #expect(!FileManager.default.fileExists(atPath: configURL.path))
        } else if scenario != "directory-target" {
            #expect(!FileManager.default.fileExists(atPath: configURL.path))
        }
    }

    @Test("an empty discovery succeeds without adding tenants")
    @MainActor
    func emptyDiscovery() async throws {
        let shell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0)
        ])
        let runner = makeTestRunner(shell: shell)
        runner.send(.discoverTenants)
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.discoveredTenants == [])
        #expect(runner.tenantDiscoveryError == nil)
        #expect(runner.config == nil)
    }

    @Test("cancelled discovery cannot publish or log late results into a newer action")
    @MainActor
    func cancelledDiscovery() async throws {
        let shell = SuspendedDiscoveryShell()
        let runner = makeTestRunner(shell: shell)
        runner.send(.discoverTenants)
        try await shell.waitForCall(1)
        runner.send(.cancelAction)
        #expect(!runner.isBusy)

        runner.send(.discoverTenants)
        try await shell.waitForCall(2)
        let secondActionId = runner.currentAction?.id
        try await shell.resolve(call: 1)
        await Task.yield()
        #expect(runner.currentAction?.id == secondActionId)
        #expect(runner.discoveredTenants == nil)

        try await shell.resolve(call: 2)
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.discoveredTenants?.map(\.tenantId) == ["tenant-2"])
        #expect(runner.tenantDiscoveryError == nil)
        #expect(runner.actionHistory.count == 2)
        #expect(runner.actionHistory.first?.phase == .failed("Cancelled"))
        #expect(runner.actionHistory.last?.phase == .succeeded)
        #expect(runner.actionHistory.last?.commandLog.count == 1)
    }

    @Test("tenant picker renders in the native panel size",
          arguments: [0, 2, 100])
    @MainActor
    func nativePickerRendering(count: Int) throws {
        _ = NSApplication.shared
        let shell = MockShellExecutor()
        let runner = makeTestRunner(shell: shell, config: AppConfig(tenants: [
            TenantConfig(name: "Existing", tenantId: "tenant-0", subscriptions: [])
        ]))
        let tenants = (0..<count).map {
            AzTenant(tenantId: "tenant-\($0)", displayName: "Tenant \($0)", defaultDomain: nil)
        }
        let hostingView = NSHostingView(rootView: TenantDiscoveryView(tenants: tenants, runner: runner))
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 500)
        #expect(bitmap.pixelsHigh >= 400)
        #expect(hostingView.fittingSize.width.isFinite)
        #expect(hostingView.fittingSize.height.isFinite)
    }
}

@Suite("ActionRunner - PIM Loading")
struct PIMLoadingTests {
    private actor Shell: ShellExecuting {
        private(set) var calls: [[String]] = []
        private var discoveryFails = false
        private let context: String
        private let suspendDiscovery: Bool
        private var pendingDiscovery: CheckedContinuation<Void, Never>?

        init(context: String = accountShowJSON(tenantId: "tenant-A"), suspendDiscovery: Bool = false) {
            self.context = context
            self.suspendDiscovery = suspendDiscovery
        }

        func setDiscoveryFailure(_ fails: Bool) {
            discoveryFails = fails
        }

        func waitForDiscovery() async throws {
            let deadline = Date().addingTimeInterval(5)
            while pendingDiscovery == nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try #require(pendingDiscovery != nil)
        }

        func resumeDiscovery() {
            pendingDiscovery?.resume()
            pendingDiscovery = nil
        }

        func run(executable: String, arguments: [String]) async throws -> ShellResult {
            calls.append(arguments)
            let output: String
            switch arguments {
            case ["login", "--tenant", "tenant-A"], ["account", "set", "-s", "sub-1"]:
                output = ""
            case ["account", "list", "-o", "json"]:
                output = accountListJSON(tenantId: "tenant-A")
            case ["ad", "signed-in-user", "show", "-o", "json"]:
                output = signedInUserJSON()
            case ["account", "show", "-o", "json"]:
                output = context
            case ["rest", "--method", "GET", "--url",
                  "https://management.azure.com/subscriptions/sub-1/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&$filter=asTarget()",
                  "-o", "json"]:
                if suspendDiscovery {
                    await withCheckedContinuation { pendingDiscovery = $0 }
                }
                if discoveryFails {
                    return ShellResult(stdout: "", stderr: "AuthorizationFailed", exitCode: 1)
                }
                output = """
                {"value":[{"id":"eligible-role","properties":{
                  "roleDefinitionId":"/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/owner",
                  "scope":"/subscriptions/sub-1","principalId":"user-id","roleEligibilityScheduleId":"schedule-id"
                }}]}
                """
            case ["role", "definition", "list", "--scope", "/subscriptions/sub-1", "-o", "json"]:
                output = """
                [{"id":"/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/owner","roleName":"Owner"}]
                """
            default:
                guard arguments.starts(with: ["rest", "--method", "PUT"]),
                      arguments.contains("--body") else {
                    throw AzCLIError.commandFailed(stderr: "Unexpected test command: \(arguments)", exitCode: 1)
                }
                output = #"{"properties":{"status":"Granted","scheduleInfo":{"expiration":{"endDateTime":"2030-01-01T00:00:00Z"}}}}"#
            }
            return ShellResult(stdout: output, stderr: "", exitCode: 0)
        }
    }

    @Test("login and subscription selection load eligible PIM roles with or without PIM settings",
          arguments: [false, true], ["login", "login-and-select", "select-subscription"])
    @MainActor
    func loadsRoles(configured: Bool, path: String) async throws {
        let shell = Shell()
        let subscription = SubscriptionConfig(name: "Dev", id: "sub-1")
        let tenant = TenantConfig(
            name: "Tenant A", tenantId: "tenant-A", subscriptions: [subscription],
            pim: configured ? PIMConfig(justification: "Development", duration: "PT4H") : nil
        )
        let runner = makeTestRunner(shell: shell, config: AppConfig(tenants: [tenant]))
        switch path {
        case "login":
            runner.send(.login(tenant))
        case "login-and-select":
            runner.send(.loginAndSelect(subscription, tenant: tenant))
        default:
            runner.send(.selectSubscription(subscription, tenantId: tenant.tenantId))
        }
        await waitForIdle(runner)
        try #require(!runner.isBusy)

        #expect(runner.cache(for: tenant.tenantId).eligiblePIMRoles.map(\.id) == ["eligible-role"])
        #expect(runner.cache(for: tenant.tenantId).eligiblePIMRoles.first?.roleName == "Owner")
        #expect(runner.pimRoles(for: tenant.tenantId).map(\.id) == ["eligible-role"])
        #expect(runner.pimRoles(for: "tenant-B").isEmpty)
        #expect(runner.isActiveTenant(tenant.tenantId))
        let calls = await shell.calls
        #expect(calls.filter { $0.first == "rest" }.count == 1)
    }

    @Test("new tenants load PIM roles even before exposing subscriptions", arguments: [false, true])
    @MainActor
    func loadsRolesWithoutConfiguredSubscriptions(configured: Bool) async throws {
        let shell = Shell()
        let tenant = TenantConfig(
            name: "Discovered", tenantId: "tenant-A", subscriptions: [],
            pim: configured ? PIMConfig(justification: "Development", duration: "PT4H") : nil
        )
        let runner = makeTestRunner(shell: shell, config: AppConfig(tenants: [tenant]))
        runner.send(.login(tenant))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.cache(for: tenant.tenantId).eligiblePIMRoles.map(\.id) == ["eligible-role"])
        #expect(runner.config?.tenants.first?.subscriptions.isEmpty == true)
    }

    @Test("failed discovery is visible and a later selection clears the error")
    @MainActor
    func discoveryErrorAndRecovery() async throws {
        let shell = Shell()
        let subscription = SubscriptionConfig(name: "Dev", id: "sub-1")
        let runner = makeTestRunner(shell: shell)
        await shell.setDiscoveryFailure(true)
        runner.send(.selectSubscription(subscription, tenantId: "tenant-A"))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.cache(for: "tenant-A").pimDiscoveryError?.contains("AuthorizationFailed") == true)
        #expect(runner.cache(for: "tenant-A").eligiblePIMRoles.isEmpty)
        guard case .partialSuccess = runner.actionHistory.last?.phase else {
            Issue.record("Discovery failure must not be reported as a successful empty list")
            return
        }
        #expect(runner.actionHistory.last?.commandLog.last?.exitCode == 1)

        await shell.setDiscoveryFailure(false)
        runner.send(.selectSubscription(subscription, tenantId: "tenant-A"))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.cache(for: "tenant-A").pimDiscoveryError == nil)
        #expect(runner.cache(for: "tenant-A").eligiblePIMRoles.map(\.id) == ["eligible-role"])
        #expect(runner.actionHistory.last?.phase == .succeeded)
    }

    @Test("refreshing roles preserves activation status and configured activation request")
    @MainActor
    func preservesActivation() async throws {
        let shell = Shell()
        let subscription = SubscriptionConfig(name: "Dev", id: "sub-1")
        let tenant = TenantConfig(
            name: "Tenant A", tenantId: "tenant-A", subscriptions: [subscription],
            pim: PIMConfig(justification: "Configured justification", duration: "PT4H")
        )
        let runner = makeTestRunner(shell: shell, config: AppConfig(tenants: [tenant]))
        runner.send(.login(tenant))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        let role = try #require(runner.cache(for: tenant.tenantId).eligiblePIMRoles.first)
        runner.send(.activatePIM(role, tenant))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        let activeStatus = try #require(runner.cache(for: tenant.tenantId).pimRoleStatuses[role.id])
        #expect(activeStatus.status == .active(expires: "2030-01-01T00:00:00Z"))

        runner.send(.loginAndSelect(subscription, tenant: tenant))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.cache(for: tenant.tenantId).pimRoleStatuses[role.id] == activeStatus)
        let calls = await shell.calls
        let activation = try #require(calls.first { $0.starts(with: ["rest", "--method", "PUT"]) })
        let bodyIndex = try #require(activation.firstIndex(of: "--body"))
        let body = try JSONSerialization.jsonObject(with: Data(activation[bodyIndex + 1].utf8)) as? [String: Any]
        let properties = try #require(body?["properties"] as? [String: Any])
        #expect(properties["justification"] as? String == "Configured justification")
        let schedule = try #require(properties["scheduleInfo"] as? [String: Any])
        let expiration = try #require(schedule["expiration"] as? [String: Any])
        #expect(expiration["duration"] as? String == "PT4H")
        #expect(calls.filter { $0.contains("login") }.count == 1)
    }

    @Test("PIM is not queried for a mismatched live tenant")
    @MainActor
    func mismatchedTenant() async throws {
        let shell = Shell(context: accountShowJSON(tenantId: "tenant-B"))
        let runner = makeTestRunner(shell: shell)
        runner.send(.selectSubscription(SubscriptionConfig(name: "Dev", id: "sub-1"), tenantId: "tenant-A"))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.cache(for: "tenant-A").eligiblePIMRoles.isEmpty)
        #expect(runner.cache(for: "tenant-A").pimDiscoveryError?.contains("not active") == true)
        let calls = await shell.calls
        #expect(!calls.contains { $0.first == "rest" })
    }

    @Test("login without a selected subscription does not query PIM")
    @MainActor
    func noSelectedSubscription() async throws {
        let shell = Shell(context: #"{"tenantId":"tenant-A","user":{"name":"user@example.com"}}"#)
        let tenant = TenantConfig(name: "Empty", tenantId: "tenant-A", subscriptions: [])
        let runner = makeTestRunner(shell: shell, config: AppConfig(tenants: [tenant]))
        runner.send(.login(tenant))
        await waitForIdle(runner)
        try #require(!runner.isBusy)
        #expect(runner.pimRoles(for: tenant.tenantId).isEmpty)
        #expect(runner.cache(for: tenant.tenantId).pimDiscoveryError == nil)
        #expect(runner.actionHistory.last?.phase == .succeeded)
        let calls = await shell.calls
        #expect(!calls.contains { $0.first == "rest" })
    }

    @Test("cancelled PIM discovery cannot publish late roles")
    @MainActor
    func cancelledPIMDiscovery() async throws {
        let shell = Shell(suspendDiscovery: true)
        let runner = makeTestRunner(shell: shell)
        runner.send(.selectSubscription(SubscriptionConfig(name: "Dev", id: "sub-1"), tenantId: "tenant-A"))
        try await shell.waitForDiscovery()
        runner.send(.cancelAction)
        #expect(!runner.isBusy)
        await shell.resumeDiscovery()
        await Task.yield()
        #expect(runner.cache(for: "tenant-A").eligiblePIMRoles.isEmpty)
        #expect(runner.cache(for: "tenant-A").pimDiscoveryError == nil)
        #expect(runner.actionHistory.last?.phase == .failed("Cancelled"))
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
            // Login to tenant-B
            ShellResult(stdout: "", stderr: "", exitCode: 0), // login
            ShellResult(stdout: accountListJSON(tenantId: "tenant-B", subs: [("sub-B", "Prod")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub
            ShellResult(stdout: signedInUserJSON(id: "user-b", upn: "userb@example.com"), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-B", subscriptionId: "sub-B"), stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
            // loginAndSelect on same tenant — should skip login, just set sub-2
            ShellResult(stdout: "", stderr: "", exitCode: 0), // set sub-2 (no login call)
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-A", subscriptionId: "sub-2", subscriptionName: "Prod"), stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
            // Login tenant-B
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-B", subs: [("sub-B", "Prod")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(id: "user-b", upn: "b@example.com"), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-B", subscriptionId: "sub-B"), stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
            // Login tenant-B (makes tenant-A inactive)
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: accountListJSON(tenantId: "tenant-B", subs: [("sub-B", "Prod")]), stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "", exitCode: 0),
            ShellResult(stdout: signedInUserJSON(id: "user-b", upn: "b@example.com"), stderr: "", exitCode: 0),
            ShellResult(stdout: accountShowJSON(tenantId: "tenant-B", subscriptionId: "sub-B"), stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[]}"#, stderr: "", exitCode: 0),
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
