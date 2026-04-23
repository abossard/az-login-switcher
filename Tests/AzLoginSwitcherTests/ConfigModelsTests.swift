import XCTest
import Yams
@testable import AzLoginSwitcher

final class ConfigModelsTests: XCTestCase {
    
    struct TestCase<T: Codable & Equatable> {
        let name: String
        let yaml: String
        let expected: Result<T, ConfigError>
        
        init(name: String, yaml: String, expected: T) {
            self.name = name
            self.yaml = yaml
            self.expected = .success(expected)
        }
        
        init(name: String, yaml: String, expectedError: ConfigError) {
            self.name = name
            self.yaml = yaml
            self.expected = .failure(expectedError)
        }
    }
    
    // MARK: - Test Data
    
    func validFullConfigTestCases() -> [TestCase<AppConfig>] {
        return [
            TestCase(
                name: "Valid full config with PIM",
                yaml: """
                tenants:
                  - name: "Dev Testing"
                    tenantId: "aabbccdd-1111-2222-3333-444455556666"
                    subscriptions:
                      - name: "Dev Sub"
                        id: "11111111-aaaa-bbbb-cccc-ddddeeee0001"
                      - name: "Prod Sub"
                        id: "11111111-aaaa-bbbb-cccc-ddddeeee0002"
                    pim:
                      justification: "dev testing"
                      duration: "PT8H"
                """,
                expected: AppConfig(
                    tenants: [
                        TenantConfig(
                            name: "Dev Testing",
                            tenantId: "aabbccdd-1111-2222-3333-444455556666",
                            subscriptions: [
                                SubscriptionConfig(name: "Dev Sub", id: "11111111-aaaa-bbbb-cccc-ddddeeee0001"),
                                SubscriptionConfig(name: "Prod Sub", id: "11111111-aaaa-bbbb-cccc-ddddeeee0002")
                            ],
                            pim: PIMConfig(justification: "dev testing", duration: "PT8H")
                        )
                    ]
                )
            )
        ]
    }
    
    func validMinimalConfigTestCases() -> [TestCase<AppConfig>] {
        return [
            TestCase(
                name: "Minimal config without PIM",
                yaml: """
                tenants:
                  - name: "Simple Tenant"
                    tenantId: "abc-123"
                    subscriptions:
                      - name: "Only Sub"
                        id: "sub-456"
                """,
                expected: AppConfig(
                    tenants: [
                        TenantConfig(
                            name: "Simple Tenant",
                            tenantId: "abc-123",
                            subscriptions: [
                                SubscriptionConfig(name: "Only Sub", id: "sub-456")
                            ],
                            pim: nil
                        )
                    ]
                )
            )
        ]
    }
    
    func multipleTenantTestCases() -> [TestCase<AppConfig>] {
        return [
            TestCase(
                name: "Multiple tenants with multiple subscriptions",
                yaml: """
                tenants:
                  - name: "Tenant A"
                    tenantId: "tenant-a-id"
                    subscriptions:
                      - name: "Sub A1"
                        id: "sub-a1-id"
                      - name: "Sub A2"
                        id: "sub-a2-id"
                  - name: "Tenant B"
                    tenantId: "tenant-b-id"
                    subscriptions:
                      - name: "Sub B1"
                        id: "sub-b1-id"
                    pim:
                      justification: "testing tenant B"
                      duration: "PT4H"
                """,
                expected: AppConfig(
                    tenants: [
                        TenantConfig(
                            name: "Tenant A",
                            tenantId: "tenant-a-id",
                            subscriptions: [
                                SubscriptionConfig(name: "Sub A1", id: "sub-a1-id"),
                                SubscriptionConfig(name: "Sub A2", id: "sub-a2-id")
                            ],
                            pim: nil
                        ),
                        TenantConfig(
                            name: "Tenant B",
                            tenantId: "tenant-b-id",
                            subscriptions: [
                                SubscriptionConfig(name: "Sub B1", id: "sub-b1-id")
                            ],
                            pim: PIMConfig(justification: "testing tenant B", duration: "PT4H")
                        )
                    ]
                )
            )
        ]
    }
    
    // MARK: - Decoding Tests
    
    func testValidFullConfigDecoding() throws {
        for testCase in validFullConfigTestCases() {
            let decoder = YAMLDecoder()
            let decoded = try decoder.decode(AppConfig.self, from: testCase.yaml)
            
            guard case .success(let expected) = testCase.expected else {
                XCTFail("\(testCase.name): Expected success but test case configured with error")
                continue
            }
            
            XCTAssertEqual(decoded, expected, "\(testCase.name) failed")
        }
    }
    
