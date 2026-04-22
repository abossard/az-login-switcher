import Foundation

struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol ShellExecuting: Sendable {
    func run(executable: String, arguments: [String]) async throws -> ShellResult
}

protocol LoginLaunching: Sendable {
    func launchInTerminal(command: String, arguments: [String]) async throws
}

protocol URLOpening: Sendable {
    func open(_ url: URL)
}
