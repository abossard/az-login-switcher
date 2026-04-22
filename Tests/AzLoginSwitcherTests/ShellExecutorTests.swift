import Foundation
import Testing
@testable import AzLoginSwitcher

@Suite("ShellExecutor Tests")
struct ShellExecutorTests {
    @Test("run echo command returns hello in stdout")
    func testEchoCommand() async throws {
        let executor = ShellExecutor()
        let result = try await executor.run(executable: "/bin/echo", arguments: ["hello"])
        
        #expect(result.stdout.contains("hello"))
        #expect(result.exitCode == 0)
    }
    
    @Test("run false command returns non-zero exit code")
    func testFailingCommand() async throws {
        let executor = ShellExecutor()
        let result = try await executor.run(executable: "/usr/bin/false", arguments: [])
        
        #expect(result.exitCode != 0)
    }
    
    @Test("resolveAzPath returns valid path")
    func testResolveAzPath() {
        let path = ShellExecutor.resolveAzPath()
        
        // Should find az CLI if installed
        // This test will pass if az is installed, otherwise it's informational
        if let path = path {
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(path.contains("az"))
        }
        // Not asserting non-nil since az might not be installed in all environments
    }
}
