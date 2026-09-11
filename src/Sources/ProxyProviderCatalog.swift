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
    let uiPools: [String: ProxyProviderEntry]
}

enum ProxyProviderCatalog {
    static let catalogURL = URL(string: "https://models.opencode.ai/api.json")!

    /// Managed proxy provider IDs mapped to their expected upstream API URLs.
    static let supportedProviderDefinitions: [String: String] = [
        "ollama-cloud": "https://ollama.com/v1",
        "opencode-go": "https://opencode.ai/zen/go/v1"
    ]

    /// App provider key -> catalog id, used to build the UI model-selection
    /// pool for built-in OAuth providers. These pools are for display and user
    /// selection only; they are never injected into the proxy config.
    static let uiProviderPoolCatalogIDs: [String: String] = [
        "claude": "anthropic",
        "codex": "openai",
        "gemini": "google",
        "github-copilot": "github-copilot",
        "xai": "xai"
    ]

    /// Additional pull sources. These are not part of the shared catalog file;
    /// each is fetched from its own upstream endpoint at refresh time.
    static let openRouterAPIURL = "https://openrouter.ai/api/v1"
    static let zaiAPIBaseURL = "https://api.z.ai/api/coding/paas/v4"
    static let ollamaDefaultBaseURL = "http://localhost:11434"
    static let ollamaTagsPath = "/api/tags"

    /// OpenRouter's public /models endpoint. `data[]` entries carry
    /// id, name, context_length and top_provider.max_completion_tokens.
    static func decodeOpenRouter(from data: Data) -> ProxyProviderEntry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            return nil
        }
        let models = items.compactMap { item -> ProxyProviderModel? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String) ?? id
            let context = (item["context_length"] as? Int) ?? 128_000
            let output = ((item["top_provider"] as? [String: Any])?["max_completion_tokens"] as? Int) ?? 8_192
            return ProxyProviderModel(
                id: id,
                name: name,
                reasoning: (item["architecture"] as? [String: Any])?["reasoning"] as? Bool ?? false,
                toolCall: true,
                limit: ProxyProviderModelLimit(context: max(context, 1), output: max(output, 1)),
                modalities: nil
            )
        }.sorted { $0.id < $1.id }
        guard !models.isEmpty else { return nil }
        return ProxyProviderEntry(
            id: "openrouter",
            api: openRouterAPIURL,
            name: "OpenRouter",
            models: models
        )
    }

    /// Ollama's local /api/tags endpoint. `models[]` entries carry name/model.
    /// Context/output limits are unknowable locally, so defaults are used.
    static func decodeOllama(from data: Data, baseURL: String = ollamaDefaultBaseURL) -> ProxyProviderEntry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["models"] as? [[String: Any]] else {
            return nil
        }
        let models = items.compactMap { item -> ProxyProviderModel? in
            guard let rawName = (item["name"] as? String) ?? (item["model"] as? String),
                  !rawName.isEmpty else { return nil }
            // `name` is `model:tag`; the bare model name is the stable id.
            let id = rawName.components(separatedBy: ":").first ?? rawName
            return ProxyProviderModel(
                id: id,
                name: id,
                reasoning: false,
                toolCall: true,
                limit: ProxyProviderModelLimit(context: 8_192, output: 4_096),
                modalities: nil
            )
        }.sorted { $0.id < $1.id }
        guard !models.isEmpty else { return nil }
        return ProxyProviderEntry(
            id: "ollama",
            api: baseURL + "/v1",
            name: "Ollama",
            models: models
        )
    }

    /// Z.AI's OpenAI-compatible /models endpoint (requires the user's API key).
    /// `data[]` entries carry id; limits are not exposed, so defaults are used.
    static func decodeZAI(from data: Data, baseURL: String = zaiAPIBaseURL) -> ProxyProviderEntry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            return nil
        }
        let models = items.compactMap { item -> ProxyProviderModel? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return ProxyProviderModel(
                id: id,
                name: (item["name"] as? String) ?? id,
                reasoning: false,
                toolCall: true,
                limit: ProxyProviderModelLimit(context: 262_144, output: 8_192),
                modalities: nil
            )
        }.sorted { $0.id < $1.id }
        guard !models.isEmpty else { return nil }
        return ProxyProviderEntry(
            id: "zai",
            api: baseURL,
            name: "Z.AI",
            models: models
        )
    }

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

    /// Decode model pools for the built-in OAuth providers (UI selection only).
    /// Catalog entries use `id` + `api`; the app-side keys map via
    /// `uiProviderPoolCatalogIDs`.
    static func decodeUIProviderPools(from root: [String: Any]) -> [String: ProxyProviderEntry] {
        var pools: [String: ProxyProviderEntry] = [:]
        for (appKey, catalogID) in uiProviderPoolCatalogIDs {
            guard let entry = root[catalogID] as? [String: Any],
                  let models = entry["models"] as? [String: Any],
                  !models.isEmpty else {
                continue
            }
            let decoded = models.compactMap { key, value -> ProxyProviderModel? in
                guard let modelDict = value as? [String: Any],
                      let id = modelDict["id"] as? String, id == key else {
                    return nil
                }
                let name = (modelDict["name"] as? String) ?? id
                let limit = modelDict["limit"] as? [String: Any]
                return ProxyProviderModel(
                    id: id,
                    name: name,
                    reasoning: (modelDict["reasoning"] as? Bool) ?? false,
                    toolCall: (modelDict["tool_call"] as? Bool) ?? true,
                    limit: ProxyProviderModelLimit(
                        context: max((limit?["context"] as? Int) ?? 128_000, 1),
                        output: max((limit?["output"] as? Int) ?? 8_192, 1)
                    ),
                    modalities: nil
                )
            }.sorted { $0.id < $1.id }
            guard !decoded.isEmpty else { continue }
            pools[appKey] = ProxyProviderEntry(
                id: catalogID,
                api: (entry["api"] as? String) ?? "",
                name: (entry["name"] as? String) ?? catalogID,
                models: decoded
            )
        }
        return pools
    }

    static func hasSameModelIDs(_ lhs: ProxyProviderEntry, _ rhs: ProxyProviderEntry) -> Bool {
        lhs.models.map(\.id) == rhs.models.map(\.id)
    }
}

