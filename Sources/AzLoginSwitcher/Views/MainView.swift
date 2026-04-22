import SwiftUI

struct MainView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let error = appState.configError {
                configErrorView(error)
            } else if appState.config == nil {
                noConfigView
            } else {
                tenantListView
            }
            Divider()
            bottomBar
        }
        .frame(width: 350)
        .frame(minHeight: 200, maxHeight: 500)
        .onAppear { appState.loadConfig() }
    }

    // MARK: - Subviews

    private func configErrorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.largeTitle)
            Text(error)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noConfigView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.gearshape")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Create config at")
                .foregroundStyle(.secondary)
            Text("~/.az-login-switcher.yaml")
                .font(.system(.caption, design: .monospaced))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var tenantListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let tenants = appState.config?.tenants {
                    ForEach(tenants, id: \.tenantId) { tenant in
                        TenantRow(tenant: tenant, appState: appState)
                        if tenant.tenantId != tenants.last?.tenantId {
                            Divider()
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                appState.loadConfig()
            } label: {
                Label("Reload Config", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
