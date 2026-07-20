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
