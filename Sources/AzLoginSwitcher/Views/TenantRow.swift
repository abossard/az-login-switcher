import SwiftUI

struct TenantRow: View {
    let tenant: TenantConfig
    let runner: ActionRunner
    @State private var showingPicker: Bool = false
    @State private var searchText: String = ""

    private var cache: TenantCache { runner.cache(for: tenant.tenantId) }

    private var currentTenant: TenantConfig {
        runner.config?.tenants.first { $0.tenantId == tenant.tenantId } ?? tenant
    }

    private var anotherTenantIsActive: Bool {
        runner.azureContext.isAuthenticated && !runner.isActiveTenant(tenant.tenantId)
    }

    private var statusColor: Color {
        switch runner.tenantStatus(for: tenant.tenantId) {
        case .active: return .green
        case .remembered: return .yellow
        case .unknown:
            return anotherTenantIsActive ? .yellow : .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            if showingPicker {
                subscriptionPicker
            } else if !currentTenant.subscriptions.isEmpty {
                subscriptionQuickPick
            }

            if runner.isActiveTenant(tenant.tenantId) {
                expandedContent
            }
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

            if runner.isActiveTenant(tenant.tenantId), let loginAt = cache.loginAt {
                RelativeTimeText(date: loginAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingPicker.toggle()
                if showingPicker && !runner.isActiveTenant(tenant.tenantId) {
                    runner.send(.login(currentTenant))
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Select subscriptions to show")
            .disabled(runner.isBusy)

            if runner.isActiveTenant(tenant.tenantId) {
                // No per-tenant logout — use global logout in bottom bar
            }

            Button("Login") {
                runner.send(.login(currentTenant))
            }
            .buttonStyle(.borderless)
            .disabled(runner.isBusy)
        }
    }

    // MARK: - Subscription Picker (all discovered, with checkboxes)

    private var subscriptionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header — always visible
            HStack {
                Text("Select subscriptions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { showingPicker = false; searchText = "" }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            let discovered = cache.allDiscoveredSubscriptions
            if !runner.isActiveTenant(tenant.tenantId) {
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
                // Search field
                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)

                let filtered = discovered.filter {
                    searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                }

                // Scrollable subscription list
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered, id: \.id) { sub in
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
                                .padding(.vertical, 1)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Text("\(filtered.count) of \(discovered.count) subscriptions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Auto-open browsers — always visible
            Text("Auto-open portal in:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(runner.availableBrowsers) { browser in
                    let isChecked = runner.autoOpenBrowserIds.contains(browser.id)
                    Button {
                        runner.send(.toggleAutoOpenBrowser(browser.id))
                    } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: BrowserService.icon(for: browser, size: 16))
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isChecked ? .blue : .secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(browser.name)
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
                        if runner.isActiveTenant(tenant.tenantId) {
                            runner.send(.selectSubscription(sub, tenantId: tenant.tenantId))
                        } else {
                            runner.send(.loginAndSelect(sub, tenant: currentTenant))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isActive ? .green : .secondary)
                                .font(.caption)
                            Text(sub.name)
                                .font(.callout)
                            if isActive, let setAt = cache.subscriptionSetAt {
                                RelativeTimeText(date: setAt)
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
                                Image(nsImage: BrowserService.icon(for: browser, size: 18))
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
