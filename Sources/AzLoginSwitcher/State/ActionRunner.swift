import Foundation
import SwiftUI

// MARK: - FSM States

enum FSMState: Equatable {
    case idle
    case busy(AzAction)
    case awaitingExternalLogin(tenantId: String)
}

// MARK: - Events

enum AppEvent: Sendable {
    case loadConfig
    case login(TenantConfig)
    case loginInTerminal(TenantConfig)
    case logout(tenantId: String)
    case logoutAll
    case selectSubscription(SubscriptionConfig, tenantId: String)
    case activatePIM(PIMEligibleRole, TenantConfig)
    case openPortal(tenantId: String, subscriptionId: String, browserBundleId: String)
    case openPortalDefault(tenantId: String, subscriptionId: String)
    case toggleSubscriptionExposure(AzSubscription, tenantId: String)
    case openLogFolder
    case reloadBrowsers
    case refreshAfterExternalLogin(tenantId: String)
}

// MARK: - ActionRunner

@MainActor
@Observable
final class ActionRunner {
    // MARK: - FSM State (read-only to views)
    private(set) var fsmState: FSMState = .idle

    // MARK: - Projections (read-only to views)
    private(set) var config: AppConfig?
    private(set) var configError: String?
    private(set) var tenantCaches: [String: TenantCache] = [:]
    private(set) var azureContext: AzureContext = .empty
    private(set) var actionHistory: [AzAction] = []
    private(set) var availableBrowsers: [BrowserInfo] = []

    // MARK: - Computed
    var isBusy: Bool { fsmState != .idle }
    var currentAction: AzAction? {
        if case .busy(let action) = fsmState { return action }
        return nil
    }
    var isAwaitingExternalLogin: Bool {
        if case .awaitingExternalLogin = fsmState { return true }
        return false
    }

    // MARK: - Dependencies
    private let azCLI: AzCLI
    private let pimService: PIMService
    private let loginLauncher: LoginLaunching
    private let logger: ActionLogger
    private var currentTask: Task<Void, Never>?

    init(azCLI: AzCLI, pimService: PIMService, loginLauncher: LoginLaunching, logger: ActionLogger) {
        self.azCLI = azCLI
        self.pimService = pimService
        self.loginLauncher = loginLauncher
        self.logger = logger
    }

    // MARK: - Single Entry Point

    func send(_ event: AppEvent) {
        switch event {
        case .loadConfig:
            handleLoadConfig()

        case .login(let tenant):
            guard !isBusy else { return }
            startAction(.login(tenantId: tenant.tenantId, tenantName: tenant.name)) { [self] action in
                await self.executeLogin(action: action, tenant: tenant)
            }

        case .loginInTerminal(let tenant):
            guard !isBusy else { return }
            startAction(.login(tenantId: tenant.tenantId, tenantName: tenant.name)) { [self] action in
                await self.executeTerminalLogin(action: action, tenant: tenant)
            }

        case .logout(let tenantId):
            guard !isBusy else { return }
            let tenantName = config?.tenants.first(where: { $0.tenantId == tenantId })?.name ?? tenantId
            startAction(.logout(tenantId: tenantId, tenantName: tenantName)) { [self] action in
                await self.executeLogout(action: action, tenantId: tenantId)
            }

        case .logoutAll:
            guard !isBusy else { return }
            startAction(.logout(tenantId: "all", tenantName: "All Accounts")) { [self] action in
                await self.executeLogoutAll(action: action)
            }

        case .selectSubscription(let sub, let tenantId):
            guard !isBusy else { return }
            startAction(.selectSubscription(subscriptionId: sub.id, subscriptionName: sub.name, tenantId: tenantId)) { [self] action in
                await self.executeSelectSubscription(action: action, subscription: sub, tenantId: tenantId)
            }

        case .activatePIM(let role, let tenant):
            guard !isBusy else { return }
            let roleName = role.roleName ?? "Role"
            let subId = extractSubscriptionId(from: role.scope) ?? ""
            startAction(.activatePIM(roleId: role.id, roleName: roleName, subscriptionId: subId, tenantId: tenant.tenantId)) { [self] action in
                await self.executeActivatePIM(action: action, role: role, tenant: tenant)
            }

        case .openPortal(let tenantId, let subId, let browserBundleId):
            let url = PortalURL.portalURL(tenantId: tenantId, subscriptionId: subId)
            if let browser = availableBrowsers.first(where: { $0.id == browserBundleId }) {
                BrowserService.open(url, in: browser)
            }

        case .openPortalDefault(let tenantId, let subId):
            let url = PortalURL.portalURL(tenantId: tenantId, subscriptionId: subId)
            BrowserService.openDefault(url)

        case .toggleSubscriptionExposure(let sub, let tenantId):
            handleToggleSubscriptionExposure(sub, tenantId: tenantId)

        case .openLogFolder:
            logger.openInFinder()

        case .reloadBrowsers:
            availableBrowsers = BrowserService.installedBrowsers()

        case .refreshAfterExternalLogin(let tenantId):
            handleRefreshAfterExternalLogin(tenantId: tenantId)
        }
    }

