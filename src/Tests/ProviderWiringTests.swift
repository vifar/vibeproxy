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
    }

    func testBundledConfigAdvertisesKimiK3ThroughOllamaCloud() throws {
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Resources/config.yaml")
        let config = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertTrue(config.contains("alias: kimi-k3\n    name: kimi-k3"))
    }

    func testBundledConfigUsesStableDeepSeekV4FlashDefaultThroughOllamaCloud() throws {
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Resources/config.yaml")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let loadedYAML = try XCTUnwrap(try Yams.load(yaml: config))
        let root = try XCTUnwrap(ConfigComposer.stringKeyedDictionary(loadedYAML))
        let providers = ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"])
        let ollamaCloud = try XCTUnwrap(
            providers.first { ($0["name"] as? String) == "ollama-cloud" }
        )
        let models = ConfigComposer.stringKeyedDictionaryArray(ollamaCloud["models"])
        let deepSeekV4FlashModels = models.filter { model in
            let identifiers = [model["alias"], model["name"]]
                .compactMap { ($0 as? String)?.lowercased() }
            return identifiers.contains { identifier in
                identifier.contains("deepseek-v4-flash")
            }
        }

        XCTAssertEqual(deepSeekV4FlashModels.count, 1)
        XCTAssertEqual(deepSeekV4FlashModels.first?["alias"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(deepSeekV4FlashModels.first?["name"] as? String, "deepseek-v4-flash")
    }

    func testKimiProviderCatalogRegistrationMatchesRuntimeProviderKey() {
        XCTAssertEqual(ProviderCatalog.oauthProviderKeys["kimi"], "kimi")
        XCTAssertTrue(ProviderCatalog.reservedCustomProviderKeys.contains("kimi"))
    }
}
