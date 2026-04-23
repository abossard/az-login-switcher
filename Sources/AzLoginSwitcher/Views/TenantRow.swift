import SwiftUI

struct TenantRow: View {
    let tenant: TenantConfig
    let appState: AppState
    @State private var isExpanded: Bool = false
    @State private var showingPicker: Bool = false

    private var session: TenantSession {
        appState.session(for: tenant.tenantId)
    }

    private var anotherTenantIsActive: Bool {
        appState.tenantSessions.contains { key, value in
            key != tenant.tenantId && value.loginStatus == .loggedIn
        }
    }

    private var statusColor: Color {
        switch session.loginStatus {
        case .idle: anotherTenantIsActive ? .yellow : .gray
        case .loggingIn: .yellow
        case .loggedIn: .green
        case .failed: .red
        }
    }

    private var currentTenant: TenantConfig {
        appState.config?.tenants.first { $0.tenantId == tenant.tenantId } ?? tenant
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            errorRow

            if showingPicker && session.loginStatus == .loggedIn {
                subscriptionPicker
            } else if !currentTenant.subscriptions.isEmpty {
                subscriptionQuickPick
            }

            if isExpanded && session.loginStatus == .loggedIn {
                expandedContent
            }
        }
        .onChange(of: session.loginStatus) { _, newValue in
            if newValue == .loggedIn {
                isExpanded = true
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

            if session.loginStatus == .loggingIn {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if session.loginStatus == .loggedIn {
                Button {
                    showingPicker.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Select subscriptions to show")
            }

            Button("Login") {
                Task { await appState.loginToTenant(currentTenant) }
            }
            .buttonStyle(.borderless)
            .disabled(session.loginStatus == .loggingIn)

            Button {
                Task { await appState.loginToTenant(currentTenant, useTerminal: true) }
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Login in Terminal")
            .disabled(session.loginStatus == .loggingIn)

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
        }
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

            let discovered = session.allDiscoveredSubscriptions
            if discovered.isEmpty {
                Text("No subscriptions found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovered, id: \.id) { sub in
                    let isExposed = appState.isSubscriptionExposed(sub.id, tenantId: tenant.tenantId)
                    Button {
                        appState.toggleSubscriptionExposure(sub, tenantId: tenant.tenantId)
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
                let isActive = session.activeSubscription?.id == sub.id
                HStack(spacing: 6) {
                    Button {
                        Task { await appState.loginAndSelectSubscription(sub, tenant: currentTenant) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isActive ? .green : .secondary)
                                .font(.caption)
                            Text(sub.name)
                                .font(.callout)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.loginStatus == .loggingIn)

                    Spacer()

                    Button {
                        appState.openPortal(tenantId: tenant.tenantId, subscriptionId: sub.id)
                    } label: {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.leading, 16)
    }

    // MARK: - Error & Expanded

    @ViewBuilder
    private var errorRow: some View {
        if case .failed(let msg) = session.loginStatus {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if currentTenant.pim != nil {
                PIMSection(tenant: currentTenant, session: session, appState: appState)
            }
        }
        .padding(.leading, 16)
    }
}
