import Foundation

@main
struct ProxyProviderCatalogSpec {
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let data = try Data(contentsOf: ProxyProviderCatalog.catalogURL)
            let result = ProxyProviderCatalog.decodeSupportedProviders(from: data)
            guard result.failures.isEmpty else {
                throw VerificationError(message: "live catalog validation failed: \(result.failures)")
            }
            for providerID in ProxyProviderCatalog.supportedProviderDefinitions.keys {
                guard let entry = result.providers[providerID], !entry.models.isEmpty else {
                    throw VerificationError(message: "live catalog missing \(providerID)")
                }
            }
            let count = result.providers.values.reduce(0) { $0 + $1.models.count }
            print("ProxyProviderCatalogSpec: live catalog validated \(result.providers.count) providers with \(count) exact models")
            return
        }

        let fixture = Data(
            """
            {
              "other": {"id":"other","api":"https://example.com/v1","name":"Other","models":{}},
              "ollama-cloud": {
                "id": "ollama-cloud",
                "api": "https://ollama.com/v1",
                "name": "Ollama Cloud",
                "models": {
                  "kimi-k3": {
                    "id": "kimi-k3",
                    "name": "Kimi K3",
                    "reasoning": true,
                    "tool_call": true,
                    "limit": {"context": 1048576, "output": 131072},
                    "modalities": {"input": ["text", "image"], "output": ["text"]}
                  },
                  "deepseek-v4-pro": {
                    "id": "deepseek-v4-pro",
                    "name": "DeepSeek V4 Pro",
                    "reasoning": true,
                    "tool_call": true,
                    "limit": {"context": 1048576, "output": 1048576},
                    "modalities": {"input": ["text"], "output": ["text"]}
                  }
                }
              },
              "opencode-go": {
                "id": "opencode-go",
                "api": "https://opencode.ai/zen/go/v1",
                "name": "OpenCode Go",
                "models": {
                  "grok-4.5": {
                    "id": "grok-4.5",
                    "name": "Grok 4.5",
                    "reasoning": true,
                    "tool_call": true,
                    "limit": {"context": 262144, "output": 131072},
                    "modalities": {"input": ["text"], "output": ["text"]}
                  },
                  "kimi-k3": {
                    "id": "kimi-k3",
                    "name": "Kimi K3",
                    "reasoning": true,
                    "tool_call": true,
                    "limit": {"context": 1048576, "output": 131072},
                    "modalities": {"input": ["text", "image"], "output": ["text"]}
                  }
                }
              }
            }
            """.utf8
        )

        let result = ProxyProviderCatalog.decodeSupportedProviders(from: fixture)
        expectEqual(result.failures, [:], "both supported providers should decode without failures")

        let ollama = try require(result.providers["ollama-cloud"], "ollama-cloud entry")
        expectEqual(ollama.id, "ollama-cloud", "ollama-cloud provider id")
        expectEqual(ollama.api, "https://ollama.com/v1", "ollama-cloud upstream api")
        expectEqual(ollama.models.map(\.id), ["deepseek-v4-pro", "kimi-k3"], "ollama-cloud sorted exact model ids")
        expectEqual(ollama.models.first?.limit.context, 1_048_576, "ollama-cloud context limit")
        expectEqual(ollama.models.first?.toolCall, true, "ollama-cloud tool capability")
        expectEqual(
            ProxyProviderCatalog.modelRows(from: ollama),
            [
                ["name": "deepseek-v4-pro", "alias": "deepseek-v4-pro"],
                ["name": "kimi-k3", "alias": "kimi-k3"]
            ],
            "ollama-cloud routing rows preserve exact ids"
        )

        let go = try require(result.providers["opencode-go"], "opencode-go entry")
        expectEqual(go.id, "opencode-go", "opencode-go provider id")
        expectEqual(go.api, "https://opencode.ai/zen/go/v1", "opencode-go upstream api")
        expectEqual(go.models.map(\.id), ["grok-4.5", "kimi-k3"], "opencode-go sorted exact model ids")
        expectEqual(
            ProxyProviderCatalog.modelRows(from: go),
            [
                ["name": "grok-4.5", "alias": "grok-4.5"],
                ["name": "kimi-k3", "alias": "kimi-k3"]
            ],
            "opencode-go routing rows preserve exact ids"
        )

        let missingGo = ProxyProviderCatalog.decodeSupportedProviders(
            from: Data("{\"ollama-cloud\":{\"id\":\"ollama-cloud\",\"api\":\"https://ollama.com/v1\",\"name\":\"Ollama Cloud\",\"models\":{\"kimi-k3\":{\"id\":\"kimi-k3\",\"name\":\"Kimi K3\",\"reasoning\":true,\"tool_call\":true,\"limit\":{\"context\":1,\"output\":1}}}}}".utf8)
        )
        expectEqual(missingGo.providers["ollama-cloud"]?.id, "ollama-cloud", "valid provider survives a missing sibling")
        expectEqual(missingGo.failures["opencode-go"], .missingProvider("opencode-go"), "missing sibling fails independently")

        let wrongAPI = ProxyProviderCatalog.decodeSupportedProviders(
            from: Data("{\"opencode-go\":{\"id\":\"opencode-go\",\"api\":\"https://wrong.example.com/v1\",\"name\":\"OpenCode Go\",\"models\":{\"kimi-k3\":{\"id\":\"kimi-k3\",\"name\":\"Kimi K3\",\"reasoning\":true,\"tool_call\":true,\"limit\":{\"context\":1,\"output\":1}}}}}".utf8)
        )
        expectEqual(
            wrongAPI.failures["opencode-go"],
            .invalidProvider("opencode-go", "api must be https://opencode.ai/zen/go/v1"),
            "unexpected upstream api fails independently"
        )

        let emptyModels = ProxyProviderCatalog.decodeSupportedProviders(
            from: Data("{\"ollama-cloud\":{\"id\":\"ollama-cloud\",\"api\":\"https://ollama.com/v1\",\"name\":\"Ollama Cloud\",\"models\":{}}}".utf8)
        )
        expectEqual(emptyModels.failures["ollama-cloud"], .emptyModels("ollama-cloud"), "empty models fail independently")

        let mismatched = ProxyProviderCatalog.decodeSupportedProviders(
            from: Data("{\"ollama-cloud\":{\"id\":\"ollama-cloud\",\"api\":\"https://ollama.com/v1\",\"name\":\"Ollama Cloud\",\"models\":{\"alias\":{\"id\":\"different\",\"name\":\"Different\",\"reasoning\":false,\"tool_call\":false,\"limit\":{\"context\":1,\"output\":1}}}}}".utf8)
        )
        expectEqual(
            mismatched.failures["ollama-cloud"],
            .mismatchedModelID("ollama-cloud", key: "alias", id: "different"),
            "mismatched model key fails independently"
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibeproxy-proxy-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let cache = ProxyProviderCatalogCache(
            fileURL: temporaryDirectory.appendingPathComponent("proxy-provider-catalog.json")
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_786_000_000)
        try cache.save(providers: result.providers, fetchedAt: fetchedAt)
        let loaded = try require(cache.load(), "saved cache should load")
        expectEqual(loaded.providers, result.providers, "cache provider round trip")
        expectEqual(loaded.fetchedAt, fetchedAt, "cache timestamp round trip")

        try Data("not json".utf8).write(to: temporaryDirectory.appendingPathComponent("proxy-provider-catalog.json"))
        expectEqual(cache.load(), nil, "malformed cache is ignored")

        let refreshCache = ProxyProviderCatalogCache(
            fileURL: temporaryDirectory.appendingPathComponent("refreshed-catalog.json")
        )
        let refreshClient = ProxyProviderCatalogClient(
            cache: refreshCache,
            fetchData: { completion in completion(.success(fixture)) }
        )
        let refreshResult = waitForRefresh(refreshClient)
        let refreshValue = try refreshResult.get()
        expectEqual(refreshValue.failures, [:], "refresh reports no failures")
        expectEqual(refreshValue.providers, result.providers, "refresh returns validated providers")
        expectEqual(refreshCache.load()?.providers, result.providers, "refresh persists last-known-good providers")

        let invalidSiblingClient = ProxyProviderCatalogClient(
            cache: refreshCache,
            fetchData: { completion in completion(.success(Data("{}".utf8))) }
        )
        let invalidSiblingResult = waitForRefresh(invalidSiblingClient)
        let invalidValue = try invalidSiblingResult.get()
        expectEqual(invalidValue.providers, [:], "invalid refresh yields no providers")
        expectEqual(
            invalidValue.failures["ollama-cloud"],
            .missingProvider("ollama-cloud"),
            "missing provider reported after refresh"
        )
        expectEqual(
            refreshCache.load()?.providers,
            result.providers,
            "invalid refresh preserves last-known-good cache"
        )

        expectEqual(
            ProxyProviderCatalog.hasSameModelIDs(ollama, ollama),
            true,
            "identical model sets compare equal"
        )
        let reducedOllama = ProxyProviderEntry(
            id: ollama.id,
            api: ollama.api,
            name: ollama.name,
            models: Array(ollama.models.prefix(1))
        )
        expectEqual(
            ProxyProviderCatalog.hasSameModelIDs(ollama, reducedOllama),
            false,
            "different model sets compare unequal"
        )

        print("ProxyProviderCatalogSpec: all checks passed")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("\(message): got \(actual), expected \(expected)")
    }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) {
    do {
        try body()
        fatalError("\(message): expected an error")
    } catch {
        return
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw VerificationError(message: message)
    }
    return value
}

private struct VerificationError: Error {
    let message: String
}

private func waitForRefresh(_ client: ProxyProviderCatalogClient) -> Result<ProxyProviderCatalogRefreshResult, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<ProxyProviderCatalogRefreshResult, Error>?
    client.refresh { refreshResult in
        result = refreshResult
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 2) == .success, let result else {
        return .failure(VerificationError(message: "catalog refresh timed out"))
    }
    return result
}
