# DeepSeek V4 Flash Stable Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock VibeProxy's Ollama Cloud DeepSeek V4 Flash mapping to the stable unversioned `deepseek-v4-flash` identifier without adding versioned or provider-specific aliases.

**Architecture:** The bundled YAML remains the runtime source of truth and requires no production edit because it already has the approved mapping. A Swift/XCTest regression test will parse that YAML with Yams, locate the Ollama Cloud provider, identify every DeepSeek V4 Flash entry by semantic name fragments, and require exactly one entry whose alias and upstream name are both the stable identifier.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, Yams, YAML configuration.

---

## File Structure

- Modify `src/Package.swift`: declare Yams as a direct test-target dependency so the test owns every module it imports.
- Modify `src/Tests/ProviderWiringTests.swift`: add the exact bundled-config regression test.
- Keep `src/Sources/Resources/config.yaml` unchanged: it already contains the desired production mapping.

### Task 1: Lock the Stable Ollama Cloud Mapping

**Files:**
- Modify: `src/Package.swift:28-32`
- Modify: `src/Tests/ProviderWiringTests.swift:16-23`
- Verify unchanged: `src/Sources/Resources/config.yaml:49-63`

Because the approved production state already exists, this task adds characterization/regression coverage rather than new runtime behavior. No production implementation step is required after the test is added.

- [ ] **Step 1: Give the test target a direct Yams dependency**

Replace the test target dependency list in `src/Package.swift` with:

```swift
.testTarget(
    name: "CLIProxyMenuBarTests",
    dependencies: ["CLIProxyMenuBar", "Yams"],
    path: "Tests"
)
```

- [ ] **Step 2: Add the bundled-config regression test**

Add `import Yams` after `import XCTest` in `src/Tests/ProviderWiringTests.swift`, then add this test after `testBundledConfigAdvertisesKimiK3ThroughOllamaCloud()`:

```swift
func testBundledConfigUsesStableDeepSeekV4FlashDefaultThroughOllamaCloud() throws {
    let configURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Sources/Resources/config.yaml")
    let config = try String(contentsOf: configURL, encoding: .utf8)
    let loadedYAML = try XCTUnwrap(try Yams.load(yaml: config))
    let root = try XCTUnwrap(ConfigComposer.stringKeyedDictionary(loadedYAML))
    let providers = ConfigComposer.stringKeyedDictionaryArray(root["openai-compatibility"])
    let ollamaCloudProviders = providers.filter {
        ($0["name"] as? String) == "ollama-cloud"
    }
    XCTAssertEqual(ollamaCloudProviders.count, 1)
    let ollamaCloud = try XCTUnwrap(ollamaCloudProviders.first)
    let models = ConfigComposer.stringKeyedDictionaryArray(ollamaCloud["models"])
    let deepSeekV4FlashModels = models.filter { model in
        let identifiers = [model["alias"], model["name"]]
            .compactMap { ($0 as? String)?.lowercased() }
        return identifiers.contains { identifier in
            identifier.contains("deepseek")
                && identifier.contains("v4")
                && identifier.contains("flash")
        }
    }

    XCTAssertEqual(deepSeekV4FlashModels.count, 1)
    XCTAssertEqual(deepSeekV4FlashModels.first?["alias"] as? String, "deepseek-v4-flash")
    XCTAssertEqual(deepSeekV4FlashModels.first?["name"] as? String, "deepseek-v4-flash")
}
```

The semantic filter makes the test fail if a legacy identifier such as a `071`, `0731`, `OC`, or OpenCloud-suffixed variant is added beside or instead of the stable mapping.

- [ ] **Step 3: Run the focused regression test**

Run:

```bash
cd src && swift test --filter ProviderWiringTests/testBundledConfigUsesStableDeepSeekV4FlashDefaultThroughOllamaCloud
```

Expected: PASS. This is a characterization test for an already-correct production mapping; a failure must identify either malformed YAML, a missing Ollama Cloud provider, duplicate DeepSeek V4 Flash entries, or a non-stable alias/name.

- [ ] **Step 4: Confirm the production mapping stayed minimal**

Read `src/Sources/Resources/config.yaml` and confirm the Ollama Cloud models still contain exactly:

```yaml
- alias: deepseek-v4-flash
  name: deepseek-v4-flash
```

Do not add `071`, `0731`, `OC`, `OpenCloud`, or compatibility aliases.

- [ ] **Step 5: Run the full package test suite**

Run:

```bash
cd src && swift test
```

Expected: all tests pass with no compiler errors or test failures.

- [ ] **Step 6: Commit the implementation**

```bash
git add docs/superpowers/plans/2026-08-07-deepseek-v4-flash-default.md src/Package.swift src/Tests/ProviderWiringTests.swift
git commit -m "test: lock DeepSeek V4 Flash stable default"
```
