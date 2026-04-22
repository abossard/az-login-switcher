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

            // Auto-select first subscription
            if let firstSub = tenant.subscriptions.first {
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
            for sub in tenant.subscriptions {
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
}
