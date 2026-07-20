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
    var loginAt: Date?
    var allDiscoveredSubscriptions: [AzSubscription] = []
    var activeSubscription: AzSubscription?
    var subscriptionSetAt: Date?
    var eligiblePIMRoles: [PIMEligibleRole] = []
    var pimRoleStatuses: [String: PIMRoleStatusEntry] = [:]
    var signedInUser: AzUser?
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
