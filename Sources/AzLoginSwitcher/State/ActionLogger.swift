import Foundation
import AppKit

final class ActionLogger: Sendable {
    private let logDirectoryURL: URL
    private let maxAgeDays: Int
    
    init(maxAgeDays: Int = 30) {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.logDirectoryURL = libraryURL.appendingPathComponent("Logs/az-login-switcher")
        self.maxAgeDays = maxAgeDays
        ensureDirectoryExists()
        pruneOldLogs()
    }
    
    /// Log a completed action as a JSON line
    func logAction(_ action: AzAction) {
        let entry = LogEntry(
            timestamp: ISO8601DateFormatter().string(from: action.startedAt),
            completedAt: action.completedAt.map { ISO8601DateFormatter().string(from: $0) },
            kind: action.kind.displayName,
            tenantId: action.kind.tenantId,
            phase: String(describing: action.phase),
            commands: action.commandLog.map { cmd in
                LogCommandEntry(
                    timestamp: ISO8601DateFormatter().string(from: cmd.timestamp),
                    command: "\(cmd.command) \(cmd.arguments.joined(separator: " "))",
                    exitCode: cmd.exitCode,
                    duration: cmd.duration,
                    stderr: cmd.stderr.isEmpty ? nil : String(cmd.stderr.prefix(1000))
                )
            }
        )
        
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        
        appendToTodayFile(line + "\n")
    }
    
    /// Open log directory in Finder
    @MainActor
    func openInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logDirectoryURL.path)
    }
    
    /// Get the log directory path
    var logDirectory: String { logDirectoryURL.path }
    
    // MARK: - Private
    
    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
    }
    
    private func todayFileName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "az-login-switcher-\(fmt.string(from: Date())).log"
    }
    
    private func appendToTodayFile(_ content: String) {
        let fileURL = logDirectoryURL.appendingPathComponent(todayFileName())
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = content.data(using: .utf8) {
            handle.write(data)
        }
    }
    
    private func pruneOldLogs() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: logDirectoryURL, includingPropertiesForKeys: [.creationDateKey]
              ) else { return }
        
        for file in files where file.pathExtension == "log" {
            if let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
               let created = attrs.creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Codable log entry (for JSON Lines output)

private struct LogEntry: Codable {
    let timestamp: String
    let completedAt: String?
    let kind: String
    let tenantId: String
    let phase: String
    let commands: [LogCommandEntry]
}

private struct LogCommandEntry: Codable {
    let timestamp: String
    let command: String
    let exitCode: Int32?
    let duration: TimeInterval?
    let stderr: String?  // truncated to 1000 chars
}
