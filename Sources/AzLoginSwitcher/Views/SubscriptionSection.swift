import SwiftUI

struct SubscriptionSection: View {
    let tenant: TenantConfig
    let session: TenantSession
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subscriptions")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(tenant.subscriptions, id: \.id) { sub in
                subscriptionRow(sub)
            }
        }
    }

    private func subscriptionRow(_ sub: SubscriptionConfig) -> some View {
        let isActive = session.activeSubscription?.id == sub.id

        return HStack(spacing: 6) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? .green : .secondary)
                .font(.caption)

            Text(sub.name)
                .font(.callout)

            Spacer()

            if !isActive {
                Button("Set Active") {
                    Task { await appState.setActiveSubscription(sub, tenantId: tenant.tenantId) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Button {
                appState.openPortal(tenantId: tenant.tenantId, subscriptionId: sub.id)
            } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.borderless)
            .help("Open Azure Portal")
        }
        .padding(.vertical, 2)
    }
}