    // MARK: - Config

    private func handleLoadConfig() {
        let result = ConfigLoader.loadConfig(from: ConfigLoader.defaultConfigPath())
        switch result {
        case .success(let appConfig):
            config = appConfig
            configError = nil
        case .failure(let error):
            configError = error.localizedDescription
            config = nil
        }
        availableBrowsers = BrowserService.installedBrowsers()
        restoreState()
    }

    // MARK: - Action Lifecycle

    private func startAction(_ kind: AzActionKind, execute: @escaping (AzAction) async -> Void) {
        var action = AzAction(kind: kind)
        action.phase = .running(step: "Starting...")
        fsmState = .busy(action)

        currentTask = Task {
            await execute(action)
            await refreshAzureContext()
        }
    }

    private func updatePhase(_ step: String) {
        guard case .busy(var action) = fsmState else { return }
        action.phase = .running(step: step)
        fsmState = .busy(action)
    }

    private func logCommand(_ entry: CommandLogEntry) {
        guard case .busy(var action) = fsmState else { return }
        action.addCommandEntry(entry)
        fsmState = .busy(action)
    }

    private func completeAction(phase: AzActionPhase) {
        guard case .busy(var action) = fsmState else { return }
        action.complete(phase: phase)
        actionHistory.append(action)
        if actionHistory.count > 100 { actionHistory.removeFirst() }
        logger.logAction(action)
        fsmState = .idle
        currentTask = nil
        persistState()
    }

    // MARK: - Run az command helper

    private func runAz(_ arguments: [String]) async throws -> ShellResult {
        let start = Date()
        var entry = CommandLogEntry(command: "az", arguments: arguments)

        let result = try await azCLI.shell.run(
            executable: azCLI.azPath,
            arguments: arguments
        )

        entry.stdout = result.stdout
        entry.stderr = result.stderr
        entry.exitCode = result.exitCode
        entry.duration = Date().timeIntervalSince(start)
        logCommand(entry)

        return result
    }

    // MARK: - Login Workflow

    private func executeLogin(action: AzAction, tenant: TenantConfig) async {
        let tenantId = tenant.tenantId
        ensureCache(for: tenantId)

        updatePhase("Authenticating...")
        do {
            try await azCLI.login(tenantId: tenantId)
        } catch {
            tenantCaches[tenantId]!.isLoggedIn = false
            completeAction(phase: .failed("Login failed: \(error.localizedDescription)"))
            return
        }

        tenantCaches[tenantId]!.isLoggedIn = true
        tenantCaches[tenantId]!.loginAt = Date()

        updatePhase("Fetching subscriptions...")
        do {
            let allSubs = try await azCLI.listSubscriptions()
            let tenantSubs = allSubs
                .filter { $0.tenantId == tenantId }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            tenantCaches[tenantId]!.allDiscoveredSubscriptions = tenantSubs
        } catch {
            // Partial — login succeeded but sub discovery failed
        }

        if let firstSub = tenant.subscriptions.first {
            updatePhase("Setting subscription...")
            do {
                try await azCLI.setSubscription(id: firstSub.id)
                tenantCaches[tenantId]!.activeSubscription = AzSubscription(
                    id: firstSub.id, name: firstSub.name, tenantId: tenantId,
                    isDefault: true, state: "Enabled", homeTenantId: nil, tenantDisplayName: nil
                )
                tenantCaches[tenantId]!.subscriptionSetAt = Date()
            } catch {
                // Non-fatal
            }
        }

        updatePhase("Loading user info...")
        do {
            let user = try await azCLI.getSignedInUser()
            tenantCaches[tenantId]!.signedInUser = user
        } catch {
            // Non-fatal
        }

        var pimIssues: [String] = []
        if !tenant.subscriptions.isEmpty {
            updatePhase("Discovering PIM roles...")
            var allRoles: [PIMEligibleRole] = []
            for sub in tenant.subscriptions {
                do {
                    var roles = try await pimService.discoverEligibleRoles(subscriptionId: sub.id)
                    roles = await pimService.resolveRoleNames(for: roles, subscriptionId: sub.id)
                    allRoles.append(contentsOf: roles)
                } catch {
                    pimIssues.append("PIM discovery failed for \(sub.name)")
                }
            }
            tenantCaches[tenantId]!.eligiblePIMRoles = allRoles
            var statuses: [String: PIMRoleStatusEntry] = [:]
            for role in allRoles { statuses[role.id] = .idle() }
            tenantCaches[tenantId]!.pimRoleStatuses = statuses
        }

        if pimIssues.isEmpty {
            completeAction(phase: .succeeded)
        } else {
            completeAction(phase: .partialSuccess(pimIssues.joined(separator: "; ")))
        }
    }

