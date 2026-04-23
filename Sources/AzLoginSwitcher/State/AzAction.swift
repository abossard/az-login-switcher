import Foundation

// MARK: - Action Kind

enum AzActionKind: Equatable, Sendable {
    case login(tenantId: String, tenantName: String)
    case logout(tenantId: String, tenantName: String)
    case selectSubscription(subscriptionId: String, subscriptionName: String, tenantId: String)
    case activatePIM(roleId: String, roleName: String, subscriptionId: String, tenantId: String)
    
    var displayName: String {
        switch self {
        case .login(_, let name): return "Login to \(name)"
        case .logout(_, let name): return "Logout from \(name)"
        case .selectSubscription(_, let name, _): return "Select \(name)"
        case .activatePIM(_, let name, _, _): return "Activate \(name)"
        }
    }
    
    var tenantId: String {
        switch self {
        case .login(let id, _), .logout(let id, _): return id
        case .selectSubscription(_, _, let id): return id
        case .activatePIM(_, _, _, let id): return id
        }
    }
}

// MARK: - Action Phase (child FSM state)

enum AzActionPhase: Equatable, Sendable {
    case pending
    case running(step: String)           // human-readable step (display only)
    case succeeded
    case partialSuccess(String)          // e.g., login OK but PIM discovery failed
    case failed(String)
    
    var isTerminal: Bool {
        switch self {
        case .succeeded, .partialSuccess, .failed: return true
        default: return false
        }
    }
}

// MARK: - Command Log Entry

struct CommandLogEntry: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let timestamp: Date
    let command: String              // e.g., "az login --tenant abc"
    let arguments: [String]
    var stdout: String
    var stderr: String               // verbose output
    var exitCode: Int32?
    var duration: TimeInterval?
    
    init(command: String, arguments: [String]) {
        self.id = UUID()
        self.timestamp = Date()
        self.command = command
        self.arguments = arguments
        self.stdout = ""
        self.stderr = ""
        self.exitCode = nil
        self.duration = nil
    }
}

// MARK: - AzAction (child FSM)

struct AzAction: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: AzActionKind
    var phase: AzActionPhase
    let startedAt: Date
    var completedAt: Date?
    var commandLog: [CommandLogEntry]
    
    init(kind: AzActionKind) {
        self.id = UUID()
        self.kind = kind
        self.phase = .pending
        self.startedAt = Date()
        self.completedAt = nil
        self.commandLog = []
    }
    
    var displayName: String { kind.displayName }
    var isTerminal: Bool { phase.isTerminal }
    
    mutating func addCommandEntry(_ entry: CommandLogEntry) {
        commandLog.append(entry)
    }
    
    mutating func complete(phase: AzActionPhase) {
        self.phase = phase
        self.completedAt = Date()
    }
}
