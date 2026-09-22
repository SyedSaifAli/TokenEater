import Foundation
import Testing

@Suite("ProviderSessionStore")
@MainActor
struct ProviderSessionStoreTests {
    @Test("selected Claude is mirrored while only Codex is fetched")
    func selectedClaudeFetchesCodexCompanion() async {
        let apiClient = MockAPIClient()
        let tokenProvider = MockTokenProvider()
        tokenProvider.token = "claude-token"
        let codex = MockCodexUsageService()
        codex.snapshot = CodexUsageSnapshot(
            usage: UsageResponse(fiveHour: UsageBucket(utilization: 42, resetsAt: nil)),
            planType: .plus
        )
        let store = ProviderSessionStore(
            apiClient: apiClient,
            tokenProvider: tokenProvider,
            codexUsageService: codex
        )

        store.syncSelected(
            provider: .claude,
            usage: UsageResponse(
                fiveHour: UsageBucket(utilization: 18, resetsAt: nil),
                sevenDay: UsageBucket(utilization: 54, resetsAt: nil)
            )
        )
        await store.refreshCompanion(selectedProvider: .claude, proxyConfig: nil)

        #expect(store.claude?.percentage == 18)
        #expect(store.claudeWeekly?.percentage == 54)
        #expect(store.codex?.percentage == 42)
        #expect(codex.fetchCallCount == 1)
        #expect(apiClient.fetchCallCount == 0)
        #expect(tokenProvider.currentTokenCallCount == 0)
    }

    @Test("selected Codex is mirrored while only Claude is fetched")
    func selectedCodexFetchesClaudeCompanion() async {
        let apiClient = MockAPIClient()
        apiClient.stubbedUsage = UsageResponse(
            fiveHour: UsageBucket(utilization: 63, resetsAt: nil),
            sevenDay: UsageBucket(utilization: 72, resetsAt: nil)
        )
        let tokenProvider = MockTokenProvider()
        tokenProvider.token = "claude-token"
        let codex = MockCodexUsageService()
        let store = ProviderSessionStore(
            apiClient: apiClient,
            tokenProvider: tokenProvider,
            codexUsageService: codex
        )

        store.syncSelected(
            provider: .codex,
            usage: UsageResponse(fiveHour: UsageBucket(utilization: 27, resetsAt: nil))
        )
        await store.refreshCompanion(selectedProvider: .codex, proxyConfig: nil)

        #expect(store.codex?.percentage == 27)
        #expect(store.claude?.percentage == 63)
        #expect(store.claudeWeekly?.percentage == 72)
        #expect(apiClient.fetchCallCount == 1)
        #expect(codex.fetchCallCount == 0)
    }

    @Test("missing companion configuration hides only that provider")
    func missingConfiguration() async {
        let codex = MockCodexUsageService()
        codex.installed = false
        let store = ProviderSessionStore(
            apiClient: MockAPIClient(),
            tokenProvider: MockTokenProvider(),
            codexUsageService: codex
        )

        store.syncSelected(
            provider: .claude,
            usage: UsageResponse(fiveHour: UsageBucket(utilization: 12, resetsAt: nil))
        )
        await store.refreshCompanion(selectedProvider: .claude, proxyConfig: nil)

        #expect(store.claude?.percentage == 12)
        #expect(store.codex == nil)
        #expect(codex.fetchCallCount == 0)
    }

    @Test("missing Claude configuration hides session and weekly usage")
    func missingClaudeConfiguration() async {
        let tokenProvider = MockTokenProvider()
        tokenProvider.token = nil
        let store = ProviderSessionStore(
            apiClient: MockAPIClient(),
            tokenProvider: tokenProvider,
            codexUsageService: MockCodexUsageService()
        )

        store.syncSelected(
            provider: .claude,
            usage: UsageResponse(
                fiveHour: UsageBucket(utilization: 20, resetsAt: nil),
                sevenDay: UsageBucket(utilization: 60, resetsAt: nil)
            )
        )

        await store.refreshCompanion(selectedProvider: .codex, proxyConfig: nil)

        #expect(store.claude == nil)
        #expect(store.claudeWeekly == nil)
    }
}
