import Foundation

@main
struct UserModelSelectionStoreSpec {
    static func main() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeproxy-selection-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let store = UserModelSelectionStore(directoryURL: temporaryDirectory)
        let configURL = store.userConfigURL

        // No config yet -> nil (catalog-driven), not an error.
        guard store.selectedModelIDs(forProviderID: "opencode-go") == nil else {
            throw SpecError("missing config must read as catalog-driven (nil)")
        }

        // First selection writes a config preserving nothing else (nothing to preserve).
        try store.setSelectedModelIDs(["muse-spark-1.2-contributor", "deepseek-v4-flash"], forProviderID: "opencode-go")
        guard store.selectedModelIDs(forProviderID: "opencode-go") == ["muse-spark-1.2-contributor", "deepseek-v4-flash"] else {
            throw SpecError("selection must round-trip")
        }

        // Second provider selection preserves the first provider's block.
        try store.setSelectedModelIDs(["glm-5.3"], forProviderID: "zai")
        guard store.selectedModelIDs(forProviderID: "opencode-go") == ["muse-spark-1.2-contributor", "deepseek-v4-flash"] else {
            throw SpecError("first provider selection must survive a second provider write")
        }
        guard store.selectedModelIDs(forProviderID: "zai") == ["glm-5.3"] else {
            throw SpecError("second provider selection must round-trip")
        }

        // Unrelated top-level keys survive.
        let content = try String(contentsOf: configURL, encoding: .utf8)
        guard content.contains("openai-compatibility") else {
            throw SpecError("config must contain openai-compatibility")
        }

        // Clear restores catalog-driven (provider block removed).
        try store.removeModelSelection(forProviderID: "zai")
        guard store.selectedModelIDs(forProviderID: "zai") == nil else {
            throw SpecError("cleared provider must read as catalog-driven (nil)")
        }
        guard store.selectedModelIDs(forProviderID: "opencode-go") != nil else {
            throw SpecError("clearing one provider must not clear the other")
        }

        // OAuth providers persist as oauth-included-models, never openai-compatibility.
        try store.setSelectedModelIDs(["grok-4.6"], forProviderID: "xai")
        guard store.selectedModelIDs(forProviderID: "xai") == ["grok-4.6"] else {
            throw SpecError("xai selection must round-trip via oauth-included-models")
        }
        let oauthContent = try String(contentsOf: configURL, encoding: .utf8)
        guard oauthContent.contains("oauth-included-models") else {
            throw SpecError("xai selection must write oauth-included-models")
        }
        guard !oauthContent.contains("name: xai") else {
            throw SpecError("xai selection must not write a reserved openai-compatibility entry")
        }
        guard store.selectedModelIDs(forProviderID: "opencode-go") != nil else {
            throw SpecError("oauth selection must not drop openai-compat selections")
        }

        // A leftover reserved openai-compat block is stripped on the next oauth write.
        try """
        openai-compatibility:
        - name: xai
          models:
          - name: grok-4.5
            alias: grok-4.5
        oauth-included-models:
          xai:
          - grok-4.5
        """.write(to: configURL, atomically: true, encoding: .utf8)
        try store.setSelectedModelIDs(["grok-4.6"], forProviderID: "xai")
        let repaired = try String(contentsOf: configURL, encoding: .utf8)
        guard !repaired.contains("name: xai") else {
            throw SpecError("oauth write must strip leftover reserved openai-compatibility entries")
        }
        guard store.selectedModelIDs(forProviderID: "xai") == ["grok-4.6"] else {
            throw SpecError("oauth write after leftover strip must persist the new selection")
        }

        try store.removeModelSelection(forProviderID: "xai")
        guard store.selectedModelIDs(forProviderID: "xai") == nil else {
            throw SpecError("cleared xai selection must read as catalog-driven")
        }

        print("UserModelSelectionStoreSpec: all checks passed")
    }
}

struct SpecError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
