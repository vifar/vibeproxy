import Foundation

struct ProxyProviderModelLimit: Codable, Equatable {
    let context: Int
    let output: Int
}

struct ProxyProviderModelModalities: Codable, Equatable {
    let input: [String]
    let output: [String]
}

struct ProxyProviderModel: Codable, Equatable {
    let id: String
    let name: String
    let reasoning: Bool
    let toolCall: Bool
    let limit: ProxyProviderModelLimit
    let modalities: ProxyProviderModelModalities?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case reasoning
        case toolCall = "tool_call"
        case limit
        case modalities
    }
}

struct ProxyProviderEntry: Codable, Equatable {
    let id: String
    let api: String
    let name: String
    let models: [ProxyProviderModel]
}

enum ProxyProviderCatalogError: LocalizedError, Equatable {
    case invalidCatalog
    case missingProvider(String)
    case invalidProvider(String, String)
    case emptyModels(String)
    case mismatchedModelID(String, key: String, id: String)

    var errorDescription: String? {
        switch self {
        case .invalidCatalog:
            return "The proxy provider catalog is not a JSON object."
        case .missingProvider(let providerID):
            return "The proxy provider catalog does not contain \(providerID)."
        case .invalidProvider(let providerID, let message):
            return "The \(providerID) catalog entry is invalid: \(message)"
        case .emptyModels(let providerID):
            return "The \(providerID) catalog entry contains no models."
        case .mismatchedModelID(let providerID, let key, let id):
            return "The \(providerID) model key '\(key)' does not match id '\(id)'."
        }
    }
}

struct ProxyProviderCatalogDecodeResult: Equatable {
    var providers: [String: ProxyProviderEntry] = [:]
    var failures: [String: ProxyProviderCatalogError] = [:]
}

struct ProxyProviderCatalogRefreshResult: Equatable {
    let providers: [String: ProxyProviderEntry]
    let failures: [String: ProxyProviderCatalogError]
}

enum ProxyProviderCatalog {
    static let catalogURL = URL(string: "https://models.opencode.ai/api.json")!

    /// Managed proxy provider IDs mapped to their expected upstream API URLs.
    static let supportedProviderDefinitions: [String: String] = [
        "ollama-cloud": "https://ollama.com/v1",
        "opencode-go": "https://opencode.ai/zen/go/v1"
    ]

    static func decodeSupportedProviders(from data: Data) -> ProxyProviderCatalogDecodeResult {
        var result = ProxyProviderCatalogDecodeResult()
        let object = try? JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            for providerID in supportedProviderDefinitions.keys {
                result.failures[providerID] = .invalidCatalog
            }
            return result
        }

        for (providerID, expectedAPIURL) in supportedProviderDefinitions {
            do {
                result.providers[providerID] = try decodeProvider(
                    providerID,
                    expectedAPIURL: expectedAPIURL,
                    from: root
                )
            } catch let error as ProxyProviderCatalogError {
                result.failures[providerID] = error
            } catch {
                result.failures[providerID] = .invalidProvider(providerID, error.localizedDescription)
            }
        }
        return result
    }

    static func decodeProvider(
        _ providerID: String,
        expectedAPIURL: String,
        from root: [String: Any]
    ) throws -> ProxyProviderEntry {
        guard let providerObject = root[providerID] as? [String: Any] else {
            throw ProxyProviderCatalogError.missingProvider(providerID)
        }
        guard let id = providerObject["id"] as? String, id == providerID else {
            throw ProxyProviderCatalogError.invalidProvider(providerID, "id must be \(providerID)")
        }
        guard let api = providerObject["api"] as? String, api == expectedAPIURL else {
            throw ProxyProviderCatalogError.invalidProvider(providerID, "api must be \(expectedAPIURL)")
        }
        guard let name = providerObject["name"] as? String, !name.isEmpty else {
            throw ProxyProviderCatalogError.invalidProvider(providerID, "name must not be empty")
        }
        guard let modelObjects = providerObject["models"] as? [String: Any], !modelObjects.isEmpty else {
            throw ProxyProviderCatalogError.emptyModels(providerID)
        }

        let decoder = JSONDecoder()
        let models = try modelObjects.map { key, value -> ProxyProviderModel in
            let modelData = try JSONSerialization.data(withJSONObject: value)
            let model = try decoder.decode(ProxyProviderModel.self, from: modelData)
            guard model.id == key else {
                throw ProxyProviderCatalogError.mismatchedModelID(providerID, key: key, id: model.id)
            }
            guard !model.id.isEmpty, model.limit.context > 0, model.limit.output > 0 else {
                throw ProxyProviderCatalogError.invalidProvider(providerID, "model \(key) has invalid limits or id")
            }
            return model
        }
        .sorted { $0.id < $1.id }

        return ProxyProviderEntry(id: id, api: api, name: name, models: models)
    }

    static func modelRows(from entry: ProxyProviderEntry) -> [[String: String]] {
        entry.models.map { ["name": $0.id, "alias": $0.id] }
    }

    static func hasSameModelIDs(_ lhs: ProxyProviderEntry, _ rhs: ProxyProviderEntry) -> Bool {
        lhs.models.map(\.id) == rhs.models.map(\.id)
    }
}

struct ProxyProviderCatalogCacheEntry: Codable, Equatable {
    let providers: [String: ProxyProviderEntry]
    let fetchedAt: Date
}

struct ProxyProviderCatalogCache {
    let fileURL: URL

    func load() -> ProxyProviderCatalogCacheEntry? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ProxyProviderCatalogCacheEntry.self, from: data)
    }

    func save(providers: [String: ProxyProviderEntry], fetchedAt: Date = Date()) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let entry = ProxyProviderCatalogCacheEntry(providers: providers, fetchedAt: fetchedAt)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: fileURL, options: .atomic)
    }
}

final class ProxyProviderCatalogClient {
    typealias FetchData = (@escaping (Result<Data, Error>) -> Void) -> Void

    private let cache: ProxyProviderCatalogCache
    private let fetchData: FetchData

    init(cache: ProxyProviderCatalogCache, fetchData: @escaping FetchData = ProxyProviderCatalogClient.fetchRemoteData) {
        self.cache = cache
        self.fetchData = fetchData
    }

    func refresh(completion: @escaping (Result<ProxyProviderCatalogRefreshResult, Error>) -> Void) {
        fetchData { result in
            do {
                let decoded = ProxyProviderCatalog.decodeSupportedProviders(from: try result.get())
                _ = self.mergeIntoCache(decoded)
                completion(.success(
                    ProxyProviderCatalogRefreshResult(
                        providers: decoded.providers,
                        failures: decoded.failures
                    )
                ))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func mergeIntoCache(_ decoded: ProxyProviderCatalogDecodeResult) -> [String: ProxyProviderEntry] {
        var merged = cache.load()?.providers ?? [:]
        for (providerID, entry) in decoded.providers {
            merged[providerID] = entry
        }
        try? cache.save(providers: merged)
        return merged
    }

    private static func fetchRemoteData(completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: ProxyProviderCatalog.catalogURL)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data else {
                completion(.failure(ProxyProviderCatalogError.invalidCatalog))
                return
            }
            completion(.success(data))
        }.resume()
    }
}
