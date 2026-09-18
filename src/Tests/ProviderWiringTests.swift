import XCTest
import Yams
@testable import CLIProxyMenuBar

final class ProviderWiringTests: XCTestCase {
    func testConnectionActionMatchesExistingProviderFlows() {
        XCTAssertEqual(ServiceType.claude.connectionAction, .authCommand(.claudeLogin))
        XCTAssertEqual(ServiceType.codex.connectionAction, .authCommand(.codexLogin))
        XCTAssertEqual(ServiceType.copilot.connectionAction, .authCommand(.copilotLogin))
        XCTAssertEqual(ServiceType.gemini.connectionAction, .authCommand(.geminiLogin))
        XCTAssertEqual(ServiceType.kimi.connectionAction, .authCommand(.kimiLogin))
        XCTAssertEqual(ServiceType.qwen.connectionAction, .promptForQwenEmail)
        XCTAssertEqual(ServiceType.antigravity.connectionAction, .authCommand(.antigravityLogin))
        XCTAssertEqual(ServiceType.zai.connectionAction, .promptForZAIAPIKey)
        XCTAssertEqual(ServiceType.xai.connectionAction, .authCommand(.xaiLogin))
        XCTAssertEqual(ServiceType.ollama.connectionAction, .promptForOllamaAPIKey)
        XCTAssertEqual(ServiceType.openrouter.connectionAction, .promptForOpenRouterAPIKey)
        XCTAssertEqual(ServiceType.vercel.connectionAction, .promptForVercelAPIKey)
    }

    func testBundledConfigDeclaresProviderSkeletonsWithoutStaticModelLists() throws {
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Resources/config.yaml")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let loadedYAML = try XCTUnwrap(try Yams.load(yaml: config))
        let root = try XCTUnwrap(ConfigComposer.stringKeyedDictionary(loadedYAML))
        let providers = ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"])

        let ollamaCloud = providers.first { ($0["name"] as? String) == "ollama-cloud" }
        XCTAssertNotNil(ollamaCloud, "ollama-cloud skeleton must remain in bundled config")
        XCTAssertEqual(ollamaCloud?["base-url"] as? String, "https://ollama.com/v1")
        XCTAssertNil(ollamaCloud?["models"], "bundled config must not carry a static ollama-cloud model list")

        let opencodeGo = providers.first { ($0["name"] as? String) == "opencode-go" }
        XCTAssertNotNil(opencodeGo, "opencode-go skeleton must remain in bundled config")
        XCTAssertEqual(opencodeGo?["base-url"] as? String, "https://opencode.ai/zen/go/v1")
        XCTAssertNil(opencodeGo?["models"], "bundled config must not carry a static opencode-go model list")
    }

    func testBundledConfigSkeletonStillReceivesCatalogModelsAtRuntime() throws {
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Resources/config.yaml")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let loadedYAML = try XCTUnwrap(try Yams.load(yaml: config))
        let root = try XCTUnwrap(ConfigComposer.stringKeyedDictionary(loadedYAML))

        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: root,
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [],
            includeManagedZAIProvider: false,
            catalogModelRowsByProviderID: [
                "opencode-go": [
                    ["name": "muse-spark-1.2-contributor", "alias": "muse-spark-1.2-contributor"],
                    ["name": "deepseek-v4-flash", "alias": "deepseek-v4-flash"]
                ]
            ]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        let opencodeGo = try XCTUnwrap(providers.first { ($0["name"] as? String) == "opencode-go" })
        let modelAliases = ConfigComposer.stringKeyedDictionaryArray(opencodeGo["models"])
            .compactMap { ($0["alias"] as? String) ?? ($0["name"] as? String) }
        XCTAssertEqual(modelAliases, ["deepseek-v4-flash", "muse-spark-1.2-contributor"])
    }

    func testKimiProviderCatalogRegistrationMatchesRuntimeProviderKey() {
        XCTAssertEqual(ProviderCatalog.oauthProviderKeys["kimi"], "kimi")
        XCTAssertTrue(ProviderCatalog.reservedCustomProviderKeys.contains("kimi"))
    }

    func testXaiProviderRegistrationAndPoolMapping() {
        XCTAssertEqual(ProviderCatalog.oauthProviderKeys["xai"], "xai")
        XCTAssertTrue(ProviderCatalog.reservedCustomProviderKeys.contains("xai"))
        XCTAssertEqual(ProxyProviderCatalog.uiProviderPoolCatalogIDs["xai"], "xai")
    }

