import Foundation

struct CodexUsageSnapshot {
    let usage: UsageResponse
    let planType: PlanType
}

protocol CodexUsageServiceProtocol: Sendable {
    /// True when a Codex executable can be resolved without starting it.
    func isCodexInstalled() -> Bool
    /// Reads the signed-in account's limits through Codex's local app-server.
    func fetchUsage() async throws -> CodexUsageSnapshot
}
