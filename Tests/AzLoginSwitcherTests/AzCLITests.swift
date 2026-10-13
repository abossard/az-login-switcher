import Foundation
import Testing
@testable import AzLoginSwitcher

// MARK: - Mock Shell Executor

final class MockShellExecutor: ShellExecuting, @unchecked Sendable {
    var lastExecutable: String?
    var lastArguments: [String]?
    var resultToReturn: ShellResult = ShellResult(stdout: "", stderr: "", exitCode: 0)
    var errorToThrow: Error?
    
    func run(executable: String, arguments: [String]) async throws -> ShellResult {
        lastExecutable = executable
        lastArguments = arguments
        if let error = errorToThrow { throw error }
        return resultToReturn
    }
}

// MARK: - Tests

@Suite("AzCLI Tests")
struct AzCLITests {

    @Test("listTenants decodes tenant names without requiring subscriptions",
          arguments: [
            (json: #"{"value":[{"tenantId":"t-1","displayName":"Tenant 1"}]}"#, name: "Tenant 1"),
            (json: #"{"value":[{"tenantId":"t-1","displayName":null,"defaultDomain":"tenant.example.com"}]}"#, name: "tenant.example.com"),
            (json: #"{"value":[{"tenantId":"t-1","displayName":"  ","defaultDomain":"  tenant.example.com  "}]}"#, name: "tenant.example.com"),
            (json: #"{"value":[{"tenantId":"t-1"}]}"#, name: "t-1"),
          ])
    func listTenantsNames(json: String, name: String) async throws {
        let shell = MockShellExecutor()
        shell.resultToReturn = ShellResult(stdout: json, stderr: "", exitCode: 0)
        let cli = AzCLI(shell: shell, azPath: "/usr/local/bin/az")

        let tenants = try await cli.listTenants()

        #expect(tenants.count == 1)
        #expect(tenants.first?.tenantId == "t-1")
        #expect(tenants.first?.name == name)
        #expect(shell.lastExecutable == "/usr/local/bin/az")
        #expect(shell.lastArguments == [
            "rest", "--method", "GET", "--url",
            "https://management.azure.com/tenants?api-version=2022-12-01", "-o", "json"
        ])
    }

    @Test("listTenants follows pages, deduplicates IDs and sorts by name")
    func listTenantsPagination() async throws {
        let nextLink = "https://management.azure.com/tenants?api-version=2022-12-01&$skiptoken=next"
        let shell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: """
            {"value":[{"tenantId":"t-b","displayName":"Beta"}],"nextLink":"\(nextLink)"}
            """, stderr: "", exitCode: 0),
            ShellResult(stdout: """
            {"value":[{"tenantId":"T-B","displayName":"Duplicate"},{"tenantId":"t-a","displayName":"Alpha"}]}
            """, stderr: "", exitCode: 0)
        ])
        let cli = AzCLI(shell: shell, azPath: "/usr/local/bin/az")

        let tenants = try await cli.listTenants()

