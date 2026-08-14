import Foundation

final class MockCodexUsageService: CodexUsageServiceProtocol, @unchecked Sendable {
    var installed = true
    var snapshot = CodexUsageSnapshot(usage: UsageResponse(), planType: .plus)
    var error: Error?
    var fetchCallCount = 0

    func isCodexInstalled() -> Bool { installed }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        fetchCallCount += 1
        if let error { throw error }
        return snapshot
    }
}
