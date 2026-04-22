import Foundation
import Yams

public enum ConfigError: Error, Equatable {
    case fileNotFound(String)
    case parseError(String)
    case validationError(String)
}

extension ConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Configuration file not found at: \(path)"
        case .parseError(let message):
            return "Failed to parse configuration: \(message)"
        case .validationError(let message):
            return "Configuration validation failed: \(message)"
        }
    }
}

public struct ConfigLoader {
    
    public static func loadConfig(from path: String) -> Result<AppConfig, ConfigError> {
        let fileManager = FileManager.default
        let expandedPath = (path as NSString).expandingTildeInPath
        
        guard fileManager.fileExists(atPath: expandedPath) else {
            return .failure(.fileNotFound(expandedPath))
        }
        
        do {
            let yamlString = try String(contentsOfFile: expandedPath, encoding: .utf8)
            let decoder = YAMLDecoder()
            let config = try decoder.decode(AppConfig.self, from: yamlString)
            
            return validate(config: config)
        } catch let error as DecodingError {
            return .failure(.parseError(error.localizedDescription))
        } catch {
            return .failure(.parseError(error.localizedDescription))
        }
    }
    
    public static func defaultConfigPath() -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".az-login-switcher.yaml").path
    }
    
    public static func validate(config: AppConfig) -> Result<AppConfig, ConfigError> {
        for (index, tenant) in config.tenants.enumerated() {
            if tenant.tenantId.isEmpty {
                return .failure(.validationError("Tenant at index \(index) (\(tenant.name)) has empty tenantId"))
            }
            
            if tenant.subscriptions.isEmpty {
                return .failure(.validationError("Tenant '\(tenant.name)' must have at least one subscription"))
            }
        }
        
        return .success(config)
    }
}