        #expect(tenants.map(\.tenantId) == ["t-a", "t-b"])
        #expect(tenants.map(\.name) == ["Alpha", "Beta"])
        #expect(shell.allCalls.map(\.arguments) == [
            ["rest", "--method", "GET", "--url", "https://management.azure.com/tenants?api-version=2022-12-01", "-o", "json"],
            ["rest", "--method", "GET", "--url", nextLink, "-o", "json"]
        ])
    }

    @Test("listTenants rejects failed commands and malformed responses",
          arguments: [
            ShellResult(stdout: "", stderr: "Please run 'az login'", exitCode: 1),
            ShellResult(stdout: "not JSON", stderr: "", exitCode: 0),
            ShellResult(stdout: "{}", stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[{"tenantId":""}]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[{"tenantId":null}]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[],"nextLink":"https://example.com/tenants"}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"value":[],"nextLink":"https://management.azure.com/tenants?api-version=2022-12-01"}"#, stderr: "", exitCode: 0),
          ])
    func listTenantsFailure(result: ShellResult) async {
        let shell = MockShellExecutor()
        shell.resultToReturn = result
        let cli = AzCLI(shell: shell, azPath: "/usr/local/bin/az")
        await #expect(throws: AzCLIError.self) {
            try await cli.listTenants()
        }
    }

    @Test("listTenants does not return a partial list when a later page fails")
    func listTenantsLaterPageFailure() async {
        let shell = SequentialMockShellExecutor(results: [
            ShellResult(stdout: """
            {"value":[{"tenantId":"t-1"}],"nextLink":"https://management.azure.com/tenants?api-version=2022-12-01&$skiptoken=next"}
            """, stderr: "", exitCode: 0),
            ShellResult(stdout: "", stderr: "Request failed", exitCode: 1)
        ])
        let cli = AzCLI(shell: shell, azPath: "/usr/local/bin/az")
        await #expect(throws: AzCLIError.self) {
            try await cli.listTenants()
        }
        #expect(shell.allCalls.count == 2)
    }
    
    // MARK: - listSubscriptions Tests
    
    @Test("listSubscriptions parses valid JSON",
          arguments: [
            (json: """
            [{"id":"sub-1","name":"Dev","tenantId":"t-1","isDefault":true,"state":"Enabled","homeTenantId":"t-1","tenantDisplayName":"Tenant 1"}]
            """,
             expectedCount: 1,
             expectedId: "sub-1",
             expectedName: "Dev",
             expectedTenantId: "t-1",
             expectedIsDefault: true),
            (json: """
            [{"id":"sub-1","name":"Dev","tenantId":"t-1","isDefault":true,"state":"Enabled","homeTenantId":"t-1","tenantDisplayName":"Tenant 1"},{"id":"sub-2","name":"Prod","tenantId":"t-2","isDefault":false,"state":"Enabled","homeTenantId":"t-2","tenantDisplayName":"Tenant 2"}]
            """,
             expectedCount: 2,
             expectedId: "sub-1",
             expectedName: "Dev",
             expectedTenantId: "t-1",
             expectedIsDefault: true)
          ])
    func testListSubscriptionsParseValidJSON(
        json: String,
        expectedCount: Int,
        expectedId: String,
        expectedName: String,
        expectedTenantId: String,
        expectedIsDefault: Bool
    ) async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: json, stderr: "", exitCode: 0)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        let subscriptions = try await azCLI.listSubscriptions()
        
        #expect(mock.lastExecutable == "/usr/local/bin/az")
        #expect(mock.lastArguments == ["account", "list", "-o", "json"])
        #expect(subscriptions.count == expectedCount)
        #expect(subscriptions[0].id == expectedId)
        #expect(subscriptions[0].name == expectedName)
        #expect(subscriptions[0].tenantId == expectedTenantId)
        #expect(subscriptions[0].isDefault == expectedIsDefault)
    }
    
    @Test("listSubscriptions throws on invalid JSON")
    func testListSubscriptionsInvalidJSON() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "not valid json", stderr: "", exitCode: 0)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        
        await #expect(throws: Error.self) {
            try await azCLI.listSubscriptions()
        }
    }
    
    @Test("listSubscriptions throws commandFailed on non-zero exit code")
    func testListSubscriptionsCommandFailed() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "", stderr: "Error: not logged in", exitCode: 1)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        
        await #expect(throws: AzCLIError.self) {
            try await azCLI.listSubscriptions()
        }
    }
    
    // MARK: - getSignedInUser Tests
    
    @Test("getSignedInUser parses valid JSON",
          arguments: [
            (json: """
            {"id":"user-principal-id","userPrincipalName":"user@example.com"}
            """,
             expectedId: "user-principal-id",
             expectedUserPrincipalName: "user@example.com"),
            (json: """
            {"id":"another-id","userPrincipalName":"another@example.com","mail":"another@example.com"}
            """,
             expectedId: "another-id",
             expectedUserPrincipalName: "another@example.com")
          ])
    func testGetSignedInUserParseValidJSON(
        json: String,
        expectedId: String,
        expectedUserPrincipalName: String
    ) async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: json, stderr: "", exitCode: 0)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        let user = try await azCLI.getSignedInUser()
        
        #expect(mock.lastExecutable == "/usr/local/bin/az")
        #expect(mock.lastArguments == ["ad", "signed-in-user", "show", "-o", "json"])
        #expect(user.id == expectedId)
        #expect(user.userPrincipalName == expectedUserPrincipalName)
    }
    
    @Test("getSignedInUser throws on invalid JSON")
    func testGetSignedInUserInvalidJSON() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "not valid json", stderr: "", exitCode: 0)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        
        await #expect(throws: Error.self) {
            try await azCLI.getSignedInUser()
        }
    }
    
    // MARK: - login Tests
    
    @Test("login passes correct arguments",
          arguments: ["tenant-1", "tenant-2", "abc-123"])
    func testLoginArguments(tenantId: String) async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "Logged in", stderr: "", exitCode: 0)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        try await azCLI.login(tenantId: tenantId)
        
        #expect(mock.lastExecutable == "/usr/local/bin/az")
        #expect(mock.lastArguments == ["login", "--tenant", tenantId])
    }

    @Test("login passes selected browser only to the login child")
    func testLoginSelectedBrowserArguments() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "Logged in", stderr: "", exitCode: 0)

        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        try await azCLI.login(tenantId: "tenant-1", browserBundleId: "com.google.Chrome")

        #expect(mock.lastExecutable == "/usr/bin/env")
        #expect(mock.lastArguments == [
            "BROWSER=/usr/bin/open -b com.google.Chrome %s",
            "/usr/local/bin/az",
            "login",
            "--tenant",
            "tenant-1",
        ])
    }
    
    @Test("login throws commandFailed on non-zero exit code")
    func testLoginCommandFailed() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "", stderr: "Login failed", exitCode: 1)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        
        await #expect(throws: AzCLIError.self) {
            try await azCLI.login(tenantId: "tenant-1", browserBundleId: "com.microsoft.edgemac")
        }
    }
    
    // MARK: - setSubscription Tests
    
    @Test("setSubscription passes correct arguments",
          arguments: ["sub-1", "sub-2", "abc-123"])
    func testSetSubscriptionArguments(subscriptionId: String) async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "Subscription set", stderr: "", exitCode: 0)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        try await azCLI.setSubscription(id: subscriptionId)
        
        #expect(mock.lastExecutable == "/usr/local/bin/az")
        #expect(mock.lastArguments == ["account", "set", "-s", subscriptionId])
    }
    
    @Test("setSubscription throws commandFailed on non-zero exit code")
    func testSetSubscriptionCommandFailed() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "", stderr: "Subscription not found", exitCode: 1)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        
        await #expect(throws: AzCLIError.self) {
            try await azCLI.setSubscription(id: "sub-1")
        }
    }
    
    // MARK: - checkInstalled Tests
    
    @Test("checkInstalled returns true when az is available")
    func testCheckInstalledSuccess() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "azure-cli 2.0.0", stderr: "", exitCode: 0)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        let isInstalled = await azCLI.checkInstalled()
        
        #expect(isInstalled == true)
        #expect(mock.lastArguments == ["version"])
    }
    
    @Test("checkInstalled returns false when az is not available")
    func testCheckInstalledFailure() async throws {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellResult(stdout: "", stderr: "command not found", exitCode: 127)
        
        let azCLI = AzCLI(shell: mock, azPath: "/usr/local/bin/az")
        let isInstalled = await azCLI.checkInstalled()
        
        #expect(isInstalled == false)
    }
}
