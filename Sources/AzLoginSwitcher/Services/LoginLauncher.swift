import Foundation
import AppKit

struct TerminalLoginLauncher: LoginLaunching {
    func launchInTerminal(command: String, arguments: [String]) async throws {
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedArgs = arguments.map { $0.replacingOccurrences(of: "\"", with: "\\\"") }
        let fullCommand = ([escapedCommand] + escapedArgs).joined(separator: " ")
        
        let script = """
        tell application "Terminal"
            activate
            do script "\(fullCommand)"
        end tell
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        // No output capture needed for interactive terminal
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TerminalLoginLauncher",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to launch Terminal"]
            )
        }
    }
}

final class DefaultURLOpener: URLOpening, @unchecked Sendable {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
