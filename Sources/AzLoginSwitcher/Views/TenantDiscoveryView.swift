import SwiftUI

struct TenantDiscoveryView: View {
    let tenants: [AzTenant]
    let runner: ActionRunner
    @State private var selectedTenantIds: Set<String> = []

    private var existingTenantIds: Set<String> {
        Set(runner.config?.tenants.map { $0.tenantId.lowercased() } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose tenants to add")
                .font(.headline)
            Text("Uses your current Azure CLI sign-in. Subscriptions can be selected after login.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if tenants.isEmpty {
                Text("No accessible tenants found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tenants, id: \.tenantId) { tenant in
                            let alreadyAdded = existingTenantIds.contains(tenant.tenantId.lowercased())
                            Button {
                                if selectedTenantIds.contains(tenant.tenantId) {
                                    selectedTenantIds.remove(tenant.tenantId)
                                } else {
                                    selectedTenantIds.insert(tenant.tenantId)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: alreadyAdded || selectedTenantIds.contains(tenant.tenantId)
                                          ? "checkmark.square.fill" : "square")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tenant.name)
                                        Text(tenant.tenantId)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if alreadyAdded {
                                        Text("Already added")
                                            .font(.caption)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .disabled(alreadyAdded || runner.isBusy)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Button("Cancel") { runner.send(.dismissTenantDiscovery) }
                    .disabled(runner.isBusy)
                Spacer()
                Button("Add selected (\(selectedTenantIds.count))") {
                    runner.send(.addDiscoveredTenants(selectedTenantIds))
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTenantIds.isEmpty || runner.isBusy)
            }
        }
        .padding()
    }
}