struct ProxyProviderCatalogCacheEntry: Codable, Equatable {
    let providers: [String: ProxyProviderEntry]
    let fetchedAt: Date
    /// Built-in OAuth provider pools (claude/codex/gemini/copilot/xai). Decoded
    /// from the same catalog payload but keyed by app provider id, so they need
    /// their own slot; without it they are lost on every restart and only a
    /// successful network refresh can restore them.
    let uiPools: [String: ProxyProviderEntry]?

    init(
        providers: [String: ProxyProviderEntry],
        fetchedAt: Date,
        uiPools: [String: ProxyProviderEntry]? = nil
    ) {
        self.providers = providers
        self.fetchedAt = fetchedAt
        self.uiPools = uiPools
    }
}

struct ProxyProviderCatalogCache {
    let fileURL: URL

    func load() -> ProxyProviderCatalogCacheEntry? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ProxyProviderCatalogCacheEntry.self, from: data)
    }

    func save(
        providers: [String: ProxyProviderEntry],
        uiPools: [String: ProxyProviderEntry]? = nil,
        fetchedAt: Date = Date()
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let entry = ProxyProviderCatalogCacheEntry(providers: providers, fetchedAt: fetchedAt, uiPools: uiPools)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: fileURL, options: .atomic)
    }
}

final class ProxyProviderCatalogClient {
    typealias FetchData = (@escaping (Result<Data, Error>) -> Void) -> Void

    private let cache: ProxyProviderCatalogCache
    private let fetchData: FetchData
    /// Optional per-provider pull sources (OpenRouter, Ollama, Z.AI). Injectable
    /// so the refresh's threading contract can be exercised without live network
    /// endpoints — the extra fetches are what the outer completion blocks on.
    private let fetchExtrasData: ((URL, String?, @escaping (Result<Data, Error>) -> Void) -> Void)?

    init(
        cache: ProxyProviderCatalogCache,
        fetchData: @escaping FetchData = { completion in
            ProxyProviderCatalogClient.fetchRemoteData(url: ProxyProviderCatalog.catalogURL, completion: completion)
        },
        fetchExtrasData: ((URL, String?, @escaping (Result<Data, Error>) -> Void) -> Void)? = nil
    ) {
        self.cache = cache
        self.fetchData = fetchData
        self.fetchExtrasData = fetchExtrasData
    }

    /// Delivers an extra fetch, honoring the injected override when present.
    private func fetchExtra(
        url: URL,
        authorization: String?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        if let fetchExtrasData {
            fetchExtrasData(url, authorization, completion)
        } else {
            Self.fetchRemoteData(url: url, authorization: authorization, completion: completion)
        }
    }

