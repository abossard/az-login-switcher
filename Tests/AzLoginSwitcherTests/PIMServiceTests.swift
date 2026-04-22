import XCTest
@testable import AzLoginSwitcher

final class PIMServiceTests: XCTestCase {
    
    // MARK: - Mock
    
    final class MockShellExecutor: ShellExecuting, @unchecked Sendable {
        var calls: [(executable: String, arguments: [String])] = []
        var resultsQueue: [ShellResult] = []
        var errorToThrow: Error?
        
        func run(executable: String, arguments: [String]) async throws -> ShellResult {
            calls.append((executable, arguments))
            if let error = errorToThrow { throw error }
            guard !resultsQueue.isEmpty else { return ShellResult(stdout: "", stderr: "", exitCode: 0) }
            return resultsQueue.removeFirst()
        }
    }
    
    // MARK: - Discovery Tests
    
    func testDiscoverEligibleRoles_withValidResponse_parsesCorrectly() async throws {
        let testCases: [(name: String, json: String, expected: [PIMEligibleRole])] = [
            (
                "single role",
                """
                {"value":[{"id":"/subscriptions/sub-1/providers/Microsoft.Authorization/roleEligibilityScheduleInstances/inst-1","properties":{"roleDefinitionId":"/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635","scope":"/subscriptions/sub-1","principalId":"user-1","roleEligibilityScheduleId":"sched-1"}}]}
                """,
                [PIMEligibleRole(
                    id: "/subscriptions/sub-1/providers/Microsoft.Authorization/roleEligibilityScheduleInstances/inst-1",
                    roleDefinitionId: "/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
                    scope: "/subscriptions/sub-1",
                    principalId: "user-1",
                    scheduleId: "sched-1",
                    roleName: nil
                )]
            ),
            (
                "multiple roles",
                """
                {"value":[
                    {"id":"id-1","properties":{"roleDefinitionId":"role-1","scope":"scope-1","principalId":"user-1","roleEligibilityScheduleId":"sched-1"}},
                    {"id":"id-2","properties":{"roleDefinitionId":"role-2","scope":"scope-2","principalId":"user-1","roleEligibilityScheduleId":"sched-2"}}
                ]}
                """,
                [
                    PIMEligibleRole(id: "id-1", roleDefinitionId: "role-1", scope: "scope-1", principalId: "user-1", scheduleId: "sched-1", roleName: nil),
                    PIMEligibleRole(id: "id-2", roleDefinitionId: "role-2", scope: "scope-2", principalId: "user-1", scheduleId: "sched-2", roleName: nil)
                ]
            )
        ]
        
        for testCase in testCases {
            let mock = MockShellExecutor()
            mock.resultsQueue = [ShellResult(stdout: testCase.json, stderr: "", exitCode: 0)]
            let service = PIMService(shell: mock, azPath: "/usr/bin/az")
            
            let result = try await service.discoverEligibleRoles(subscriptionId: "sub-1")
            
            XCTAssertEqual(result, testCase.expected, "Failed for case: \(testCase.name)")
            XCTAssertEqual(mock.calls.count, 1, "Failed for case: \(testCase.name)")
            XCTAssertEqual(mock.calls[0].executable, "/usr/bin/az", "Failed for case: \(testCase.name)")
            XCTAssertEqual(mock.calls[0].arguments[0], "rest", "Failed for case: \(testCase.name)")
            XCTAssertEqual(mock.calls[0].arguments[1], "--method", "Failed for case: \(testCase.name)")
            XCTAssertEqual(mock.calls[0].arguments[2], "GET", "Failed for case: \(testCase.name)")
            XCTAssertTrue(mock.calls[0].arguments[4].contains("sub-1"), "Failed for case: \(testCase.name)")
        }
    }
    
    func testDiscoverEligibleRoles_withEmptyResponse_returnsEmptyArray() async throws {
        let mock = MockShellExecutor()
        mock.resultsQueue = [ShellResult(stdout: "{\"value\":[]}", stderr: "", exitCode: 0)]
        let service = PIMService(shell: mock, azPath: "/usr/bin/az")
        
        let result = try await service.discoverEligibleRoles(subscriptionId: "sub-1")
        
        XCTAssertEqual(result, [])
    }
    
    func testDiscoverEligibleRoles_withError_throwsError() async {
        let mock = MockShellExecutor()
        mock.resultsQueue = [ShellResult(stdout: "", stderr: "Error", exitCode: 1)]
        let service = PIMService(shell: mock, azPath: "/usr/bin/az")
        
        do {
            _ = try await service.discoverEligibleRoles(subscriptionId: "sub-1")
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected
        }
    }
    
    // MARK: - Activation Tests
    
