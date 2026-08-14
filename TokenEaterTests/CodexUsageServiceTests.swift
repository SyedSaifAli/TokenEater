import Foundation
import Testing

@Suite("Codex usage service")
struct CodexUsageServiceTests {
    @Test("adapts Codex session and weekly windows")
    func adaptsBothWindows() throws {
        let account = Data(#"{"id":1,"result":{"account":{"type":"chatgpt","planType":"plus"},"requiresOpenaiAuth":true}}"#.utf8)
        let limits = Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":1786000000},"secondary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":1786500000},"planType":"plus"},"rateLimitsByLimitId":{}}}"#.utf8)

        let snapshot = try CodexUsageAdapter.snapshot(accountData: account, rateLimitsData: limits)

        #expect(snapshot.planType == .plus)
        #expect(snapshot.usage.fiveHour?.utilization == 31)
        #expect(snapshot.usage.sevenDay?.utilization == 64)
        #expect(snapshot.usage.fiveHour?.resetsAtDate != nil)
        #expect(snapshot.usage.sevenDay?.resetsAtDate != nil)
    }

    @Test("keeps a weekly-only Codex response out of the session gauge")
    func adaptsWeeklyOnly() throws {
        let account = Data(#"{"id":1,"result":{"account":{"type":"chatgpt","planType":"pro"}}}"#.utf8)
        let limits = Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":24,"windowDurationMins":10080,"resetsAt":1786171455},"secondary":null,"planType":"pro"}}}"#.utf8)

        let snapshot = try CodexUsageAdapter.snapshot(accountData: account, rateLimitsData: limits)

        #expect(snapshot.planType == .pro)
        #expect(snapshot.usage.fiveHour == nil)
        #expect(snapshot.usage.sevenDay?.utilization == 24)
    }

    @Test("rejects API-key-only auth because it has no ChatGPT limit window")
    func rejectsAPIKeyAuth() {
        let account = Data(#"{"id":1,"result":{"account":{"type":"apiKey","planType":null}}}"#.utf8)
        let limits = Data(#"{"id":2,"result":{"rateLimits":null}}"#.utf8)

        #expect(throws: CodexUsageServiceError.unsupportedAuthentication) {
            try CodexUsageAdapter.snapshot(accountData: account, rateLimitsData: limits)
        }
    }

    @Test("old cached usage defaults to Claude")
    func oldCacheDefaultsToClaude() throws {
        let data = Data(#"{"usage":{"five_hour":{"utilization":12,"resets_at":null}},"fetchDate":0}"#.utf8)
        let decoded = try JSONDecoder().decode(CachedUsage.self, from: data)

        #expect(decoded.provider == .claude)
        #expect(decoded.usage.fiveHour?.utilization == 12)
    }
}

@Suite("UsageStore Codex provider")
@MainActor
struct UsageStoreCodexTests {
    @Test("refresh uses Codex instead of the Claude token and repository")
    func refreshUsesCodex() async {
        let repository = MockUsageRepository()
        let tokenProvider = MockTokenProvider()
        tokenProvider.token = nil
        let codex = MockCodexUsageService()
        codex.snapshot = CodexUsageSnapshot(
            usage: UsageResponse(
                fiveHour: UsageBucket(utilization: 28, resetsAt: nil),
                sevenDay: UsageBucket(utilization: 57, resetsAt: nil)
            ),
            planType: .plus
        )
        let sharedFile = MockSharedFileService()
        let store = UsageStore(
            provider: .codex,
            repository: repository,
            tokenProvider: tokenProvider,
            codexUsageService: codex,
            sharedFileService: sharedFile,
            notificationService: MockNotificationService()
        )

        await store.refresh()

        #expect(codex.fetchCallCount == 1)
        #expect(repository.refreshCallCount == 0)
        #expect(tokenProvider.currentTokenCallCount == 0)
        #expect(store.fiveHourPct == 28)
        #expect(store.sevenDayPct == 57)
        #expect(store.planType == .plus)
        #expect(sharedFile.cachedUsage?.provider == .codex)
    }

    @Test("missing Codex installation reports disconnected without touching Claude")
    func missingCodex() async {
        let repository = MockUsageRepository()
        let tokenProvider = MockTokenProvider()
        let codex = MockCodexUsageService()
        codex.installed = false
        let store = UsageStore(
            provider: .codex,
            repository: repository,
            tokenProvider: tokenProvider,
            codexUsageService: codex,
            sharedFileService: MockSharedFileService(),
            notificationService: MockNotificationService()
        )

        await store.refresh()

        #expect(store.errorState == .tokenUnavailable)
        #expect(store.hasConfig == false)
        #expect(codex.fetchCallCount == 0)
        #expect(tokenProvider.currentTokenCallCount == 0)
    }
}
