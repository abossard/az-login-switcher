import SwiftUI

struct MainView: View {
    let runner: ActionRunner

    var body: some View {
        VStack(spacing: 0) {
            if runner.isBusy, let action = runner.currentAction {
                actionProgressBar(action)
            }
            if let error = runner.configError {
                configErrorView(error)
            } else if runner.config == nil {
                noConfigView
            } else {
                tenantListView
            }
            Divider()
            bottomBar
        }
        .frame(width: 380)
        .frame(minHeight: 200, maxHeight: 600)
        .onAppear { runner.send(.loadConfig) }
    }

    // MARK: - Action Progress

    private func actionProgressBar(_ action: AzAction) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(action.displayName)
                .font(.caption)
            if case .running(let step) = action.phase {
                Text("· \(step)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
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
                if let tenants = runner.config?.tenants {
                    ForEach(tenants, id: \.tenantId) { tenant in
                        TenantRow(tenant: tenant, runner: runner)
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
            Button { runner.send(.loadConfig) } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }.buttonStyle(.borderless)

            Button { runner.send(.openLogFolder) } label: {
                Label("Logs", systemImage: "doc.text")
            }.buttonStyle(.borderless)

            Spacer()

            if let ctx = runner.azureContext.currentUser {
                Text(ctx).font(.caption2).foregroundStyle(.secondary)
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
