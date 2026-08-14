import Foundation

enum CodexUsageServiceError: LocalizedError, Equatable {
    case executableNotFound
    case notAuthenticated
    case unsupportedAuthentication
    case appServerUnavailable(String)
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex CLI was not found. Install Codex, then run codex login."
        case .notAuthenticated:
            return "Codex is not signed in. Run codex login and try again."
        case .unsupportedAuthentication:
            return "Codex usage limits require ChatGPT sign-in; API-key-only login has no plan limit window."
        case .appServerUnavailable(let message):
            return message.isEmpty ? "Codex app-server is unavailable." : message
        case .invalidResponse:
            return "Codex returned an unsupported usage response."
        case .timedOut:
            return "Codex did not return usage data in time."
        }
    }
}

/// Resolves the CLI without invoking a login shell. GUI apps receive a very
/// small PATH, so Homebrew plus the common Node version-manager locations must
/// be considered explicitly.
struct CodexExecutableResolver {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: String

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) {
        self.fileManager = fileManager
        self.environment = environment
        if let homeDirectory {
            self.homeDirectory = homeDirectory
        } else if let pw = getpwuid(getuid()) {
            self.homeDirectory = String(cString: pw.pointee.pw_dir)
        } else {
            self.homeDirectory = NSHomeDirectory()
        }
    }

    func resolve() -> URL? {
        var candidates: [String] = []

        if let override = environment["TOKENEATER_CODEX_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(homeDirectory)/.local/bin/codex",
            "\(homeDirectory)/.volta/bin/codex",
            "\(homeDirectory)/.asdf/shims/codex",
            "\(homeDirectory)/.local/share/mise/shims/codex",
            "\(homeDirectory)/.npm-global/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ])

        candidates.append(contentsOf: versionManagedCandidates(
            root: "\(homeDirectory)/.local/share/fnm/node-versions",
            suffix: "installation/bin/codex"
        ))
        candidates.append(contentsOf: versionManagedCandidates(
            root: "\(homeDirectory)/.nvm/versions/node",
            suffix: "bin/codex"
        ))

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func versionManagedCandidates(root: String, suffix: String) -> [String] {
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return versions.sorted(by: >).map { "\(root)/\($0)/\(suffix)" }
    }
}

final class CodexUsageService: CodexUsageServiceProtocol, @unchecked Sendable {
    private let executableResolver: CodexExecutableResolver
    private let requestTimeout: TimeInterval

    init(
        executableResolver: CodexExecutableResolver = CodexExecutableResolver(),
        requestTimeout: TimeInterval = 10
    ) {
        self.executableResolver = executableResolver
        self.requestTimeout = requestTimeout
    }

    func isCodexInstalled() -> Bool {
        executableResolver.resolve() != nil
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        guard let executableURL = executableResolver.resolve() else {
            throw CodexUsageServiceError.executableNotFound
        }

        let responses = try await CodexAppServerRequest.perform(
            executableURL: executableURL,
            timeout: requestTimeout
        )
        return try CodexUsageAdapter.snapshot(
            accountData: responses.account,
            rateLimitsData: responses.rateLimits
        )
    }
}

// MARK: - Wire protocol

private struct CodexAppServerResponses {
    let account: Data
    let rateLimits: Data
}

/// One short-lived app-server process per refresh. Codex remains the sole owner
/// of its tokens and token refresh. Keeping stdin open until both replies arrive
/// prevents app-server from treating EOF as a request to shut down early.
private final class CodexAppServerRequest: @unchecked Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let continuation: CheckedContinuation<CodexAppServerResponses, Error>
    private let stateQueue = DispatchQueue(label: "com.tokeneater.codex-app-server")
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()

    private var buffer = Data()
    private var accountData: Data?
    private var rateLimitsData: Data?
    private var errorBuffer = Data()
    private var isFinished = false

    private init(
        executableURL: URL,
        timeout: TimeInterval,
        continuation: CheckedContinuation<CodexAppServerResponses, Error>
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.continuation = continuation
    }

    static func perform(executableURL: URL, timeout: TimeInterval) async throws -> CodexAppServerResponses {
        try await withCheckedThrowingContinuation { continuation in
            let request = CodexAppServerRequest(
                executableURL: executableURL,
                timeout: timeout,
                continuation: continuation
            )
            request.start()
        }
    }

    private func start() {
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // npm/fnm installations use `#!/usr/bin/env node`. Put the resolved
        // Codex directory first so the sibling Node binary is also resolvable
        // when TokenEater was launched by Finder with a minimal PATH.
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executableDirectory):/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            stateQueue.async { [self] in
                if data.isEmpty {
                    if !isFinished { finish(.failure(exitError())) }
                } else {
                    consume(data)
                }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stateQueue.async { [self] in errorBuffer.append(data) }
        }
        process.terminationHandler = { [self] _ in
            stateQueue.async { [self] in
                if !isFinished { finish(.failure(exitError())) }
            }
        }

        do {
            try process.run()
            try sendRequests()
        } catch {
            finish(.failure(CodexUsageServiceError.appServerUnavailable(error.localizedDescription)))
            return
        }

        stateQueue.asyncAfter(deadline: .now() + timeout) { [self] in
            if !isFinished { finish(.failure(CodexUsageServiceError.timedOut)) }
        }
    }

    private func sendRequests() throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "tokeneater",
                        "title": "TokenEater",
                        "version": version,
                    ],
                    "capabilities": [
                        "optOutNotificationMethods": ["account/rateLimits/updated"],
                    ],
                ],
            ],
            ["method": "initialized", "params": [:]],
            ["method": "account/read", "id": 1, "params": ["refreshToken": false]],
            ["method": "account/rateLimits/read", "id": 2, "params": [:]],
        ]

        let handle = inputPipe.fileHandleForWriting
        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else {
                continue // Ignore notifications and unfamiliar output.
            }
            if id == 1 { accountData = line }
            if id == 2 { rateLimitsData = line }
        }

        if let accountData, let rateLimitsData {
            finish(.success(CodexAppServerResponses(account: accountData, rateLimits: rateLimitsData)))
        }
    }

    private func exitError() -> Error {
        let message = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CodexUsageServiceError.appServerUnavailable(message)
    }

    private func finish(_ result: Result<CodexAppServerResponses, Error>) {
        guard !isFinished else { return }
        isFinished = true

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        continuation.resume(with: result)
    }
}

