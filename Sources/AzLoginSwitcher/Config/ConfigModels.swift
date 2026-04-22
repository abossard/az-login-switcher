import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public let tenants: [TenantConfig]
    
    public init(tenants: [TenantConfig]) {
        self.tenants = tenants
    }
}

public struct TenantConfig: Codable, Equatable, Sendable {
    public let name: String
    public let tenantId: String
    public let subscriptions: [SubscriptionConfig]
    public let pim: PIMConfig?
    
    public init(name: String, tenantId: String, subscriptions: [SubscriptionConfig], pim: PIMConfig? = nil) {
        self.name = name
        self.tenantId = tenantId
        self.subscriptions = subscriptions
        self.pim = pim
    }
}

public struct SubscriptionConfig: Codable, Equatable, Sendable {
    public let name: String
    public let id: String
    
    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }
}

public struct PIMConfig: Codable, Equatable, Sendable {
    public let justification: String
    public let duration: String
    
    public init(justification: String, duration: String) {
        self.justification = justification
        self.duration = duration
    }
}