    // MARK: - Terminal Login

    private func executeTerminalLogin(action: AzAction, tenant: TenantConfig) async {
        do {
            try await loginLauncher.launchInTerminal(
                command: "az",
                arguments: ["login", "--tenant", tenant.tenantId]
            )
        } catch {
            completeAction(phase: .failed("Failed to open terminal: \(error.localizedDescription)"))
            return
        }

        // Transition to awaiting state — user must click "Refresh" when done
        guard case .busy(var action) = fsmState else { return }
        action.phase = .awaitingExternalLogin
        fsmState = .awaitingExternalLogin(tenantId: tenant.tenantId)
        currentTask = nil
    }

    // MARK: - Refresh After External Login

    private func handleRefreshAfterExternalLogin(tenantId: String) {
        guard case .awaitingExternalLogin(let awaitingTenantId) = fsmState,
              awaitingTenantId == tenantId else { return }

        fsmState = .idle

        guard let tenant = config?.tenants.first(where: { $0.tenantId == tenantId }) else { return }

        startAction(.login(tenantId: tenantId, tenantName: tenant.name)) { [self] action in
            self.ensureCache(for: tenantId)
            self.tenantCaches[tenantId]!.isLoggedIn = true
            self.tenantCaches[tenantId]!.loginAt = Date()

            self.updatePhase("Fetching subscriptions...")
            do {
                let allSubs = try await self.azCLI.listSubscriptions()
                let tenantSubs = allSubs
                    .filter { $0.tenantId == tenantId }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.tenantCaches[tenantId]!.allDiscoveredSubscriptions = tenantSubs
            } catch {
                self.completeAction(phase: .failed("Not logged in or fetch failed: \(error.localizedDescription)"))
                return
            }

            if let firstSub = tenant.subscriptions.first {
                self.updatePhase("Setting subscription...")
                try? await self.azCLI.setSubscription(id: firstSub.id)
                self.tenantCaches[tenantId]!.activeSubscription = AzSubscription(
                    id: firstSub.id, name: firstSub.name, tenantId: tenantId,
                    isDefault: true, state: "Enabled", homeTenantId: nil, tenantDisplayName: nil
                )
                self.tenantCaches[tenantId]!.subscriptionSetAt = Date()
            }

            self.updatePhase("Loading user info...")
            if let user = try? await self.azCLI.getSignedInUser() {
                self.tenantCaches[tenantId]!.signedInUser = user
            }

            self.completeAction(phase: .succeeded)
        }
    }

    // MARK: - Logout

    private func executeLogout(action: AzAction, tenantId: String) async {
        updatePhase("Logging out...")

        let upn = tenantCaches[tenantId]?.signedInUser?.userPrincipalName
                ?? tenantCaches[tenantId]?.signedInUser?.mail

        if let upn {
            do {
                try await azCLI.logout(username: upn)
            } catch {
                completeAction(phase: .failed("Logout failed: \(error.localizedDescription)"))
                return
            }
        }

        updatePhase("Reconciling...")
        do {
            let remainingSubs = try await azCLI.listSubscriptions()
            let remainingTenantIds = Set(remainingSubs.map(\.tenantId))

            for (tid, _) in tenantCaches {
                if !remainingTenantIds.contains(tid) {
                    tenantCaches[tid] = TenantCache()
                }
            }
        } catch {
            tenantCaches[tenantId] = TenantCache()
        }

        completeAction(phase: .succeeded)
    }

    // MARK: - Logout All
    
    private func executeLogoutAll(action: AzAction) async {
        updatePhase("Clearing all accounts...")
        do {
            let result = try await azCLI.shell.run(
                executable: azCLI.azPath,
                arguments: ["account", "clear"]
            )
            guard result.exitCode == 0 else {
                completeAction(phase: .failed("az account clear failed"))
                return
            }
        } catch {
            completeAction(phase: .failed("Logout failed: \(error.localizedDescription)"))
            return
        }
        
        // Reset all caches
        for tid in tenantCaches.keys {
            tenantCaches[tid] = TenantCache()
        }
        azureContext = .empty
        persistState()
        completeAction(phase: .succeeded)
    }

    // MARK: - Select Subscription

    private func executeSelectSubscription(action: AzAction, subscription: SubscriptionConfig, tenantId: String) async {
        ensureCache(for: tenantId)
        updatePhase("Setting subscription...")

        do {
            try await azCLI.setSubscription(id: subscription.id)
            tenantCaches[tenantId]!.activeSubscription = AzSubscription(
                id: subscription.id, name: subscription.name, tenantId: tenantId,
                isDefault: true, state: "Enabled", homeTenantId: nil, tenantDisplayName: nil
            )
            tenantCaches[tenantId]!.subscriptionSetAt = Date()
            completeAction(phase: .succeeded)
        } catch {
            completeAction(phase: .failed("Failed to set subscription: \(error.localizedDescription)"))
        }
    }

