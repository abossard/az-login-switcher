import SwiftUI

struct SubscriptionSection: View {
    let tenant: TenantConfig
    let cache: TenantCache
    let runner: ActionRunner

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
        let isActive = cache.activeSubscription?.id == sub.id

        return HStack(spacing: 6) {
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

            Spacer()

            if !isActive {
                Button("Set Active") {
                    runner.send(.selectSubscription(sub, tenantId: tenant.tenantId))
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(runner.isBusy)
            }

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

            if runner.availableBrowsers.isEmpty {
                Button {
                    runner.send(.openPortalDefault(tenantId: tenant.tenantId, subscriptionId: sub.id))
                } label: {
                    Image(systemName: "globe")
                }
                .buttonStyle(.borderless)
                .help("Open Azure Portal")
            }
        }
        .padding(.vertical, 2)
    }
}
