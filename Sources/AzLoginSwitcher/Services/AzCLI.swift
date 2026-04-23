import Foundation

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
    
    func login(tenantId: String) async throws {
        let result = try await shell.run(
            executable: azPath,
            arguments: ["login", "--tenant", tenantId]
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
