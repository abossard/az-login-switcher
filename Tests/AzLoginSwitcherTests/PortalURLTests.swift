import Testing
import Foundation
@testable import AzLoginSwitcher

struct PortalURLTests {
    
    struct PortalURLTestCase {
        let tenantId: String
        let subscriptionId: String?
        let expectedURL: String
    }
    
    @Test("Portal URL generation", arguments: [
        PortalURLTestCase(
            tenantId: "abc-123",
            subscriptionId: nil,
            expectedURL: "https://portal.azure.com/#@abc-123/home"
        ),
        PortalURLTestCase(
            tenantId: "abc-123",
            subscriptionId: "def-456",
            expectedURL: "https://portal.azure.com/#@abc-123/resource/subscriptions/def-456/overview"
        ),
        PortalURLTestCase(
            tenantId: "12345678-1234-1234-1234-123456789abc",
            subscriptionId: nil,
            expectedURL: "https://portal.azure.com/#@12345678-1234-1234-1234-123456789abc/home"
        ),
        PortalURLTestCase(
            tenantId: "12345678-1234-1234-1234-123456789abc",
            subscriptionId: "87654321-4321-4321-4321-cba987654321",
            expectedURL: "https://portal.azure.com/#@12345678-1234-1234-1234-123456789abc/resource/subscriptions/87654321-4321-4321-4321-cba987654321/overview"
        )
    ])
    func testPortalURLGeneration(testCase: PortalURLTestCase) throws {
        let actualURL: URL
        
        if let subscriptionId = testCase.subscriptionId {
            actualURL = PortalURL.portalURL(tenantId: testCase.tenantId, subscriptionId: subscriptionId)
        } else {
            actualURL = PortalURL.portalURL(tenantId: testCase.tenantId)
        }
        
        let expectedURL = URL(string: testCase.expectedURL)!
        
        #expect(actualURL == expectedURL)
        #expect(actualURL.absoluteString == testCase.expectedURL)
    }
    
    @Test("Portal URLs are valid")
    func testPortalURLsAreValid() throws {
        let tenantOnlyURL = PortalURL.portalURL(tenantId: "test-tenant")
        #expect(tenantOnlyURL.scheme == "https")
        #expect(tenantOnlyURL.host == "portal.azure.com")
        
        let subscriptionURL = PortalURL.portalURL(tenantId: "test-tenant", subscriptionId: "test-sub")
        #expect(subscriptionURL.scheme == "https")
        #expect(subscriptionURL.host == "portal.azure.com")
    }
}
