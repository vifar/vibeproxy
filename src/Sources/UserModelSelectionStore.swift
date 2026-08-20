import Foundation
import Yams

/// Persists the user's explicit model selection per provider in
/// `~/.cli-proxy-api/config.yaml` as `openai-compatibility[].models`.
///
/// This is the ONLY static model input in the system: when a provider has an
/// explicit `models` block here, it wins over the pulled catalog; when it does
/// not, the catalog drives the list automatically.
struct UserModelSelectionStore {
    let directoryURL: URL
    let userConfigFilename: String = "config.yaml"

    var userConfigURL: URL {
        directoryURL.appendingPathComponent(userConfigFilename)
    }

    /// Current user-authored model ids per provider, or nil when the provider
    /// has no explicit models block (catalog drives it).
    func selectedModelIDs(forProviderID providerID: String) -> [String]? {
        guard let root = loadRoot() else {
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

        do {
            let content = try Yams.dump(object: root)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try content.write(to: userConfigURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userConfigURL.path)
            return nil
        } catch {
            return "Failed to write model selection: \(error.localizedDescription)"
        }
    }

    /// Removes the provider's explicit models block (back to catalog-driven).
    func removeModelSelection(forProviderID providerID: String) -> String? {
        var root = loadRoot() ?? [:]
        var entries = ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"])
        let before = entries.count
        entries.removeAll { entry in
            ConfigComposer.normalizedProviderID(from: entry) == providerID
        }
        guard entries.count != before else {
            return nil
        }
        root["openai-compatibility"] = entries

        do {
            let content = try Yams.dump(object: root)
            try content.write(to: userConfigURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userConfigURL.path)
            return nil
        } catch {
            return "Failed to clear model selection: \(error.localizedDescription)"
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