    func testActivateRole_buildsCorrectRequest() async throws {
        let mock = MockShellExecutor()
        let responseJson = """
        {
            "properties": {
                "status": "Granted",
                "scheduleInfo": {
                    "expiration": {
                        "endDateTime": "2024-01-01T12:00:00Z"
                    }
                }
            }
        }
        """
        mock.resultsQueue = [ShellResult(stdout: responseJson, stderr: "", exitCode: 0)]
        let service = PIMService(shell: mock, azPath: "/usr/bin/az")
        
        let role = PIMEligibleRole(
            id: "id-1",
            roleDefinitionId: "role-def-1",
            scope: "scope-1",
            principalId: "user-1",
            scheduleId: "sched-1",
            roleName: nil
        )
        
        let result = try await service.activateRole(
            subscriptionId: "sub-1",
            role: role,
            principalId: "principal-1",
            justification: "test justification",
            duration: "PT8H"
        )
        
        XCTAssertEqual(result.status, "Granted")
        XCTAssertEqual(result.expiresAt, "2024-01-01T12:00:00Z")
        
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].executable, "/usr/bin/az")
        XCTAssertEqual(mock.calls[0].arguments[0], "rest")
        XCTAssertEqual(mock.calls[0].arguments[1], "--method")
        XCTAssertEqual(mock.calls[0].arguments[2], "PUT")
        
        let urlArg = mock.calls[0].arguments[4]
        XCTAssertTrue(urlArg.contains("sub-1"), "URL should contain subscription ID")
        XCTAssertTrue(urlArg.contains("roleAssignmentScheduleRequests"), "URL should contain roleAssignmentScheduleRequests")
        
        let bodyArg = mock.calls[0].arguments[6]
        XCTAssertTrue(bodyArg.contains("SelfActivate"), "Body should contain SelfActivate")
        XCTAssertTrue(bodyArg.contains("test justification"), "Body should contain justification")
        XCTAssertTrue(bodyArg.contains("PT8H"), "Body should contain duration")
        XCTAssertTrue(bodyArg.contains("principal-1"), "Body should contain principalId")
        XCTAssertTrue(bodyArg.contains("role-def-1"), "Body should contain roleDefinitionId")
        XCTAssertTrue(bodyArg.contains("sched-1"), "Body should contain scheduleId")
    }
    
    func testActivateRole_withError_throwsError() async {
        let mock = MockShellExecutor()
        mock.resultsQueue = [ShellResult(stdout: "", stderr: "Activation failed", exitCode: 1)]
        let service = PIMService(shell: mock, azPath: "/usr/bin/az")
        
        let role = PIMEligibleRole(
            id: "id-1",
            roleDefinitionId: "role-def-1",
            scope: "scope-1",
            principalId: "user-1",
            scheduleId: "sched-1",
            roleName: nil
        )
        
        do {
            _ = try await service.activateRole(
                subscriptionId: "sub-1",
                role: role,
                principalId: "principal-1",
                justification: "test",
                duration: "PT8H"
            )
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected
        }
    }
    
    // MARK: - Active Assignments Tests
    
    func testListActiveAssignments_parsesCorrectly() async throws {
        let testCases: [(name: String, json: String, expected: [PIMActiveRole])] = [
            (
                "single active assignment",
                """
                {"value":[{
                    "properties": {
                        "roleDefinitionId": "role-1",
                        "scope": "scope-1",
                        "status": "Accepted",
                        "assignmentType": "Activated",
                        "endDateTime": "2024-01-01T12:00:00Z"
                    }
                }]}
                """,
                [PIMActiveRole(
                    roleDefinitionId: "role-1",
                    scope: "scope-1",
                    status: "Accepted",
                    endDateTime: "2024-01-01T12:00:00Z"
                )]
            ),
            (
                "filters out non-activated",
                """
                {"value":[
                    {"properties": {"roleDefinitionId": "role-1", "scope": "scope-1", "status": "Accepted", "assignmentType": "Activated", "endDateTime": "2024-01-01T12:00:00Z"}},
                    {"properties": {"roleDefinitionId": "role-2", "scope": "scope-2", "status": "Accepted", "assignmentType": "Assigned"}}
                ]}
                """,
                [PIMActiveRole(
                    roleDefinitionId: "role-1",
                    scope: "scope-1",
                    status: "Accepted",
                    endDateTime: "2024-01-01T12:00:00Z"
                )]
            ),
            (
                "empty response",
                "{\"value\":[]}",
                []
            )
        ]
        
        for testCase in testCases {
            let mock = MockShellExecutor()
            mock.resultsQueue = [ShellResult(stdout: testCase.json, stderr: "", exitCode: 0)]
            let service = PIMService(shell: mock, azPath: "/usr/bin/az")
            
            let result = try await service.listActiveAssignments(subscriptionId: "sub-1")
            
            XCTAssertEqual(result, testCase.expected, "Failed for case: \(testCase.name)")
            XCTAssertEqual(mock.calls.count, 1, "Failed for case: \(testCase.name)")
            XCTAssertTrue(mock.calls[0].arguments[4].contains("roleAssignmentScheduleInstances"), "Failed for case: \(testCase.name)")
        }
    }
}
