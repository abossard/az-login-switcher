import Foundation

// MARK: - PIM Role Status

enum PIMRoleStatus: Equatable, Sendable, Codable {
    case idle
    case activating
    case active(expires: String?)
    case failed(String)
}

// MARK: - Tenant Cache

/// Per-tenant cached data — a projection, not an FSM.
/// Tracks what we know about each tenant from previous actions.
/// Codable for persistence across app restarts.
struct TenantCache: Sendable, Codable {
    var isLoggedIn: Bool = false
    var loginAt: Date?
    var allDiscoveredSubscriptions: [AzSubscription] = []
    var activeSubscription: AzSubscription?
    var subscriptionSetAt: Date?
    var eligiblePIMRoles: [PIMEligibleRole] = []
    var pimRoleStatuses: [String: PIMRoleStatusEntry] = [:]
    var signedInUser: AzUser?
    
    static let staleAfter: TimeInterval = 12 * 60 * 60  // 12 hours
    
    /// Login is stale if older than 12 hours
    var isStale: Bool {
        guard let loginAt else { return true }
        return Date().timeIntervalSince(loginAt) > Self.staleAfter
    }
    
    /// Effective login status: stale logins are treated as not logged in
    var effectivelyLoggedIn: Bool {
        isLoggedIn && !isStale
    }
}

/// PIM role status with timestamp for relative time display
struct PIMRoleStatusEntry: Equatable, Sendable, Codable {
    var status: PIMRoleStatus
    var updatedAt: Date
    
    static func idle() -> PIMRoleStatusEntry {
        PIMRoleStatusEntry(status: .idle, updatedAt: Date())
    }
}

// MARK: - Persisted State (saved to disk)

struct PersistedState: Codable {
    var tenantCaches: [String: TenantCache]
    var azureContext: AzureContext
    var savedAt: Date
    
    static let filePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".az-login-switcher-state.json").path
    }()
    
    static func load() -> PersistedState? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
    
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        FileManager.default.createFile(atPath: Self.filePath, contents: data)
    }
}
