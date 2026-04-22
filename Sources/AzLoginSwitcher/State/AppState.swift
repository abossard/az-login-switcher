import Foundation
import SwiftUI

enum LoginStatus: Equatable, Sendable {
    case idle
    case loggingIn
    case loggedIn
    case failed(String)
}

enum PIMRoleStatus: Equatable, Sendable {
    case idle
    case activating
    case active(expires: String?)
    case failed(String)
}

struct TenantSession: Sendable {
    var loginStatus: LoginStatus = .idle
    var subscriptions: [AzSubscription] = []
    var activeSubscription: AzSubscription? = nil
    var eligiblePIMRoles: [PIMEligibleRole] = []
    var pimRoleStatuses: [String: PIMRoleStatus] = [:]
    var signedInUser: AzUser? = nil
}

@MainActor
@Observable
final class AppState {
    var config: AppConfig?
    var configError: String?
    var tenantSessions: [String: TenantSession] = [:]

    private let azCLI: AzCLI
    private let pimService: PIMService
    private let urlOpener: URLOpening
    private let loginLauncher: LoginLaunching

    init(azCLI: AzCLI, pimService: PIMService, urlOpener: URLOpening, loginLauncher: LoginLaunching) {
        self.azCLI = azCLI
        self.pimService = pimService
        self.urlOpener = urlOpener
        self.loginLauncher = loginLauncher
    }

    func loadConfig() {
        let result = ConfigLoader.loadConfig(from: ConfigLoader.defaultConfigPath())
        switch result {
        case .success(let appConfig):
            config = appConfig
            configError = nil
        case .failure(let error):
            configError = error.localizedDescription
            config = nil
        }
    }

    /// One-click: login to tenant + select a specific subscription
    func loginAndSelectSubscription(_ subscription: SubscriptionConfig, tenant: TenantConfig, useTerminal: Bool = false) async {
        // Login first if not already logged in
        let currentStatus = tenantSessions[tenant.tenantId]?.loginStatus
        if currentStatus != .loggedIn {
            await loginToTenant(tenant, useTerminal: useTerminal)
            guard tenantSessions[tenant.tenantId]?.loginStatus == .loggedIn else { return }
        }
        // Then select the subscription
        await setActiveSubscription(subscription, tenantId: tenant.tenantId)
    }

    func loginToTenant(_ tenant: TenantConfig, useTerminal: Bool = false) async {
        if tenantSessions[tenant.tenantId]?.loginStatus == .loggingIn {
            return
        }

        ensureSession(for: tenant.tenantId)
        tenantSessions[tenant.tenantId]!.loginStatus = .loggingIn

        if useTerminal {
            do {
                try await loginLauncher.launchInTerminal(
                    command: "az",
                    arguments: ["login", "--tenant", tenant.tenantId]
                )
            } catch {
                // Can't reliably track terminal login result
            }
            tenantSessions[tenant.tenantId]!.loginStatus = .loggedIn
            return
        }

        do {
            try await azCLI.login(tenantId: tenant.tenantId)
            tenantSessions[tenant.tenantId]!.loginStatus = .loggedIn

            // Auto-discover subscriptions if filter is set and no subscriptions configured
            var activeTenant = tenant
            if let filter = tenant.subscriptionFilter, !filter.isEmpty {
                let discovered = await discoverSubscriptions(tenantId: tenant.tenantId, filter: filter)
                if !discovered.isEmpty {
                    activeTenant = updateTenantSubscriptions(tenant: tenant, discovered: discovered)
                }
            }

            // Auto-select first subscription
            if let firstSub = activeTenant.subscriptions.first {
                try await azCLI.setSubscription(id: firstSub.id)
                tenantSessions[tenant.tenantId]!.activeSubscription = AzSubscription(
                    id: firstSub.id,
                    name: firstSub.name,
                    tenantId: tenant.tenantId,
                    isDefault: true,
                    state: "Enabled",
                    homeTenantId: nil,
                    tenantDisplayName: nil
                )
            }

            // Get signed-in user
            let user = try await azCLI.getSignedInUser()
            tenantSessions[tenant.tenantId]!.signedInUser = user

            // Discover PIM roles for each subscription
            var allRoles: [PIMEligibleRole] = []
            for sub in activeTenant.subscriptions {
                do {
                    let roles = try await pimService.discoverEligibleRoles(subscriptionId: sub.id)
                    allRoles.append(contentsOf: roles)
                } catch {
                    // Continue discovering roles for remaining subscriptions
                }
            }

            tenantSessions[tenant.tenantId]!.eligiblePIMRoles = allRoles
            var statuses: [String: PIMRoleStatus] = [:]
            for role in allRoles {
                statuses[role.id] = .idle
            }
            tenantSessions[tenant.tenantId]!.pimRoleStatuses = statuses

        } catch {
            tenantSessions[tenant.tenantId]!.loginStatus = .failed(error.localizedDescription)
        }
    }

