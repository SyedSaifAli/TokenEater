import Foundation

/// The product whose account limits TokenEater displays.
///
/// Claude continues to use the existing OAuth data path. Codex uses the local
/// `codex app-server` protocol, which lets Codex own and refresh its own login
/// credentials instead of exposing them to TokenEater.
enum UsageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    static let defaultsKey = "usageProvider"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var cliDisplayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        }
    }

    var vendor: Vendor {
        switch self {
        case .claude: return .claude
        case .codex: return .openAI
        }
    }

    static var persisted: UsageProvider {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let provider = UsageProvider(rawValue: raw) else {
            return .claude
        }
        return provider
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
