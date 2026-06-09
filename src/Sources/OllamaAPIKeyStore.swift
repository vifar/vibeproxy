import Foundation

struct OllamaAPIKeyLoadIssue: Equatable {
    let filePath: URL
    let message: String
}

struct OllamaAPIKeyLoadResult: Equatable {
    let apiKeys: [String]
    let issues: [OllamaAPIKeyLoadIssue]
}

enum OllamaAPIKeyStoreError: LocalizedError {
    case failedToCreateDirectory(String)
    case failedToSerializeKey(String)
    case failedToWriteKey(String)
    case failedToReadKey(String)
    case invalidKeyJSON(String)
    case malformedKey(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreateDirectory(let message),
             .failedToSerializeKey(let message),
             .failedToWriteKey(let message),
             .failedToReadKey(let message),
             .invalidKeyJSON(let message),
             .malformedKey(let message):
            return message
        }
    }
}

final class OllamaAPIKeyStore {
    static let authType = "ollama"

    private let directoryURL: URL
    private let fileManager: FileManager
    private let queue: DispatchQueue

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        queueLabel: String = "io.automaze.vibeproxy.ollama-api-keys"
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    func save(
        apiKey: String,
        models: [String] = [],
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) throws -> URL {
        try queue.sync {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                throw OllamaAPIKeyStoreError.failedToCreateDirectory(
                    "Failed to create auth directory at \(directoryURL.path): \(error.localizedDescription)"
                )
            }

            let filename = "ollama-\(UUID().uuidString.prefix(8)).json"
            let filePath = directoryURL.appendingPathComponent(filename)
            var authData: [String: Any] = [
                "type": Self.authType,
                "email": maskAPIKey(apiKey),
                "api_key": apiKey,
                "created": createdAt
            ]
            if !models.isEmpty {
                authData["models"] = models
            }

            let jsonData: Data
            do {
                jsonData = try JSONSerialization.data(withJSONObject: authData, options: .prettyPrinted)
            } catch {
                throw OllamaAPIKeyStoreError.failedToSerializeKey(
                    "Failed to serialize Ollama API key: \(error.localizedDescription)"
                )
            }

            do {
                try jsonData.write(to: filePath, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
            } catch {
                throw OllamaAPIKeyStoreError.failedToWriteKey(
                    "Failed to write Ollama API key file at \(filePath.path): \(error.localizedDescription)"
                )
            }

            return filePath
        }
    }

    func loadActiveAPIKeys() -> OllamaAPIKeyLoadResult {
        queue.sync {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else {
                return OllamaAPIKeyLoadResult(apiKeys: [], issues: [])
            }

            var apiKeys: [String] = []
            var issues: [OllamaAPIKeyLoadIssue] = []

            for file in files where isManagedKeyFile(file) {
                do {
                    if let apiKey = try loadActiveAPIKey(at: file) {
                        apiKeys.append(apiKey)
                    }
                } catch let error as OllamaAPIKeyStoreError {
                    issues.append(
                        OllamaAPIKeyLoadIssue(
                            filePath: file,
                            message: error.localizedDescription
                        )
                    )
                } catch {
                    issues.append(
                        OllamaAPIKeyLoadIssue(
                            filePath: file,
                            message: "Unexpected error while loading \(file.path): \(error.localizedDescription)"
                        )
                    )
                }
            }

            return OllamaAPIKeyLoadResult(apiKeys: apiKeys, issues: issues)
        }
    }

    func loadActiveModels() -> [String] {
        queue.sync {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }

            var allModels: [String] = []
            for file in files where isManagedKeyFile(file) {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == Self.authType,
                      json["disabled"] as? Bool != true else {
                    continue
                }
                if let models = json["models"] as? [String] {
                    allModels.append(contentsOf: models.filter { !$0.isEmpty })
                } else if let model = json["model"] as? String, !model.isEmpty {
                    allModels.append(model)
                }
            }
            return Array(Set(allModels)).sorted()
        }
    }

    func loadActiveModel() -> String? {
        queue.sync {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else {
                return nil
            }

            for file in files where isManagedKeyFile(file) {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == Self.authType,
                      json["disabled"] as? Bool != true,
                      let model = json["model"] as? String, !model.isEmpty else {
                    continue
                }
                return model
            }
            return nil
        }
    }

    private func loadActiveAPIKey(at filePath: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: filePath)
        } catch {
            throw OllamaAPIKeyStoreError.failedToReadKey(
                "Failed to read Ollama API key file at \(filePath.path): \(error.localizedDescription)"
            )
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OllamaAPIKeyStoreError.invalidKeyJSON(
                "Ollama API key file at \(filePath.path) contains invalid JSON: \(error.localizedDescription)"
            )
        }

        guard let json = ConfigComposer.stringKeyedDictionary(jsonObject) else {
            throw OllamaAPIKeyStoreError.malformedKey(
                "Ollama API key file at \(filePath.path) must contain a JSON object."
            )
        }
        guard (json["type"] as? String) == Self.authType else {
            throw OllamaAPIKeyStoreError.malformedKey(
                "Ollama API key file at \(filePath.path) has an unexpected type."
            )
        }
        guard let apiKey = json["api_key"] as? String, !apiKey.isEmpty else {
            throw OllamaAPIKeyStoreError.malformedKey(
                "Ollama API key file at \(filePath.path) is missing an api_key."
            )
        }
        guard json["disabled"] as? Bool != true else {
            return nil
        }
        return apiKey
    }

    private func isManagedKeyFile(_ file: URL) -> Bool {
        file.lastPathComponent.hasPrefix("ollama-") && file.pathExtension == "json"
    }

    private func maskAPIKey(_ apiKey: String) -> String {
        guard apiKey.count > 12 else {
            return apiKey
        }
        return String(apiKey.prefix(8)) + "..." + String(apiKey.suffix(4))
    }
}
