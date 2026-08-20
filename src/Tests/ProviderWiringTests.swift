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
}
