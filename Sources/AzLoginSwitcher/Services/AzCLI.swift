import Foundation

struct AzTenant: Decodable, Equatable, Sendable {
    let tenantId: String
    let displayName: String?
    let defaultDomain: String?

    var name: String {
        for candidate in [displayName, defaultDomain] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return tenantId
    }
}

private struct AzTenantList: Decodable {
    let value: [AzTenant]
    let nextLink: String?
}

struct AzSubscription: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let tenantId: String
    let isDefault: Bool
    let state: String
    let homeTenantId: String?
    let tenantDisplayName: String?
}

struct AzUser: Codable, Equatable, Sendable {
    let id: String
    let userPrincipalName: String?
    let mail: String?
}

enum AzCLIError: Error, LocalizedError {
    case commandFailed(stderr: String, exitCode: Int32)
    case parseError(String)
    case azNotFound
    
    var errorDescription: String? {
        switch self {
        case .commandFailed(let stderr, let code):
            return "az command failed (exit \(code)): \(stderr)"
        case .parseError(let msg):
            return "Failed to parse az output: \(msg)"
        case .azNotFound:
            return "az CLI not found"
        }
    }
}

final class AzCLI: Sendable {
    let shell: ShellExecuting
    let azPath: String
    
    init(shell: ShellExecuting, azPath: String? = nil) {
        self.shell = shell
        self.azPath = azPath ?? ShellExecutor.resolveAzPath() ?? "/opt/homebrew/bin/az"
    }
    
    func login(tenantId: String, browserBundleId: String? = nil) async throws {
        let executable: String
        let arguments: [String]
        if let browserBundleId {
            executable = "/usr/bin/env"
            arguments = [
                "BROWSER=/usr/bin/open -b \(browserBundleId) %s",
                azPath,
                "login",
                "--tenant",
                tenantId,
            ]
        } else {
            executable = azPath
            arguments = ["login", "--tenant", tenantId]
        }

        let result = try await shell.run(
            executable: executable,
            arguments: arguments
        )
        
        guard result.exitCode == 0 else {
            throw AzCLIError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }
    
    func setSubscription(id: String) async throws {
        let result = try await shell.run(
            executable: azPath,
            arguments: ["account", "set", "-s", id]
        )
        
        guard result.exitCode == 0 else {
            throw AzCLIError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }
    
    func listSubscriptions() async throws -> [AzSubscription] {
        let result = try await shell.run(
            executable: azPath,
            arguments: ["account", "list", "-o", "json"]
        )
        
        guard result.exitCode == 0 else {
            throw AzCLIError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
        }

        let decoder = JSONDecoder()
        do {
            let subscriptions = try decoder.decode([AzSubscription].self, from: Data(result.stdout.utf8))
            return subscriptions
        } catch {
            throw AzCLIError.parseError("Failed to decode subscriptions: \(error.localizedDescription)")
        }
    }

    func listTenants(
        runCommand: (@Sendable ([String]) async throws -> ShellResult)? = nil
    ) async throws -> [AzTenant] {
        var nextURL: String? = "https://management.azure.com/tenants?api-version=2022-12-01"
        var visitedURLs: Set<String> = []
        var tenantIds: Set<String> = []
        var tenants: [AzTenant] = []

        while let url = nextURL {
            try Task.checkCancellation()
            guard let parsedURL = URL(string: url),
                  parsedURL.scheme == "https",
                  parsedURL.host == "management.azure.com",
                  parsedURL.path == "/tenants",
                  parsedURL.user == nil,
                  parsedURL.password == nil,
                  parsedURL.port == nil,
                  visitedURLs.insert(url).inserted else {
                throw AzCLIError.parseError("Invalid tenant pagination link")
            }

            let arguments = ["rest", "--method", "GET", "--url", url, "-o", "json"]
            let result: ShellResult
            if let runCommand {
                result = try await runCommand(arguments)
            } else {
                result = try await shell.run(executable: azPath, arguments: arguments)
            }
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw AzCLIError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
            }

            let page: AzTenantList
            do {
                page = try JSONDecoder().decode(AzTenantList.self, from: Data(result.stdout.utf8))
            } catch {
                throw AzCLIError.parseError("Failed to decode tenants: \(error.localizedDescription)")
            }

            for tenant in page.value {
                guard !tenant.tenantId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AzCLIError.parseError("Tenant has an empty tenantId")
                }
                if tenantIds.insert(tenant.tenantId.lowercased()).inserted {
                    tenants.append(tenant)
                }
            }
            nextURL = page.nextLink?.isEmpty == false ? page.nextLink : nil
        }

        return tenants.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame
                ? $0.tenantId < $1.tenantId
                : comparison == .orderedAscending
        }
    }
    
    func getSignedInUser() async throws -> AzUser {
        let result = try await shell.run(
            executable: azPath,
            arguments: ["ad", "signed-in-user", "show", "-o", "json"]
        )
        
        guard result.exitCode == 0 else {
            throw AzCLIError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
        
        let decoder = JSONDecoder()
        do {
            let user = try decoder.decode(AzUser.self, from: Data(result.stdout.utf8))
            return user
        } catch {
            throw AzCLIError.parseError("Failed to decode user: \(error.localizedDescription)")
        }
    }
    
    func logout(username: String) async throws {
        let result = try await shell.run(
            executable: azPath,
            arguments: ["logout", "--username", username]
        )
        guard result.exitCode == 0 else {
            throw AzCLIError.commandFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }
    
    func checkInstalled() async -> Bool {
        do {
            let result = try await shell.run(
                executable: azPath,
                arguments: ["version"]
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }
}
