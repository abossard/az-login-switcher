import SwiftUI

struct PIMSection: View {
    let tenant: TenantConfig
    let cache: TenantCache
    let runner: ActionRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PIM Roles (\(cache.eligiblePIMRoles.count))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if cache.eligiblePIMRoles.isEmpty {
                Text("No eligible PIM roles")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(cache.eligiblePIMRoles, id: \.id) { role in
                    roleRow(role)
                }
            }
        }
    }

    private func roleRow(_ role: PIMEligibleRole) -> some View {
        let entry = cache.pimRoleStatuses[role.id]
        let status = entry?.status ?? .idle

        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.roleName ?? displayName(from: role.roleDefinitionId))
                    .font(.callout)
                Text(friendlyScope(role.scope))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusView(for: status, role: role, entry: entry)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusView(for status: PIMRoleStatus, role: PIMEligibleRole, entry: PIMRoleStatusEntry?) -> some View {
        switch status {
        case .idle:
            Button("Activate") {
                runner.send(.activatePIM(role, tenant))
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(runner.isBusy)

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
                if let updatedAt = entry?.updatedAt {
                    Text(updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .help(msg)
                Button("Retry") {
                    runner.send(.activatePIM(role, tenant))
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(runner.isBusy)
            }
        }
    }

    private func displayName(from roleDefinitionId: String) -> String {
        let parts = roleDefinitionId.split(separator: "/")
        return parts.last.map(String.init) ?? "Role"
    }

    private func friendlyScope(_ scope: String) -> String {
        let parts = scope.split(separator: "/")
        if let idx = parts.firstIndex(of: "subscriptions"), idx + 1 < parts.count {
            let subId = String(parts[idx + 1])
            if let name = tenant.subscriptions.first(where: { $0.id == subId })?.name {
                return name
            }
            return subId
        }
        return scope
    }
}
