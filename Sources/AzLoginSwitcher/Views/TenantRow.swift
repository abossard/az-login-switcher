import SwiftUI

struct TenantRow: View {
    let tenant: TenantConfig
    let appState: AppState
    @State private var isExpanded: Bool = false

    private var session: TenantSession {
        appState.session(for: tenant.tenantId)
    }

    private var statusColor: Color {
        switch session.loginStatus {
        case .idle: .gray
        case .loggingIn: .yellow
        case .loggedIn: .green
        case .failed: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            errorRow
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

    // MARK: - Subviews

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

            Button("Login") {
                Task { await appState.loginToTenant(tenant) }
            }
            .buttonStyle(.borderless)
            .disabled(session.loginStatus == .loggingIn)

            Button {
                Task { await appState.loginToTenant(tenant, useTerminal: true) }
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
            .disabled(session.loginStatus != .loggedIn)
        }
    }

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
            SubscriptionSection(tenant: tenant, session: session, appState: appState)

            if tenant.pim != nil {
                PIMSection(tenant: tenant, session: session, appState: appState)
            }
        }
        .padding(.leading, 16)
    }
}
