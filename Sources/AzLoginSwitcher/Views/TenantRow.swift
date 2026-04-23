import SwiftUI

struct TenantRow: View {
    let tenant: TenantConfig
    let runner: ActionRunner
    @State private var isExpanded: Bool = false
    @State private var showingPicker: Bool = false

    private var cache: TenantCache { runner.cache(for: tenant.tenantId) }

    private var currentTenant: TenantConfig {
        runner.config?.tenants.first { $0.tenantId == tenant.tenantId } ?? tenant
    }

    private var anotherTenantIsActive: Bool {
        runner.tenantCaches.contains { $0.key != tenant.tenantId && $0.value.isLoggedIn }
    }

    private var statusColor: Color {
        if cache.isLoggedIn { return .green }
        if anotherTenantIsActive { return .yellow }
        return .gray
    }

    private var isAwaitingLogin: Bool {
        if case .awaitingExternalLogin(let tid) = runner.fsmState, tid == tenant.tenantId {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            if isAwaitingLogin {
                awaitingLoginRow
            }

            if showingPicker {
                subscriptionPicker
            } else if !currentTenant.subscriptions.isEmpty {
                subscriptionQuickPick
            }

            if isExpanded && cache.isLoggedIn {
                expandedContent
            }
        }
        .onChange(of: cache.isLoggedIn) { _, loggedIn in
            if loggedIn { isExpanded = true }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(tenant.name)
                .fontWeight(.bold)

            if cache.isLoggedIn, let loginAt = cache.loginAt {
                Text(loginAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingPicker.toggle()
                if showingPicker && !cache.isLoggedIn {
                    runner.send(.login(currentTenant))
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Select subscriptions to show")
            .disabled(runner.isBusy)

            if cache.isLoggedIn {
                Button {
                    runner.send(.logout(tenantId: tenant.tenantId))
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Logout")
                .disabled(runner.isBusy)
            }

            Button("Login") {
                runner.send(.login(currentTenant))
            }
            .buttonStyle(.borderless)
            .disabled(runner.isBusy)

            Button {
                runner.send(.loginInTerminal(currentTenant))
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Login in Terminal")
            .disabled(runner.isBusy)

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Awaiting External Login

    private var awaitingLoginRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Waiting for login...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") {
                runner.send(.refreshAfterExternalLogin(tenantId: tenant.tenantId))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.leading, 16)
    }

    // MARK: - Subscription Picker (all discovered, with checkboxes)

    private var subscriptionPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Select subscriptions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { showingPicker = false }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }

            let discovered = cache.allDiscoveredSubscriptions
            if !cache.isLoggedIn {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Login to discover subscriptions...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if discovered.isEmpty {
                Text("No subscriptions found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovered, id: \.id) { sub in
                    let isExposed = runner.isSubscriptionExposed(sub.id, tenantId: tenant.tenantId)
                    Button {
                        runner.send(.toggleSubscriptionExposure(sub, tenantId: tenant.tenantId))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExposed ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isExposed ? .blue : .secondary)
                                .font(.caption)
                            Text(sub.name)
                                .font(.callout)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Quick-pick (exposed subscriptions only)

    private var subscriptionQuickPick: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(currentTenant.subscriptions, id: \.id) { sub in
                let isActive = cache.activeSubscription?.id == sub.id
                HStack(spacing: 6) {
                    Button {
                        if cache.isLoggedIn {
                            runner.send(.selectSubscription(sub, tenantId: tenant.tenantId))
                        } else {
                            runner.send(.login(currentTenant))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isActive ? .green : .secondary)
                                .font(.caption)
                            Text(sub.name)
                                .font(.callout)
                            if isActive, let setAt = cache.subscriptionSetAt {
                                Text(setAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(runner.isBusy)

                    Spacer()

                    // Browser icons for portal
                    HStack(spacing: 2) {
                        ForEach(runner.availableBrowsers.prefix(4)) { browser in
                            Button {
                                runner.send(.openPortal(
                                    tenantId: tenant.tenantId,
                                    subscriptionId: sub.id,
                                    browserBundleId: browser.id
                                ))
                            } label: {
                                Image(nsImage: BrowserService.icon(for: browser, size: 14))
                            }
                            .buttonStyle(.borderless)
                            .help("Open in \(browser.name)")
                        }
                    }

                    // Default browser fallback
                    if runner.availableBrowsers.isEmpty {
                        Button {
                            runner.send(.openPortalDefault(tenantId: tenant.tenantId, subscriptionId: sub.id))
                        } label: {
                            Image(systemName: "globe")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.leading, 16)
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if currentTenant.pim != nil {
                PIMSection(tenant: currentTenant, cache: cache, runner: runner)
            }
        }
        .padding(.leading, 16)
    }
}
