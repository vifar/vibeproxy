# Proxy Provider Catalog Sync Design

## Goal

Keep VibeProxy's CLIProxyAPI model lists synchronized automatically for both proxy providers published at `https://models.opencode.ai/api.json`:

- `ollama-cloud` for Ollama Cloud;
- `opencode-go` for OpenCode Go.

Preserve offline startup, existing credentials, explicit user overrides, and provider-local configuration.

## Validated external contract

As observed on 2026-08-17, `GET https://models.opencode.ai/api.json` returned HTTP 200 with:

| Provider ID | Name | API URL | Models | Credential environment name |
| --- | --- | --- | ---: | --- |
| `ollama-cloud` | Ollama Cloud | `https://ollama.com/v1` | 20 | `OLLAMA_API_KEY` |
| `opencode-go` | OpenCode Go | `https://opencode.ai/zen/go/v1` | 25 | `OPENCODE_API_KEY` |

Both entries include exact model IDs plus context/output limits, tool support, reasoning support, and modalities.

VibeProxy uses this public catalog strictly as model data for its own proxy configuration. It does not configure or modify the OpenCode client. OpenCode Zen (`opencode`) is not included in this feature.

## Architecture

Replace the provider-specific `OllamaCloudCatalog` concept with a reusable proxy-provider catalog component responsible for:

1. decoding and validating the exact `ollama-cloud` and `opencode-go` entries;
2. validating each provider's expected ID and upstream API URL;
3. loading and atomically saving last-known-good provider data under the standard macOS caches directory;
4. returning cached models synchronously for startup;
5. refreshing the remote catalog asynchronously with a bounded timeout;
6. refusing to replace valid cached data with missing, empty, malformed, or mismatched provider data.

`ServerManager` owns the component. Startup config resolution remains network-independent: each provider uses cached models when available and otherwise its bundled static list. After startup, a background refresh requests config regeneration only when either effective model-ID set changes.

`ConfigComposer` receives resolved model rows keyed by provider ID. For each provider with valid non-empty catalog data, it replaces only that provider's bundled `models` array with rows where `name == alias == exact catalog model ID`. Existing provider entries continue to supply base URL, UI metadata, credentials, and offline fallback.

## Precedence

Apply precedence independently for `ollama-cloud` and `opencode-go`:

1. explicit user-authored `<provider>.models` in `~/.cli-proxy-api/config.yaml`;
2. fresh validated catalog data;
3. validated last-known-good cache;
4. bundled static models.

One provider's override, cache failure, enablement, or model changes must not affect the other provider.

## Cache

Use the standard user caches directory with an application-specific `VibeProxy/proxy-provider-catalog.json` path. The cache stores the validated provider payloads and fetch timestamp. Writes use atomic replacement.

The cache must not live under `~/.cli-proxy-api`; that directory is monitored as authentication/configuration input and cache writes would cause unnecessary refresh churn.

## Refresh behavior

- Load valid cached provider entries during `ServerManager` initialization.
- Start the proxy immediately using cache or bundled fallback for each provider.
- Refresh once in the background after initialization.
- Use a bounded request timeout.
- Refresh periodically while the app runs.
- Validate provider ID, expected upstream API URL, non-empty model set, and exact model-key/model-ID equality independently.
- Request runtime config regeneration only when at least one effective model-ID set changes.
- A failure for one provider retains that provider's previous cache/fallback without discarding a valid update for the other provider.

## OpenCode boundary and non-goals

The OpenCode client itself is outside this feature's runtime and configuration scope. VibeProxy does not:

- read or write OpenCode client configuration;
- change an OpenCode client provider or base URL;
- route OpenCode client traffic through VibeProxy merely because the catalog host is `models.opencode.ai`;
- write OpenCode's private model cache;
- require the OpenCode client to be installed or running;
- require or start a local Ollama process.

The catalog host is only the source for VibeProxy's provider model data.

VibeProxy's managed upstreams are:

```text
ollama-cloud -> https://ollama.com/v1
opencode-go  -> https://opencode.ai/zen/go/v1
```

Each credential remains owned by VibeProxy's provider credential path.

## Files

- Replace `src/Sources/OllamaCloudCatalog.swift` with a reusable proxy-provider catalog implementation.
- Modify `src/Sources/ProviderCatalog.swift` to define shared `ollama-cloud` and `opencode-go` IDs and expected upstream URLs.
- Modify `src/Sources/Resources/config.yaml` to include bundled offline fallback entries for both providers.
- Modify `src/Sources/ConfigComposer.swift` to accept catalog model rows keyed by provider ID and preserve provider-specific user overrides.
- Modify `src/Sources/ServerManager.swift` to load the shared cache, refresh both entries asynchronously, and regenerate config on effective changes.
- Extend focused standalone verification for parsing, caching, composition, credentials, and provider independence.

## Verification

1. A catalog fixture decodes both provider entries with exact IDs and metadata.
2. Expected upstream URLs are enforced independently.
3. Missing, empty, malformed, or mismatched data for one provider does not invalidate the other valid provider.
4. Valid cache entries load; invalid entries retain provider-specific fallback data.
5. Runtime composition replaces each bundled provider's models with its exact catalog IDs.
6. Explicit user models remain authoritative independently for each provider.
7. Both providers remain visible through VibeProxy's credential UI and injection path.
8. No source file reads or writes OpenCode client configuration.
9. No local Ollama server is required or contacted.
10. Provider-local model changes do not alter the other provider.
11. Standalone verification passes.
12. Swift package builds.
13. A live smoke check confirms `ollama-cloud` and `opencode-go` and their generated rows match current exact catalog IDs.
