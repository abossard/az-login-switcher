import Foundation

enum PortalURL {
    static func portalURL(tenantId: String) -> URL {
        URL(string: "https://portal.azure.com/#@\(tenantId)/home")!
    }
    
    static func portalURL(tenantId: String, subscriptionId: String) -> URL {
        URL(string: "https://portal.azure.com/#@\(tenantId)/resource/subscriptions/\(subscriptionId)/overview")!
    }
}
