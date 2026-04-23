import Foundation

/// Per-tenant cached data — a projection, not an FSM.
/// Tracks what we know about each tenant from previous actions.
struct TenantCache: Sendable {
    var isLoggedIn: Bool = false
    var loginAt: Date?
    var allDiscoveredSubscriptions: [AzSubscription] = []
    var activeSubscription: AzSubscription?
    var subscriptionSetAt: Date?
    var eligiblePIMRoles: [PIMEligibleRole] = []
    var pimRoleStatuses: [String: PIMRoleStatusEntry] = [:]
    var signedInUser: AzUser?
}

/// PIM role status with timestamp for relative time display
struct PIMRoleStatusEntry: Equatable, Sendable {
    var status: PIMRoleStatus
    var updatedAt: Date
    
    static func idle() -> PIMRoleStatusEntry {
        PIMRoleStatusEntry(status: .idle, updatedAt: Date())
    }
}
