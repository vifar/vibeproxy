import Foundation

enum ProviderCatalog {
    static let managedZAIProviderName = "zai"

    // MARK: - Ollama
    static let ollamaProviderKey = "ollama"
    static let ollamaDefaultBaseURL = "http://localhost:11434/v1"
    static let ollamaHealthCheckURL = "http://localhost:11434/api/tags"

    /// OAuth provider keys used in config.yaml oauth-excluded-models.
    static let oauthProviderKeys: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "gemini": "gemini-cli",
        "kimi": "kimi",
        "github-copilot": "github-copilot",
        "antigravity": "antigravity",
        "qwen": "qwen"
    ]

    static let reservedCustomProviderKeys = Set(oauthProviderKeys.keys)
        .union(oauthProviderKeys.values)
        .union([managedZAIProviderName])
}