    func testOpenRouterUsesCatalogModelsWhenNoUserModelsDeclared() {
        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: [:],
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [
                ConfigProviderAuthRecord(providerID: "openrouter", apiKey: "or-key", isDisabled: false)
            ],
            includeManagedZAIProvider: false,
            catalogModelRowsByProviderID: [
                "openrouter": [
                    ["name": "anthropic/claude-sonnet-4.5", "alias": "claude-sonnet-4-5-20250929"],
                    ["name": "openai/gpt-5.6-luna", "alias": "gpt-5.6-luna"]
                ]
            ]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        let openrouter = try! XCTUnwrap(providers.first { ($0["name"] as? String) == "openrouter" })
        let aliases = ConfigComposer.stringKeyedDictionaryArray(openrouter["models"])
            .compactMap { ($0["alias"] as? String) ?? ($0["name"] as? String) }
        XCTAssertEqual(aliases, ["claude-sonnet-4-5-20250929", "gpt-5.6-luna"])
    }

    func testOllamaEntrySkippedWithoutModelsOrKeys() {
        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: [:],
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [],
            includeManagedZAIProvider: false,
            catalogModelRowsByProviderID: [:]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        XCTAssertNil(
            providers.first { ($0["name"] as? String) == "ollama" },
            "ollama must not be synthesized from a static list when the local tag endpoint is unreachable"
        )
    }

    func testZaiUsesCatalogModelsWhenNoUserModelsDeclared() {
        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: [:],
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: ["zai-key"],
            customProviderAuthRecords: [],
            includeManagedZAIProvider: true,
            catalogModelRowsByProviderID: [
                "zai": [
                    ["name": "glm-5.3", "alias": "glm-5.3"],
                    ["name": "glm-4.7", "alias": "glm-4.7"]
                ]
            ]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        let zai = try! XCTUnwrap(providers.first { ($0["name"] as? String) == "zai" })
        let aliases = ConfigComposer.stringKeyedDictionaryArray(zai["models"])
            .compactMap { ($0["alias"] as? String) ?? ($0["name"] as? String) }
        XCTAssertEqual(aliases, ["glm-4.7", "glm-5.3"])
    }

    func testZaiUserModelsWinOverCatalog() {
        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: [
                "openai-compatibility": [[
                    "name": "zai",
                    "base-url": "https://api.z.ai/api/coding/paas/v4",
                    "models": [["name": "glm-4.7", "alias": "glm-4.7"]]
                ]]
            ],
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: ["zai-key"],
            customProviderAuthRecords: [],
            includeManagedZAIProvider: true,
            catalogModelRowsByProviderID: [
                "zai": [["name": "glm-5.3", "alias": "glm-5.3"]]
            ],
            userOverrideProviderIDs: ["zai"]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        let zai = try! XCTUnwrap(providers.first { ($0["name"] as? String) == "zai" })
        let aliases = ConfigComposer.stringKeyedDictionaryArray(zai["models"])
            .compactMap { ($0["alias"] as? String) ?? ($0["name"] as? String) }
        XCTAssertEqual(aliases, ["glm-4.7"], "user-authored zai models must beat catalog rows")
    }

    func testVercelUsesCatalogModelsWhenNoUserModelsDeclared() {
        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: [:],
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [
                ConfigProviderAuthRecord(providerID: "vercel", apiKey: "vck_test", isDisabled: false)
            ],
            includeManagedZAIProvider: false,
            catalogModelRowsByProviderID: [
                "vercel": [
                    ["name": "anthropic/claude-sonnet-4.5", "alias": "anthropic/claude-sonnet-4.5"],
                    ["name": "openai/gpt-5.6-luna", "alias": "openai/gpt-5.6-luna"]
                ]
            ]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        let vercel = try! XCTUnwrap(providers.first { ($0["name"] as? String) == "vercel" })
        XCTAssertEqual(vercel["base-url"] as? String, ProxyProviderCatalog.vercelAPIURL)
        let aliases = ConfigComposer.stringKeyedDictionaryArray(vercel["models"])
            .compactMap { ($0["alias"] as? String) ?? ($0["name"] as? String) }
        XCTAssertEqual(aliases, ["anthropic/claude-sonnet-4.5", "openai/gpt-5.6-luna"])
        let apiKeys = ConfigComposer.stringKeyedDictionaryArray(vercel["api-key-entries"])
            .compactMap { $0["api-key"] as? String }
        XCTAssertEqual(apiKeys, ["vck_test"])
    }