    // MARK: - Activate PIM

    private func executeActivatePIM(action: AzAction, role: PIMEligibleRole, tenant: TenantConfig) async {
        let tenantId = tenant.tenantId
        ensureCache(for: tenantId)

        guard let principalId = tenantCaches[tenantId]?.signedInUser?.id else {
            completeAction(phase: .failed("No signed-in user — login first"))
            return
        }

        let justification = tenant.pim?.justification ?? "Development work"
        let duration = tenant.pim?.duration ?? "PT8H"
        let subscriptionId = extractSubscriptionId(from: role.scope) ?? ""

        tenantCaches[tenantId]!.pimRoleStatuses[role.id] = PIMRoleStatusEntry(status: .activating, updatedAt: Date())
        updatePhase("Activating \(role.roleName ?? "role")...")

        do {
            let result = try await pimService.activateRole(
                subscriptionId: subscriptionId,
                role: role,
                principalId: principalId,
                justification: justification,
                duration: duration
            )
            tenantCaches[tenantId]!.pimRoleStatuses[role.id] = PIMRoleStatusEntry(
                status: .active(expires: result.expiresAt), updatedAt: Date()
            )
            completeAction(phase: .succeeded)
        } catch {
            tenantCaches[tenantId]!.pimRoleStatuses[role.id] = PIMRoleStatusEntry(
                status: .failed(error.localizedDescription), updatedAt: Date()
            )
            completeAction(phase: .failed("PIM activation failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Subscription Exposure Toggle

    private func handleToggleSubscriptionExposure(_ sub: AzSubscription, tenantId: String) {
        guard var currentConfig = config,
              let idx = currentConfig.tenants.firstIndex(where: { $0.tenantId == tenantId }) else { return }

        var tenant = currentConfig.tenants[idx]
        if let existingIdx = tenant.subscriptions.firstIndex(where: { $0.id == sub.id }) {
            tenant.subscriptions.remove(at: existingIdx)
        } else {
            tenant.subscriptions.append(SubscriptionConfig(name: sub.name, id: sub.id))
        }
        currentConfig.tenants[idx] = tenant
        config = currentConfig
        ConfigLoader.saveConfig(currentConfig)
    }

    // MARK: - Azure Context Refresh

    private func refreshAzureContext() async {
        do {
            let result = try await azCLI.shell.run(
                executable: azCLI.azPath,
                arguments: ["account", "show", "-o", "json"]
            )
            if result.exitCode == 0, let data = result.stdout.data(using: .utf8) {
                struct AccountShow: Codable {
                    let tenantId: String?
                    let id: String?
                    let name: String?
                    let user: UserInfo?
                    struct UserInfo: Codable { let name: String? }
                }
                if let info = try? JSONDecoder().decode(AccountShow.self, from: data) {
                    azureContext = AzureContext(
                        currentTenantId: info.tenantId,
                        currentSubscriptionId: info.id,
                        currentSubscriptionName: info.name,
                        currentUser: info.user?.name,
                        lastUpdated: Date()
                    )
                    return
                }
            }
            azureContext = .empty
        } catch {
            azureContext = .empty
        }
    }

    // MARK: - Helpers

    private func ensureCache(for tenantId: String) {
        if tenantCaches[tenantId] == nil {
            tenantCaches[tenantId] = TenantCache()
        }
    }

    private func extractSubscriptionId(from scope: String) -> String? {
        let parts = scope.split(separator: "/")
        guard let idx = parts.firstIndex(of: "subscriptions"), idx + 1 < parts.count else { return nil }
        return String(parts[idx + 1])
    }

    func cache(for tenantId: String) -> TenantCache {
        tenantCaches[tenantId] ?? TenantCache()
    }

    func isSubscriptionExposed(_ subId: String, tenantId: String) -> Bool {
        config?.tenants.first(where: { $0.tenantId == tenantId })?.subscriptions.contains { $0.id == subId } ?? false
    }

    // MARK: - State Persistence

    /// Save tenant caches and azure context to disk
    func persistState() {
        let state = PersistedState(
            tenantCaches: tenantCaches,
            azureContext: azureContext,
            savedAt: Date()
        )
        state.save()
    }

    /// Restore state from disk, marking stale logins
    func restoreState() {
        guard let state = PersistedState.load() else { return }
        tenantCaches = state.tenantCaches
        azureContext = state.azureContext
        
        // Mark stale logins
        for (tid, cache) in tenantCaches where cache.isStale && cache.isLoggedIn {
            tenantCaches[tid]!.isLoggedIn = false
        }
    }
}
