import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public var tenants: [TenantConfig]
    
    public init(tenants: [TenantConfig]) {
        self.tenants = tenants
    }
}

public struct TenantConfig: Codable, Equatable, Sendable {
    public let name: String
    public let tenantId: String
    public var subscriptions: [SubscriptionConfig]
    public let pim: PIMConfig?
    public var subscriptionFilter: String?
    
    public init(name: String, tenantId: String, subscriptions: [SubscriptionConfig], pim: PIMConfig? = nil, subscriptionFilter: String? = nil) {
        self.name = name
        self.tenantId = tenantId
        self.subscriptions = subscriptions
        self.pim = pim
        self.subscriptionFilter = subscriptionFilter
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
