import Foundation

// MARK: - Models

struct PIMEligibleRole: Equatable, Sendable {
    let id: String
    let roleDefinitionId: String
    let scope: String
    let principalId: String
    let scheduleId: String
    var roleName: String?
}

struct PIMActiveRole: Equatable, Sendable {
    let roleDefinitionId: String
    let scope: String
    let status: String
    let endDateTime: String?
}

struct PIMActivationResult: Equatable, Sendable {
    let status: String
    let expiresAt: String?
}

enum PIMError: Error, LocalizedError {
    case discoveryFailed(String)
    case activationFailed(String)
    case noEligibleSchedule(String)
    
    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let msg): return "PIM discovery failed: \(msg)"
        case .activationFailed(let msg): return "PIM activation failed: \(msg)"
        case .noEligibleSchedule(let msg): return "No eligible schedule: \(msg)"
        }
    }
}

// MARK: - Service

final class PIMService: Sendable {
    private let shell: ShellExecuting
    private let azPath: String
    
    init(shell: ShellExecuting, azPath: String? = nil) {
        self.shell = shell
        self.azPath = azPath ?? ShellExecutor.resolveAzPath() ?? "/opt/homebrew/bin/az"
    }
    
    func discoverEligibleRoles(subscriptionId: String) async throws -> [PIMEligibleRole] {
        let url = "https://management.azure.com/subscriptions/\(subscriptionId)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&$filter=asTarget()"
        
        let result = try await shell.run(
            executable: azPath,
            arguments: ["rest", "--method", "GET", "--url", url, "-o", "json"]
        )
        
        guard result.exitCode == 0 else {
            throw PIMError.discoveryFailed(result.stderr)
        }
        
        guard let data = result.stdout.data(using: .utf8) else {
            throw PIMError.discoveryFailed("Invalid response encoding")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else {
            throw PIMError.discoveryFailed("Invalid JSON structure")
        }
        
        return values.compactMap { item -> PIMEligibleRole? in
            guard let properties = item["properties"] as? [String: Any],
                  let id = item["id"] as? String,
                  let roleDefinitionId = properties["roleDefinitionId"] as? String,
                  let scope = properties["scope"] as? String,
                  let principalId = properties["principalId"] as? String,
                  let scheduleId = properties["roleEligibilityScheduleId"] as? String else {
                return nil
            }
            
            return PIMEligibleRole(
                id: id,
                roleDefinitionId: roleDefinitionId,
                scope: scope,
                principalId: principalId,
                scheduleId: scheduleId,
                roleName: nil
            )
        }
    }
    
    func activateRole(
        subscriptionId: String,
        role: PIMEligibleRole,
        principalId: String,
        justification: String,
        duration: String
    ) async throws -> PIMActivationResult {
        let requestId = UUID().uuidString.lowercased()
        let url = "https://management.azure.com/subscriptions/\(subscriptionId)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(requestId)?api-version=2020-10-01"
        
        let bodyDict: [String: Any] = [
            "properties": [
                "principalId": principalId,
                "roleDefinitionId": role.roleDefinitionId,
                "requestType": "SelfActivate",
                "linkedRoleEligibilityScheduleId": role.scheduleId,
                "justification": justification,
                "scheduleInfo": [
                    "expiration": [
                        "type": "AfterDuration",
                        "duration": duration
                    ]
                ]
            ]
        ]
        
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        guard let bodyJson = String(data: bodyData, encoding: .utf8) else {
            throw PIMError.activationFailed("Failed to serialize request body")
        }
        
        let result = try await shell.run(
            executable: azPath,
            arguments: ["rest", "--method", "PUT", "--url", url, "--body", bodyJson, "-o", "json"]
        )
        
        guard result.exitCode == 0 else {
            throw PIMError.activationFailed(result.stderr)
        }
        
        guard let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = json["properties"] as? [String: Any],
              let status = properties["status"] as? String else {
            throw PIMError.activationFailed("Invalid response structure")
        }
        
        let expiresAt: String? = {
            guard let scheduleInfo = properties["scheduleInfo"] as? [String: Any],
                  let expiration = scheduleInfo["expiration"] as? [String: Any],
                  let endDateTime = expiration["endDateTime"] as? String else {
                return nil
            }
            return endDateTime
        }()
        
        return PIMActivationResult(status: status, expiresAt: expiresAt)
    }
    
    /// Resolve role definition IDs to human-readable names
    func resolveRoleNames(for roles: [PIMEligibleRole], subscriptionId: String) async -> [PIMEligibleRole] {
        // Fetch all role definitions for this scope
        let result: ShellResult
        do {
            result = try await shell.run(
                executable: azPath,
                arguments: ["role", "definition", "list", "--scope", "/subscriptions/\(subscriptionId)", "-o", "json"]
            )
        } catch { return roles }

        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let definitions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return roles
        }

        // Build lookup: full roleDefinitionId path → roleName
        var nameMap: [String: String] = [:]
        for def in definitions {
            if let id = def["id"] as? String,
               let roleName = def["roleName"] as? String {
                nameMap[id.lowercased()] = roleName
            }
        }

        return roles.map { role in
            var updated = role
            updated.roleName = nameMap[role.roleDefinitionId.lowercased()]
            return updated
        }
    }

    func listActiveAssignments(subscriptionId: String) async throws -> [PIMActiveRole] {
        let url = "https://management.azure.com/subscriptions/\(subscriptionId)/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01&$filter=asTarget()"
        
        let result = try await shell.run(
            executable: azPath,
            arguments: ["rest", "--method", "GET", "--url", url, "-o", "json"]
        )
        
        guard result.exitCode == 0 else {
            throw PIMError.discoveryFailed(result.stderr)
        }
        
        guard let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else {
            throw PIMError.discoveryFailed("Invalid JSON structure")
        }
        
        return values.compactMap { item -> PIMActiveRole? in
            guard let properties = item["properties"] as? [String: Any],
                  let assignmentType = properties["assignmentType"] as? String,
                  assignmentType == "Activated",
                  let roleDefinitionId = properties["roleDefinitionId"] as? String,
                  let scope = properties["scope"] as? String,
                  let status = properties["status"] as? String else {
                return nil
            }
            
            let endDateTime = properties["endDateTime"] as? String
            
            return PIMActiveRole(
                roleDefinitionId: roleDefinitionId,
                scope: scope,
                status: status,
                endDateTime: endDateTime
            )
        }
    }
}
