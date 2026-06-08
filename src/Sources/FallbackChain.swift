import Foundation

/// A single provider slot in the fallback chain.
struct FallbackProvider: Codable, Equatable {
    enum Kind: String, Codable {
        /// Routes through the bundled cli-proxy-api-plus (all OAuth/ZAI/custom providers).
        case primary
        /// Direct connection to a local Ollama daemon (no API key, plain HTTP).
        case ollama
        /// Any OpenAI-compatible endpoint reached directly by ThinkingProxy.
        case openaiCompatible
    }

    var kind: Kind
    /// Human-readable label shown in Settings.
    var label: String
    /// Base URL for `ollama` and `openaiCompatible`; nil for `primary`.
    var baseURL: String?
    /// API key for `openaiCompatible`; nil for `primary` and `ollama`.
    var apiKey: String?
    /// Model name to substitute into the request body when this provider is used.
    /// If nil, the original model name from the client request is left unchanged.
    var fallbackModel: String?

    // MARK: - Built-in defaults

    static let defaultPrimary = FallbackProvider(
        kind: .primary,
        label: "Primary (via proxy)",
        baseURL: nil,
        apiKey: nil,
        fallbackModel: nil
    )

    static func defaultOllama(model: String = "llama3.2") -> FallbackProvider {
        FallbackProvider(
            kind: .ollama,
            label: "Ollama (local)",
            baseURL: ProviderCatalog.ollamaDefaultBaseURL,
            apiKey: nil,
            fallbackModel: model
        )
    }
}

/// HTTP status codes / error patterns that trigger a fallback attempt.
enum FallbackTrigger {
    /// True when the given HTTP status code should trigger chain advancement.
    static func shouldFallback(httpStatus: Int) -> Bool {
        switch httpStatus {
        case 429:           return true   // rate-limit / quota exhausted
        case 401, 403:      return true   // auth failure / no tokens
        case 500, 502, 503, 504: return true  // upstream error
        default:            return false
        }
    }

    /// True when the response body (or partial body) indicates an error that
    /// should trigger a fallback even though the HTTP status was 200.
    static func shouldFallback(onBodySnippet body: String) -> Bool {
        let triggers = [
            "insufficient_quota",
            "rate_limit_exceeded",
            "overloaded_error",
            "Service Unavailable",
        ]
        return triggers.contains { body.contains($0) }
    }
}

/// Persists and vends the ordered fallback provider chain.
///
/// The chain is stored as JSON in `UserDefaults`. The first entry is always
/// `.primary` and is never removed; additional providers are appended by the user.
final class FallbackChainStore: ObservableObject {
    private static let defaultsKey = "fallbackChain"

    @Published private(set) var providers: [FallbackProvider] = []

    init() {
        providers = load()
    }

    // MARK: - Mutations

    func append(_ provider: FallbackProvider) {
        providers.append(provider)
        save()
    }

    func remove(at index: Int) {
        guard index > 0, index < providers.count else { return }   // primary is immutable
        providers.remove(at: index)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        // Never move the primary provider (index 0).
        let safeSource = source.filteredIndexSet { $0 > 0 }
        guard !safeSource.isEmpty else { return }
        providers.move(fromOffsets: safeSource, toOffset: max(1, destination))
        save()
    }

    func update(_ provider: FallbackProvider, at index: Int) {
        guard index < providers.count else { return }
        providers[index] = provider
        save()
    }

    // MARK: - Persistence

    private func load() -> [FallbackProvider] {
        guard
            let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([FallbackProvider].self, from: data),
            !decoded.isEmpty
        else {
            return [.defaultPrimary]
        }
        // Always ensure primary is first.
        if decoded[0].kind != .primary {
            return [.defaultPrimary] + decoded.filter { $0.kind != .primary }
        }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