    func testVercelSkippedWhenDisabledWithoutKeysOrModels() {
        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: [:],
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [],
            includeManagedZAIProvider: false,
            enabledProviders: ["vercel": false],
            catalogModelRowsByProviderID: [
                "vercel": [["name": "openai/gpt-5.6-luna", "alias": "openai/gpt-5.6-luna"]]
            ]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        XCTAssertNil(providers.first { ($0["name"] as? String) == "vercel" })
    }

    func testVercelReservedAndDisplayName() {
        XCTAssertTrue(ProviderCatalog.reservedCustomProviderKeys.contains("vercel"))
        XCTAssertTrue(ProviderCatalog.managedOpenAICompatibilityProviderIDs.contains("vercel"))
        XCTAssertEqual(ServiceType.vercel.displayName, "Vercel")
        XCTAssertEqual(ServiceType.vercel.rawValue, "vercel")
    }

    func testManagedOpenAICompatProvidersAreAllowedUnderOpenaiCompatibility() {
        for providerID in ["zai", "ollama", "openrouter", "vercel"] {
            let errors = ConfigComposer.validateCustomProviders(
                in: [
                    "openai-compatibility": [[
                        "name": providerID,
                        "models": [["name": "some-model", "alias": "some-model"]]
                    ]]
                ],
                reservedProviderIDs: ProviderCatalog.reservedCustomProviderKeys
            )
            XCTAssertEqual(
                errors,
                [],
                "\(providerID) is a managed openai-compat provider and must be allowed without a base-url"
            )
        }

        let oauthErrors = ConfigComposer.validateCustomProviders(
            in: [
                "openai-compatibility": [[
                    "name": "xai",
                    "models": [["name": "grok-4.6", "alias": "grok-4.6"]]
                ]]
            ],
            reservedProviderIDs: ProviderCatalog.reservedCustomProviderKeys
        )
        XCTAssertEqual(
            oauthErrors,
            ["Provider 'xai' is reserved and cannot be declared under openai-compatibility."]
        )
    }

    func testVercelUserModelSelectionComposesSingleManagedEntry() {
        let runtime = ConfigComposer.composeRuntimeConfig(
            baseRoot: [
                "openai-compatibility": [[
                    "name": "vercel",
                    "models": [["name": "openai/gpt-5.6-luna", "alias": "openai/gpt-5.6-luna"]]
                ]]
            ],
            reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [],
            zaiAPIKeys: [],
            customProviderAuthRecords: [
                ConfigProviderAuthRecord(providerID: "vercel", apiKey: "vck_test", isDisabled: false)
            ],
            includeManagedZAIProvider: false,
            enabledProviders: ["vercel": true],
            catalogModelRowsByProviderID: [
                "vercel": [
                    ["name": "anthropic/claude-sonnet-4.5", "alias": "anthropic/claude-sonnet-4.5"],
                    ["name": "openai/gpt-5.6-luna", "alias": "openai/gpt-5.6-luna"]
                ]
            ],
            userOverrideProviderIDs: ["vercel"]
        )

        let providers = ConfigComposer.stringKeyedDictionaryArray(runtime["openai-compatibility"])
        let vercelEntries = providers.filter { ($0["name"] as? String) == "vercel" }
        XCTAssertEqual(vercelEntries.count, 1, "user-authored vercel must not be copied alongside the managed entry")
        let vercel = try! XCTUnwrap(vercelEntries.first)
        XCTAssertEqual(vercel["base-url"] as? String, ProxyProviderCatalog.vercelAPIURL)
        let aliases = ConfigComposer.stringKeyedDictionaryArray(vercel["models"])
            .compactMap { ($0["alias"] as? String) ?? ($0["name"] as? String) }
        XCTAssertEqual(aliases, ["openai/gpt-5.6-luna"], "user-selected vercel models must beat catalog rows")
    }