    func testValidMinimalConfigDecoding() throws {
        for testCase in validMinimalConfigTestCases() {
            let decoder = YAMLDecoder()
            let decoded = try decoder.decode(AppConfig.self, from: testCase.yaml)
            
            guard case .success(let expected) = testCase.expected else {
                XCTFail("\(testCase.name): Expected success but test case configured with error")
                continue
            }
            
            XCTAssertEqual(decoded, expected, "\(testCase.name) failed")
        }
    }
    
    func testMultipleTenantDecoding() throws {
        for testCase in multipleTenantTestCases() {
            let decoder = YAMLDecoder()
            let decoded = try decoder.decode(AppConfig.self, from: testCase.yaml)
            
            guard case .success(let expected) = testCase.expected else {
                XCTFail("\(testCase.name): Expected success but test case configured with error")
                continue
            }
            
            XCTAssertEqual(decoded, expected, "\(testCase.name) failed")
        }
    }
    
    // MARK: - Validation Tests
    
    func testValidationEmptySubscriptions() throws {
        let yaml = """
        tenants:
          - name: "Empty Tenant"
            tenantId: "tenant-id"
            subscriptions: []
        """
        
        let decoder = YAMLDecoder()
        let config = try decoder.decode(AppConfig.self, from: yaml)
        let result = ConfigLoader.validate(config: config)
        
        // Empty subscriptions are now allowed — discovered dynamically after login
        guard case .success = result else {
            XCTFail("Empty subscriptions should be valid")
            return
        }
    }
    
    func testValidationEmptyTenantId() throws {
        let yaml = """
        tenants:
          - name: "No ID Tenant"
            tenantId: ""
            subscriptions:
              - name: "Sub"
                id: "sub-id"
        """
        
        let decoder = YAMLDecoder()
        let config = try decoder.decode(AppConfig.self, from: yaml)
        let result = ConfigLoader.validate(config: config)
        
        guard case .failure(let error) = result else {
            XCTFail("Expected validation error for empty tenantId")
            return
        }
        
        guard case .validationError(let message) = error else {
            XCTFail("Expected validationError, got \(error)")
            return
        }
        
        XCTAssertTrue(message.contains("tenantId"), "Error message should mention tenantId: \(message)")
    }
    
    // MARK: - ConfigLoader Integration Tests
    
    func testConfigLoaderDefaultPath() {
        let path = ConfigLoader.defaultConfigPath()
        XCTAssertTrue(path.contains(".az-login-switcher.yaml"), "Default path should contain config filename")
        XCTAssertFalse(path.contains("~"), "Default path should have ~ expanded")
    }
    
    func testConfigLoaderFileNotFound() {
        let result = ConfigLoader.loadConfig(from: "/nonexistent/path/config.yaml")
        
        guard case .failure(let error) = result else {
            XCTFail("Expected fileNotFound error")
            return
        }
        
        guard case .fileNotFound = error else {
            XCTFail("Expected fileNotFound error, got \(error)")
            return
        }
    }
    
    func testConfigLoaderInvalidYAML() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("invalid-\(UUID().uuidString).yaml")
        
        let invalidYAML = "this is not: valid: yaml: [unclosed"
        try invalidYAML.write(to: tempFile, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        let result = ConfigLoader.loadConfig(from: tempFile.path)
        
        guard case .failure(let error) = result else {
            XCTFail("Expected parseError")
            return
        }
        
        guard case .parseError = error else {
            XCTFail("Expected parseError, got \(error)")
            return
        }
    }
    
    func testConfigLoaderValidConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("valid-\(UUID().uuidString).yaml")
        
        let validYAML = """
        tenants:
          - name: "Test Tenant"
            tenantId: "test-id"
            subscriptions:
              - name: "Test Sub"
                id: "sub-id"
        """
        try validYAML.write(to: tempFile, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        let result = ConfigLoader.loadConfig(from: tempFile.path)
        
        guard case .success(let config) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        
        XCTAssertEqual(config.tenants.count, 1)
        XCTAssertEqual(config.tenants[0].name, "Test Tenant")
    }
    
    func testConfigLoaderValidationFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("invalid-config-\(UUID().uuidString).yaml")
        
        let invalidConfigYAML = """
        tenants:
          - name: "Empty Subs"
            tenantId: "test-id"
            subscriptions: []
        """
        try invalidConfigYAML.write(to: tempFile, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        let result = ConfigLoader.loadConfig(from: tempFile.path)
        
        guard case .failure(let error) = result else {
            XCTFail("Expected validation error")
            return
        }
        
        guard case .validationError = error else {
            XCTFail("Expected validationError, got \(error)")
            return
        }
    }
}
