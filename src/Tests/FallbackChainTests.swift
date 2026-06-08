import XCTest
@testable import CLIProxyMenuBar

final class FallbackChainTests: XCTestCase {

    // MARK: - FallbackTrigger

    func testShouldFallbackOn429() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(httpStatus: 429))
    }

    func testShouldFallbackOn401() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(httpStatus: 401))
    }

    func testShouldFallbackOn403() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(httpStatus: 403))
    }

    func testShouldFallbackOn502() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(httpStatus: 502))
    }

    func testShouldFallbackOn503() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(httpStatus: 503))
    }

    func testShouldFallbackOn500() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(httpStatus: 500))
    }

    func testShouldNotFallbackOn200() {
        XCTAssertFalse(FallbackTrigger.shouldFallback(httpStatus: 200))
    }

    func testShouldNotFallbackOn400() {
        XCTAssertFalse(FallbackTrigger.shouldFallback(httpStatus: 400))
    }

    func testShouldNotFallbackOn404() {
        XCTAssertFalse(FallbackTrigger.shouldFallback(httpStatus: 404))
    }

    func testBodyTriggerInsufficientQuota() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(onBodySnippet: "{\"error\": \"insufficient_quota\"}"))
    }

    func testBodyTriggerRateLimitExceeded() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(onBodySnippet: "rate_limit_exceeded"))
    }

    func testBodyTriggerOverloaded() {
        XCTAssertTrue(FallbackTrigger.shouldFallback(onBodySnippet: "overloaded_error"))
    }

    func testBodyNoTriggerOnNormalResponse() {
        XCTAssertFalse(FallbackTrigger.shouldFallback(onBodySnippet: "{\"choices\": [{\"message\": {\"content\": \"hello\"}}]}"))
    }

    // MARK: - FallbackProvider defaults

    func testDefaultPrimaryKind() {
        XCTAssertEqual(FallbackProvider.defaultPrimary.kind, .primary)
    }

    func testDefaultOllamaKind() {
        XCTAssertEqual(FallbackProvider.defaultOllama().kind, .ollama)
    }

    func testDefaultOllamaBaseURL() {
        XCTAssertEqual(FallbackProvider.defaultOllama().baseURL, ProviderCatalog.ollamaDefaultBaseURL)
    }

    func testDefaultOllamaCustomModel() {
        XCTAssertEqual(FallbackProvider.defaultOllama(model: "mistral").fallbackModel, "mistral")
    }

    // MARK: - FallbackChainStore

    func testStoreDefaultsToSinglePrimaryProvider() {
        // Use a fresh UserDefaults suite so we don't pollute real prefs
        UserDefaults.standard.removeObject(forKey: "fallbackChain")
        let store = FallbackChainStore()
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers[0].kind, .primary)
    }

    func testStoreAppendAndRemove() {
        UserDefaults.standard.removeObject(forKey: "fallbackChain")
        let store = FallbackChainStore()
        store.append(.defaultOllama())
        XCTAssertEqual(store.providers.count, 2)
        store.remove(at: 1)
        XCTAssertEqual(store.providers.count, 1)
    }

    func testStorePrimaryCannotBeRemoved() {
        UserDefaults.standard.removeObject(forKey: "fallbackChain")
        let store = FallbackChainStore()
        store.remove(at: 0)   // should be a no-op
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers[0].kind, .primary)
    }

    func testStorePrimaryAlwaysFirst() {
        UserDefaults.standard.removeObject(forKey: "fallbackChain")
        let store = FallbackChainStore()
        store.append(.defaultOllama())
        // Try to move Ollama (index 1) before primary (index 0)
        store.move(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.providers[0].kind, .primary,
                       "Primary must remain at index 0 after attempted reorder")
    }
}

// MARK: - ConfigComposer Ollama

final class ConfigComposerOllamaTests: XCTestCase {

    func testOllamaEntryEmittedWhenModelsProvided() {
        let baseRoot: [String: Any] = [:]
        let result = ConfigComposer.composeRuntimeConfig(
            baseRoot: baseRoot,
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [],
            includeManagedZAIProvider: false,
            ollamaFallbackModels: ["llama3.2", "mistral"]
        )

        let entries = result["openai-compatibility"] as? [[String: Any]]
        let ollamaEntry = entries?.first { ($0["name"] as? String) == "ollama" }
        XCTAssertNotNil(ollamaEntry, "Expected an 'ollama' entry in openai-compatibility")
        XCTAssertEqual(ollamaEntry?["base-url"] as? String, ProviderCatalog.ollamaDefaultBaseURL)

        let models = ollamaEntry?["models"] as? [[String: String]]
        XCTAssertEqual(models?.count, 2)
        XCTAssertEqual(models?[0]["name"], "llama3.2")
        XCTAssertEqual(models?[1]["name"], "mistral")
    }

    func testNoOllamaEntryWhenModelsEmpty() {
        let baseRoot: [String: Any] = [:]
        let result = ConfigComposer.composeRuntimeConfig(
            baseRoot: baseRoot,
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [],
            includeManagedZAIProvider: false,
            ollamaFallbackModels: []
        )

        let entries = result["openai-compatibility"] as? [[String: Any]] ?? []
        let ollamaEntry = entries.first { ($0["name"] as? String) == "ollama" }
        XCTAssertNil(ollamaEntry, "Should not emit an ollama entry when no models are configured")
    }
}

// MARK: - ProviderCatalog Ollama constants

final class ProviderCatalogOllamaTests: XCTestCase {

    func testOllamaProviderKey() {
        XCTAssertEqual(ProviderCatalog.ollamaProviderKey, "ollama")
    }

    func testOllamaDefaultBaseURL() {
        XCTAssertEqual(ProviderCatalog.ollamaDefaultBaseURL, "http://localhost:11434/v1")
    }

    func testOllamaHealthCheckURL() {
        XCTAssertEqual(ProviderCatalog.ollamaHealthCheckURL, "http://localhost:11434/api/tags")
    }
}