    func testDecodeVercelKeepsAllTypesAndRecordsType() throws {
        let fixture = """
        {
          "object": "list",
          "data": [
            {
              "id": "anthropic/claude-sonnet-4.5",
              "object": "model",
              "name": "Claude Sonnet 4.5",
              "type": "language",
              "context_window": 200000,
              "max_tokens": 64000,
              "tags": ["reasoning", "tool-use"],
              "modalities": {"input": ["text", "image"], "output": ["text"]}
            },
            {
              "id": "openai/gpt-embed",
              "object": "model",
              "name": "Embeddings",
              "type": "embedding",
              "context_window": 8192,
              "max_tokens": 8192,
              "tags": []
            },
            {
              "id": "bfl/flux-2-pro",
              "object": "model",
              "name": "Flux",
              "type": "image",
              "context_window": 4096,
              "max_tokens": 4096
            },
            {
              "id": "acme/plain-chat",
              "object": "model",
              "name": "Plain Chat",
              "type": "language",
              "context_window": 32000,
              "max_tokens": 4096
            },
            {
              "id": "typesafe-ai/jev",
              "object": "model",
              "name": "JEV",
              "type": "evaluation",
              "context_window": 8192,
              "max_tokens": 4096
            }
          ]
        }
        """
        let data = try XCTUnwrap(fixture.data(using: .utf8))
        let entry = try XCTUnwrap(ProxyProviderCatalog.decodeVercel(from: data))
        XCTAssertEqual(entry.id, "vercel")
        XCTAssertEqual(entry.api, ProxyProviderCatalog.vercelAPIURL)
        XCTAssertEqual(
            entry.models.map(\.id),
            [
                "acme/plain-chat",
                "anthropic/claude-sonnet-4.5",
                "bfl/flux-2-pro",
                "openai/gpt-embed",
                "typesafe-ai/jev"
            ]
        )

        let claude = try XCTUnwrap(entry.models.first { $0.id == "anthropic/claude-sonnet-4.5" })
        XCTAssertEqual(claude.type, "language")
        XCTAssertTrue(claude.reasoning)
        XCTAssertTrue(claude.toolCall)
        XCTAssertEqual(claude.limit.context, 200_000)
        XCTAssertEqual(claude.limit.output, 64_000)
        XCTAssertEqual(claude.modalities?.input, ["text", "image"])
        XCTAssertEqual(claude.modalities?.output, ["text"])

        let plain = try XCTUnwrap(entry.models.first { $0.id == "acme/plain-chat" })
        XCTAssertEqual(plain.type, "language")
        XCTAssertFalse(plain.reasoning)
        XCTAssertTrue(plain.toolCall, "missing tags should default toolCall to true")

        let embed = try XCTUnwrap(entry.models.first { $0.id == "openai/gpt-embed" })
        XCTAssertEqual(embed.type, "embedding")

        let flux = try XCTUnwrap(entry.models.first { $0.id == "bfl/flux-2-pro" })
        XCTAssertEqual(flux.type, "image")

        let jev = try XCTUnwrap(entry.models.first { $0.id == "typesafe-ai/jev" })
        XCTAssertEqual(jev.type, "evaluation")
    }

    func testModelRowsFiltersByAllowedTypes() throws {
        let fixture = """
        {
          "object": "list",
          "data": [
            {
              "id": "anthropic/claude-sonnet-4.5",
              "object": "model",
              "name": "Claude Sonnet 4.5",
              "type": "language",
              "context_window": 200000,
              "max_tokens": 64000
            },
            {
              "id": "openai/gpt-embed",
              "object": "model",
              "name": "Embeddings",
              "type": "embedding",
              "context_window": 8192,
              "max_tokens": 8192
            },
            {
              "id": "bfl/flux-2-pro",
              "object": "model",
              "name": "Flux",
              "type": "image",
              "context_window": 4096,
              "max_tokens": 4096
            },
            {
              "id": "acme/plain-chat",
              "object": "model",
              "name": "Plain Chat",
              "type": "language",
              "context_window": 32000,
              "max_tokens": 4096
            },
            {
              "id": "typesafe-ai/jev",
              "object": "model",
              "name": "JEV",
              "type": "evaluation",
              "context_window": 8192,
              "max_tokens": 4096
            }
          ]
        }
        """
        let data = try XCTUnwrap(fixture.data(using: .utf8))
        let entry = try XCTUnwrap(ProxyProviderCatalog.decodeVercel(from: data))

        let filtered = ProxyProviderCatalog.modelRows(
            from: entry,
            allowedTypes: ["evaluation", "language"]
        )
        XCTAssertEqual(
            filtered.map { $0["name"] },
            ["acme/plain-chat", "anthropic/claude-sonnet-4.5", "typesafe-ai/jev"]
        )

        let allRows = ProxyProviderCatalog.modelRows(from: entry)
        XCTAssertEqual(allRows.count, entry.models.count)

        let languageOnly = ProxyProviderCatalog.modelRows(
            from: entry,
            allowedTypes: ["language"]
        )
        XCTAssertEqual(
            languageOnly.map { $0["name"] },
            ["acme/plain-chat", "anthropic/claude-sonnet-4.5"]
        )
    }
}
