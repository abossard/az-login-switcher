import Foundation

struct ShellExecutor: ShellExecuting {
    func run(executable: String, arguments: [String]) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()
        
        // Read stdout and stderr concurrently to avoid pipe deadlocks
        async let stdoutData = readPipe(stdoutPipe)
        async let stderrData = readPipe(stderrPipe)
        
        process.waitUntilExit()
        
        let (stdout, stderr) = try await (stdoutData, stderrData)
        
        return ShellResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }
    
    private func readPipe(_ pipe: Pipe) async throws -> String {
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    static func resolveAzPath() -> String? {
        let commonPaths = [
            "/opt/homebrew/bin/az",
            "/usr/local/bin/az"
        ]
        
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // Fallback: try to resolve via env
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "az"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return path?.isEmpty == false ? path : nil
            }
        } catch {
            return nil
        }
        
        return nil
    }
}