    func setActiveSubscription(_ subscription: SubscriptionConfig, tenantId: String) async {
        ensureSession(for: tenantId)
        do {
            try await azCLI.setSubscription(id: subscription.id)
            tenantSessions[tenantId]!.activeSubscription = AzSubscription(
                id: subscription.id,
                name: subscription.name,
                tenantId: tenantId,
                isDefault: true,
                state: "Enabled",
                homeTenantId: nil,
                tenantDisplayName: nil
            )
        } catch {
            // Subscription switch failed; state unchanged
        }
    }

    func activatePIMRole(_ role: PIMEligibleRole, for tenant: TenantConfig) async {
        let tenantId = tenant.tenantId
        ensureSession(for: tenantId)

        guard let principalId = tenantSessions[tenantId]?.signedInUser?.id else { return }

        let justification = tenant.pim?.justification ?? "Development work"
        let duration = tenant.pim?.duration ?? "PT8H"
        let subscriptionId = extractSubscriptionId(from: role.scope) ?? ""

        tenantSessions[tenantId]!.pimRoleStatuses[role.id] = .activating

        do {
            let result = try await pimService.activateRole(
                subscriptionId: subscriptionId,
                role: role,
                principalId: principalId,
                justification: justification,
                duration: duration
            )
            tenantSessions[tenantId]!.pimRoleStatuses[role.id] = .active(expires: result.expiresAt)
        } catch {
            tenantSessions[tenantId]!.pimRoleStatuses[role.id] = .failed(error.localizedDescription)
        }
    }

    func openPortal(tenantId: String, subscriptionId: String?) {
        let url: URL
        if let subscriptionId {
            url = PortalURL.portalURL(tenantId: tenantId, subscriptionId: subscriptionId)
        } else {
            url = PortalURL.portalURL(tenantId: tenantId)
        }
        urlOpener.open(url)
    }

    func session(for tenantId: String) -> TenantSession {
        tenantSessions[tenantId] ?? TenantSession()
    }

    // MARK: - Private

    private func ensureSession(for tenantId: String) {
        if tenantSessions[tenantId] == nil {
            tenantSessions[tenantId] = TenantSession()
        }
    }

    private func extractSubscriptionId(from scope: String) -> String? {
        let components = scope.split(separator: "/")
        guard let index = components.firstIndex(of: "subscriptions"),
              index + 1 < components.count else {
            return nil
        }
        return String(components[index + 1])
    }

    /// Discover subscriptions via `az account list`, filter by name prefix
    private func discoverSubscriptions(tenantId: String, filter: String) async -> [SubscriptionConfig] {
        do {
            let allSubs = try await azCLI.listSubscriptions()
            let matching = allSubs
                .filter { $0.tenantId == tenantId && $0.name.localizedCaseInsensitiveContains(filter) }
                .map { SubscriptionConfig(name: $0.name, id: $0.id) }
            return matching
        } catch {
            return []
        }
    }

    /// Merge discovered subscriptions into tenant config and save back to YAML
    private func updateTenantSubscriptions(tenant: TenantConfig, discovered: [SubscriptionConfig]) -> TenantConfig {
        guard var currentConfig = config else { return tenant }

        // Merge: keep existing, add new discoveries
        var existingIds = Set(tenant.subscriptions.map(\.id))
        var merged = tenant.subscriptions
        for sub in discovered {
            if !existingIds.contains(sub.id) {
                merged.append(sub)
                existingIds.insert(sub.id)
            }
        }

        var updatedTenant = tenant
        updatedTenant.subscriptions = merged

        // Update config in memory
        if let idx = currentConfig.tenants.firstIndex(where: { $0.tenantId == tenant.tenantId }) {
            currentConfig.tenants[idx] = updatedTenant
            config = currentConfig
            // Persist to disk
            ConfigLoader.saveConfig(currentConfig)
        }

        return updatedTenant
    }
}
