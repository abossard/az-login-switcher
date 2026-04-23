import Foundation

/// The ACTUAL current global Azure CLI context.
/// az CLI has ONE context — this is the source of truth, separate from per-tenant cache.
struct AzureContext: Equatable, Sendable {
    var currentTenantId: String?
    var currentSubscriptionId: String?
    var currentSubscriptionName: String?
    var currentUser: String?
    var lastUpdated: Date?
    
    /// True if az CLI has an active session
    var isAuthenticated: Bool { currentTenantId != nil }
    
    /// Reset to empty (e.g., after logout)
    static let empty = AzureContext()
}
