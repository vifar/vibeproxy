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

        print("UserModelSelectionStoreSpec: all checks passed")
    }
}

struct SpecError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
