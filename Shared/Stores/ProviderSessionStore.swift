import Foundation

/// Keeps the menu bar's provider-specific usage segments populated without
/// changing which provider drives the rest of the app. The selected provider
/// is supplied by `UsageStore`; this store fetches only the companion provider,
/// so it never duplicates the selected provider's request or writes its result
/// into the shared widget cache.
@MainActor
final class ProviderSessionStore: ObservableObject {
    struct Limit: Equatable, Sendable {
        let percentage: Int
        let resetDate: Date?
    }

    @Published private(set) var claude: Limit?
    @Published private(set) var claudeWeekly: Limit?
    @Published private(set) var codex: Limit?

    var refreshIntervalSeconds: TimeInterval = 300

    private let apiClient: APIClientProtocol
    private let tokenProvider: TokenProviderProtocol
    private let codexUsageService: CodexUsageServiceProtocol
    private var autoRefreshTask: Task<Void, Never>?
    private var isRefreshingCompanion = false

    init(
        apiClient: APIClientProtocol = APIClient(),
        tokenProvider: TokenProviderProtocol = TokenProvider(),
        codexUsageService: CodexUsageServiceProtocol = CodexUsageService()
    ) {
        self.apiClient = apiClient
        self.tokenProvider = tokenProvider
        self.codexUsageService = codexUsageService
    }

    /// Mirrors the selected provider from the already-fetched UsageStore
    /// response. A nil response means "not fetched yet" and deliberately keeps
    /// the last-known values; a successful response with a missing window clears
    /// that metric because there is no current limit to display.
    func syncSelected(provider: UsageProvider, usage: UsageResponse?) {
        guard let usage else { return }
        set(limit: usage.fiveHour.map(Self.limit), for: provider)
        if provider == .claude {
            setClaudeWeekly(usage.sevenDay.map(Self.limit))
        }
    }

    /// Fetches only the provider not currently selected in UsageStore. Errors
    /// preserve the last-known percentage, while a missing local configuration
    /// clears the value so the renderer can hide that segment.
    func refreshCompanion(selectedProvider: UsageProvider, proxyConfig: ProxyConfig?) async {
        guard !isRefreshingCompanion else { return }
        isRefreshingCompanion = true
        defer { isRefreshingCompanion = false }

        switch selectedProvider {
        case .claude:
            guard codexUsageService.isCodexInstalled() else {
                set(limit: nil, for: .codex)
                return
            }
            do {
                let snapshot = try await codexUsageService.fetchUsage()
                set(limit: snapshot.usage.fiveHour.map(Self.limit), for: .codex)
            } catch {
                // Keep the last-known value across transient app-server errors.
            }

        case .codex:
            guard let token = tokenProvider.currentToken() else {
                set(limit: nil, for: .claude)
                setClaudeWeekly(nil)
                return
            }
            do {
                let usage = try await apiClient.fetchUsage(token: token, proxyConfig: proxyConfig)
                set(limit: usage.fiveHour.map(Self.limit), for: .claude)
                setClaudeWeekly(usage.sevenDay.map(Self.limit))
            } catch {
                // Keep the last-known value across transient API errors.
            }
        }
    }

    func startAutoRefresh(
        selectedProvider: @escaping @MainActor () -> UsageProvider,
        proxyConfig: @escaping @MainActor () -> ProxyConfig?
    ) {
        stopAutoRefresh()
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshCompanion(
                    selectedProvider: selectedProvider(),
                    proxyConfig: proxyConfig()
                )
                try? await Task.sleep(for: .seconds(self.refreshIntervalSeconds))
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private static func limit(from bucket: UsageBucket) -> Limit {
        Limit(percentage: Int(bucket.utilization), resetDate: bucket.resetsAtDate)
    }

    private func set(limit: Limit?, for provider: UsageProvider) {
        switch provider {
        case .claude:
            guard claude != limit else { return }
            claude = limit
        case .codex:
            guard codex != limit else { return }
            codex = limit
        }
    }

    private func setClaudeWeekly(_ limit: Limit?) {
        guard claudeWeekly != limit else { return }
        claudeWeekly = limit
    }
}
