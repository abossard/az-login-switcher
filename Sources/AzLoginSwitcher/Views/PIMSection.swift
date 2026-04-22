import SwiftUI

struct PIMSection: View {
    let tenant: TenantConfig
    let session: TenantSession
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PIM Roles (\(session.eligiblePIMRoles.count))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if session.eligiblePIMRoles.isEmpty {
                Text("No eligible PIM roles")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(session.eligiblePIMRoles, id: \.id) { role in
                    roleRow(role)
                }
            }
        }
    }

    private func roleRow(_ role: PIMEligibleRole) -> some View {
        let status = session.pimRoleStatuses[role.id] ?? .idle

        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.roleName ?? displayName(from: role.roleDefinitionId))
                    .font(.callout)
                Text(role.scope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusView(for: status, role: role)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusView(for status: PIMRoleStatus, role: PIMEligibleRole) -> some View {
        switch status {
        case .idle:
            Button("Activate") {
                Task { await appState.activatePIMRole(role, for: tenant) }
            }
            .buttonStyle(.borderless)
            .font(.caption)

        case .activating:
            ProgressView()
                .controlSize(.small)

        case .active(let expires):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                if let expires {
                    Text(expires)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .help(msg)
                Button("Retry") {
                    Task { await appState.activatePIMRole(role, for: tenant) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    /// Extracts the last path component from a roleDefinitionId GUID-style path
    private func displayName(from roleDefinitionId: String) -> String {
        let parts = roleDefinitionId.split(separator: "/")
        return parts.last.map(String.init) ?? "Role"
    }
}