private struct CodexRPCError: Decodable {
    let message: String
}

private struct CodexRPCEnvelope<Result: Decodable>: Decodable {
    let result: Result?
    let error: CodexRPCError?
}

private struct CodexAccountResult: Decodable {
    let account: Account?

    struct Account: Decodable {
        let type: String
        let planType: String?
    }
}

private struct CodexRateLimitsResult: Decodable {
    let rateLimits: CodexRateLimitSnapshot?
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
}

private struct CodexRateLimitSnapshot: Decodable {
    let limitId: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
}

// MARK: - Adaptation to TokenEater's provider-neutral view model

enum CodexUsageAdapter {
    static func snapshot(accountData: Data, rateLimitsData: Data) throws -> CodexUsageSnapshot {
        let decoder = JSONDecoder()
        let accountEnvelope = try decoder.decode(CodexRPCEnvelope<CodexAccountResult>.self, from: accountData)
        if let error = accountEnvelope.error {
            throw CodexUsageServiceError.appServerUnavailable(error.message)
        }
        guard let account = accountEnvelope.result?.account else {
            throw CodexUsageServiceError.notAuthenticated
        }
        if account.type.lowercased().contains("api") {
            throw CodexUsageServiceError.unsupportedAuthentication
        }

        let limitsEnvelope = try decoder.decode(CodexRPCEnvelope<CodexRateLimitsResult>.self, from: rateLimitsData)
        if let error = limitsEnvelope.error {
            throw CodexUsageServiceError.appServerUnavailable(error.message)
        }
        guard let result = limitsEnvelope.result else {
            throw CodexUsageServiceError.invalidResponse
        }

        let preferred = result.rateLimits
            ?? result.rateLimitsByLimitId?["codex"]
            ?? result.rateLimitsByLimitId?.values.first
        guard let preferred else {
            throw CodexUsageServiceError.invalidResponse
        }

        let windows = [preferred.primary, preferred.secondary].compactMap { $0 }
        let session = windows
            .filter { ($0.windowDurationMins ?? 0) > 0 && ($0.windowDurationMins ?? 0) < 1_440 }
            .min { ($0.windowDurationMins ?? .max) < ($1.windowDurationMins ?? .max) }
        let weekly = windows
            .filter { ($0.windowDurationMins ?? 0) >= 1_440 }
            .max { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }

        // Older app-server versions may omit windowDurationMins. Preserve the
        // long-standing primary=session, secondary=weekly ordering as a narrow
        // compatibility fallback only when no explicit duration was supplied.
        let hasAnyDuration = windows.contains { $0.windowDurationMins != nil }
        let resolvedSession = session ?? (!hasAnyDuration ? preferred.primary : nil)
        let resolvedWeekly = weekly ?? (!hasAnyDuration ? preferred.secondary : nil)

        guard resolvedSession != nil || resolvedWeekly != nil else {
            throw CodexUsageServiceError.invalidResponse
        }

        let usage = UsageResponse(
            fiveHour: resolvedSession.map(usageBucket),
            sevenDay: resolvedWeekly.map(usageBucket)
        )
        let planType = PlanType(codexPlanType: preferred.planType ?? account.planType)
        return CodexUsageSnapshot(usage: usage, planType: planType)
    }

    private static func usageBucket(from window: CodexRateLimitWindow) -> UsageBucket {
        let resetsAt: String?
        if let epoch = window.resetsAt {
            resetsAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
        } else {
            resetsAt = nil
        }
        return UsageBucket(utilization: window.usedPercent, resetsAt: resetsAt)
    }
}
