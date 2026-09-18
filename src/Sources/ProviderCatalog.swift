import Foundation

enum ProviderCatalog {
    static let managedZAIProviderName = "zai"

    /// First-class openai-compat providers. Hidden from the custom-provider UI
    /// via `reservedCustomProviderKeys`, but allowed under `openai-compatibility`
    /// so user model selection can persist `{name, models}` without a base-url.
    static let managedOpenAICompatibilityProviderIDs: Set<String> = [
        managedZAIProviderName, "ollama", "openrouter", "vercel"
    ]

    /// Managed proxy providers (catalog-synchronized openai-compatibility entries).
    static let managedProxyProviderDefinitions: [String: String] = ProxyProviderCatalog.supportedProviderDefinitions

    /// OAuth provider keys used in config.yaml oauth-excluded-models.
    static let oauthProviderKeys: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "gemini": "gemini-cli",
        "kimi": "kimi",
        "github-copilot": "github-copilot",
        "antigravity": "antigravity",
        "qwen": "qwen",
        "xai": "xai"
    ]

    static let reservedCustomProviderKeys = Set(oauthProviderKeys.keys)
        .union(oauthProviderKeys.values)
        .union(managedOpenAICompatibilityProviderIDs)
}