    func refresh(
        openRouterEnabled: Bool = false,
        ollamaBaseURL: String? = nil,
        zaiAPIKeys: [String] = [],
        completion: @escaping (Result<ProxyProviderCatalogRefreshResult, Error>) -> Void
    ) {
        fetchData { [weak self] result in
            guard let self else { return }
            // `fetchData` delivers on URLSession.shared's serial delegate queue,
            // and `fetchExtras` below blocks that same queue in an unbounded
            // DispatchGroup.wait() for its own nested URLSession.shared tasks.
            // Those completions can never be delivered while the queue is
            // blocked, so the refresh would hang forever and no catalog would
            // ever populate. Hop off the delegate queue before blocking.
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try result.get()
                    let primary = ProxyProviderCatalog.decodeSupportedProviders(from: data)
                    var providers = primary.providers
                    var failures = primary.failures
                    let uiPools: [String: ProxyProviderEntry]
                    if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        uiPools = ProxyProviderCatalog.decodeUIProviderPools(from: root)
                    } else {
                        uiPools = [:]
                    }

                    // Optional per-provider pull sources, fetched independently so
                    // one failure never blocks the others.
                    let extras = self.fetchExtras(
                        openRouterEnabled: openRouterEnabled,
                        ollamaBaseURL: ollamaBaseURL,
                        zaiAPIKeys: zaiAPIKeys
                    )
                    for (providerID, entry) in extras {
                        if let entry {
                            providers[providerID] = entry
                        } else {
                            failures[providerID] = .invalidProvider(providerID, "upstream model list unavailable")
                        }
                    }

                    self.mergeIntoCache(providers, uiPools: uiPools)
                    completion(.success(
                        ProxyProviderCatalogRefreshResult(
                            providers: providers,
                            failures: failures,
                            uiPools: uiPools
                        )
                    ))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func fetchExtras(
        openRouterEnabled: Bool,
        ollamaBaseURL: String?,
        zaiAPIKeys: [String]
    ) -> [(String, ProxyProviderEntry?)] {
        var results: [(String, ProxyProviderEntry?)] = []
        let group = DispatchGroup()
        let lock = NSLock()

        if openRouterEnabled {
            group.enter()
            fetchExtra(url: URL(string: ProxyProviderCatalog.openRouterAPIURL + "/models")!, authorization: nil) { result in
                var entry: ProxyProviderEntry?
                if case .success(let data) = result {
                    entry = ProxyProviderCatalog.decodeOpenRouter(from: data)
                }
                lock.lock(); results.append(("openrouter", entry)); lock.unlock()
                group.leave()
            }
        }

        if let ollamaBaseURL {
            group.enter()
            fetchExtra(url: URL(string: ollamaBaseURL + ProxyProviderCatalog.ollamaTagsPath)!, authorization: nil) { result in
                var entry: ProxyProviderEntry?
                if case .success(let data) = result {
                    entry = ProxyProviderCatalog.decodeOllama(from: data, baseURL: ollamaBaseURL)
                }
                lock.lock(); results.append(("ollama", entry)); lock.unlock()
                group.leave()
            }
        }

        if !zaiAPIKeys.isEmpty, let firstKey = zaiAPIKeys.first {
            group.enter()
            fetchExtra(
                url: URL(string: ProxyProviderCatalog.zaiAPIBaseURL + "/models")!,
                authorization: firstKey
            ) { result in
                var entry: ProxyProviderEntry?
                if case .success(let data) = result {
                    entry = ProxyProviderCatalog.decodeZAI(from: data)
                }
                lock.lock(); results.append(("zai", entry)); lock.unlock()
                group.leave()
            }
        }

        group.wait()
        return results.sorted { $0.0 < $1.0 }
    }

    private func mergeIntoCache(
        _ providers: [String: ProxyProviderEntry],
        uiPools: [String: ProxyProviderEntry]? = nil
    ) {
        let existing = cache.load()
        var merged = existing?.providers ?? [:]
        for (providerID, entry) in providers {
            merged[providerID] = entry
        }
        // A structurally valid payload can still yield no built-in OAuth pools
        // (for example a catalog that dropped one of those providers). Never let
        // that wipe a good cached pool, or the model list would empty out on
        // restart until the next successful refresh.
        let pools = (uiPools?.isEmpty == false) ? uiPools : existing?.uiPools
        try? cache.save(providers: merged, uiPools: pools)
    }

    private static func fetchRemoteData(
        url: URL,
        authorization: String? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
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
