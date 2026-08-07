# DeepSeek V4 Flash Stable Default Design

## Goal

Keep VibeProxy's Ollama Cloud model identifier stable while Ollama rolls `DeepSeek-V4-Flash-0731` out behind the `deepseek-v4-flash` default.

## Current State

The bundled source configuration already contains one Ollama Cloud mapping with the same unversioned identifier on both sides:

```yaml
- alias: deepseek-v4-flash
  name: deepseek-v4-flash
```

Tracked source contains no `071`, `0731`, `OC`, or OpenCloud-specific DeepSeek V4 Flash alias. Ollama's model page identifies `deepseek-v4-flash:0731-cloud` as the current cloud rollout behind the stable model.

## Decision

Retain the unversioned alias and upstream name. Do not pin `0731-cloud`, add a versioned public alias, or introduce legacy alias rewrites.

This keeps coding-harness configuration stable, delegates default-version rollout to Ollama Cloud, and avoids carrying obsolete provider-specific suffixes after the model identifiers have converged.

## Changes

1. Keep the existing `deepseek-v4-flash` mapping in `src/Sources/Resources/config.yaml` unchanged.
2. Add focused regression coverage in `src/Tests/ProviderWiringTests.swift` that parses the bundled YAML and establishes:
   - the Ollama Cloud provider exists;
   - it contains exactly one DeepSeek V4 Flash model entry;
   - that entry has `alias == deepseek-v4-flash`;
   - that entry has `name == deepseek-v4-flash`.
3. Do not change `ModelAliasMapper`; this is provider configuration, not request-time compatibility rewriting.
4. Do not edit generated `VibeProxy.app` contents. Release packaging will copy the source resource through the existing build process.

## Error Handling

The regression test will fail with explicit assertions if the provider or model list is missing or malformed. Production behavior remains unchanged because no runtime parsing or fallback logic is added.

## Verification

1. Before production changes, add the regression test and confirm it fails for the intended reason by temporarily expressing the new exact contract against a fixture/config state that does not satisfy it.
2. Restore the approved stable mapping and run the focused provider wiring test.
3. Run the full Swift package test suite to detect configuration or packaging regressions.

## Non-Goals

- Pinning VibeProxy to `deepseek-v4-flash:0731-cloud`.
- Advertising performance, privacy, plan limits, or rollout copy in the app UI.
- Supporting obsolete `071` or `OC` aliases through compatibility shims.
- Rebuilding or releasing the application bundle.
