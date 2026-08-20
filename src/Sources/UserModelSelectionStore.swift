import Foundation
import Yams

/// Persists the user's explicit model selection per provider in
/// `~/.cli-proxy-api/config.yaml`.
///
/// OpenAI-compatible providers keep their selection as
/// `openai-compatibility[].models`. OAuth providers (Claude, Codex, Gemini,
/// Copilot, xAI, …) cannot be declared there — those names are reserved and
/// have no `base-url` — so their selection is stored as
/// `oauth-included-models` and composed into `oauth-excluded-models` at
/// runtime as the catalog complement.
struct UserModelSelectionStore {
    let directoryURL: URL
    let userConfigFilename: String = "config.yaml"

    var userConfigURL: URL {
        directoryURL.appendingPathComponent(userConfigFilename)
    }

    /// Current user-authored model ids per provider, or nil when the provider
    /// has no explicit selection (catalog drives it).
    func selectedModelIDs(forProviderID providerID: String) -> [String]? {
        guard let root = loadRoot() else {
            return nil
        }
        if let oauthKey = ConfigComposer.oauthKey(forProviderID: providerID) {
            let included = ConfigComposer.includedOAuthModels(from: root)
            if let models = included[oauthKey] {
                return models
            }
            return nil
        }
        for entry in ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"]) {
            guard ConfigComposer.normalizedProviderID(from: entry) == providerID else {
                continue
            }
            let rows = ConfigComposer.stringKeyedDictionaryArray(entry["models"])
            guard !rows.isEmpty else {
                return []
            }
            return rows.compactMap {
                ($0["alias"] as? String) ?? ($0["name"] as? String)
            }
        }
        return nil
    }

    /// Writes the explicit model selection for a provider. Empty array keeps
    /// the provider present with no models. Returns nil on success or an
    /// error message. Preserves every other key in the user config.
    func setSelectedModelIDs(_ modelIDs: [String], forProviderID providerID: String) -> String? {
        var root = loadRoot() ?? [:]
        if let oauthKey = ConfigComposer.oauthKey(forProviderID: providerID) {
            stripReservedOpenAICompatibilityEntries(from: &root, matching: oauthKey)
            var included = ConfigComposer.includedOAuthModels(from: root)
            included[oauthKey] = modelIDs
            root["oauth-included-models"] = included
            return writeRoot(root, failurePrefix: "Failed to write model selection")
        }

        let rows = modelIDs.map { ["name": $0, "alias": $0] }
        var entries = ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"])
        var foundIndex: Int?
        for (index, entry) in entries.enumerated() {
            if ConfigComposer.normalizedProviderID(from: entry) == providerID {
                foundIndex = index
                break
            }
        }
        if let foundIndex {
            var entry = entries[foundIndex]
            entry["models"] = rows
            entries[foundIndex] = entry
        } else {
            entries.append(["name": providerID, "models": rows])
        }
        root["openai-compatibility"] = entries
        return writeRoot(root, failurePrefix: "Failed to write model selection")
    }

    /// Removes the provider's explicit selection (back to catalog-driven).
    func removeModelSelection(forProviderID providerID: String) -> String? {
        var root = loadRoot() ?? [:]
        if let oauthKey = ConfigComposer.oauthKey(forProviderID: providerID) {
            stripReservedOpenAICompatibilityEntries(from: &root, matching: oauthKey)
            var included = ConfigComposer.includedOAuthModels(from: root)
            guard included.removeValue(forKey: oauthKey) != nil else {
                return nil
            }
            if included.isEmpty {
                root.removeValue(forKey: "oauth-included-models")
            } else {
                root["oauth-included-models"] = included
            }
            return writeRoot(root, failurePrefix: "Failed to clear model selection")
        }

        var entries = ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"])
        let before = entries.count
        entries.removeAll { entry in
            ConfigComposer.normalizedProviderID(from: entry) == providerID
        }
        guard entries.count != before else {
            return nil
        }
        root["openai-compatibility"] = entries
        return writeRoot(root, failurePrefix: "Failed to clear model selection")
    }

    private func stripReservedOpenAICompatibilityEntries(from root: inout [String: Any], matching oauthKey: String) {
        var entries = ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"])
        entries.removeAll { entry in
            guard let name = ConfigComposer.normalizedProviderID(from: entry) else {
                return false
            }
            return name == oauthKey || ConfigComposer.oauthKey(forProviderID: name) == oauthKey
        }
        if entries.isEmpty {
            root.removeValue(forKey: "openai-compatibility")
        } else {
            root["openai-compatibility"] = entries
        }
    }

    private func writeRoot(_ root: [String: Any], failurePrefix: String) -> String? {
        do {
            let content = try Yams.dump(object: root)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try content.write(to: userConfigURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userConfigURL.path)
            return nil
        } catch {
            return "\(failurePrefix): \(error.localizedDescription)"
        }
    }

    private func loadRoot() -> [String: Any]? {
        guard let data = try? Data(contentsOf: userConfigURL),
              let loaded = try? Yams.load(yaml: String(data: data, encoding: .utf8) ?? ""),
              let root = ConfigComposer.stringKeyedDictionary(loaded) else {
            return nil
        }
        return root
    }
}
