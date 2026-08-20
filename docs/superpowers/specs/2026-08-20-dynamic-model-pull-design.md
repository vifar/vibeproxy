# Dynamic Model Pull — Design

Date: 2026-08-20
Status: Approved (user selected Option A)

## Problem

Model lists are hardcoded in five surfaces:

1. `~/.config/opencode/opencode.json` — static `provider.vibeproxy.models` (18 entries). opencode never queries `/v1/models`; newly cataloged models (e.g. `muse-spark-1.2-contributor`) never appear.
2. `src/Sources/Resources/config.yaml:57-133` — 32 bundled static `alias/name` entries for ollama-cloud and opencode-go (offline fallback tier that drifts from the live catalog).
3. `ConfigComposer.swift` — `defaultZAIModels()` (464-471), `ollamaDefaultModels()` (490-500), `openRouterDefaultModels()` (503-514). zai/ollama/openrouter never pull model lists.
4. `ModelAliasMapper.swift:4-8` — `ghcp-* → claude-*` rewrite table in ThinkingProxy (static rewrite map, not a model list).
5. `ProviderCatalog.swift` / `ProxyProviderCatalog.swift:45-49` — static provider taxonomy and provider→URL map (provider set; acceptable config, not a model list).

## Goal

Nothing static on pull. Model lists are always pulled from upstream sources. The ONLY static input is the user's own model selection (which providers/models to enable) plus their API keys and auth.

## Design

### Architecture

```
Upstream sources
  ├─ models.opencode.ai/api.json  → ollama-cloud, opencode-go (existing, hourly)
  ├─ openrouter.ai/api/v1/models  → openrouter provider (new)
  ├─ ollama local /api/tags       → ollama provider (new, base URL from config)
  └─ z.ai model API               → zai provider (new; probe endpoint, fall back to documented list)
        │
        ▼
ProxyProviderCatalogClient.refresh()  →  per-provider adapter → ProxyProviderEntry
        │
        ▼
~/Library/Caches/VibeProxy/proxy-provider-catalog.json   (last-known-good cache)
        │
        ▼
ConfigComposer (catalog rows keyed by provider id; user-override models win)
        │
        ▼
~/.cli-proxy-api/merged-config.yaml  →  cli-proxy-api-plus on :8318  →  /v1/models
        │
        ▼
OpenCodeConfigSync  →  ~/.config/opencode/opencode.json `provider.vibeproxy.models`
        (preserves all other keys; writes only the model set; atomic replace; only when set changes)
```

### Phase 1 — opencode sync (fixes muse immediately)

- New `src/Sources/OpenCodeConfigSync.swift`.
- Inputs: effective model pool = merged catalog models ∪ user-override models (alias→name/display).
- Reads existing `~/.config/opencode/opencode.json`; errors or missing `provider.vibeproxy` → log and skip (never invent config).
- Rewrites only `provider.vibeproxy.models`: keys = model ids, values = `{ "name": displayName }` preserving existing custom names when the id is unchanged.
- Atomic write (temp file + rename), preserve file permissions.
- Triggered after every catalog refresh that changes the model set and after every config regeneration (provider toggle / user model selection change).

### Phase 2 — strip static lists, extend pull

- Remove model lists from bundled `config.yaml`; keep provider skeletons (name, display-name, help-text, base-url).
- Remove/replace `defaultZAIModels()`, `ollamaDefaultModels()`, `openRouterDefaultModels()` with dynamic merge from catalog providers; add per-provider adapters for openrouter, ollama (local tags), zai.
- Validation: `validateCustomProviders` accepts catalog-backed providers without explicit models; `userOverrideProviderIDs` remains the sole static model source.
- Update verification specs/tests to the new contract (provider skeletons in bundle; dynamic injection in composition).

### Phase 3 — user model selection

- Settings UI: per managed provider, checkbox list of pulled models; selection persisted in `~/.cli-proxy-api/config.yaml` as `<provider>.models` (existing user-override mechanism).
- Selection drives both merged-config.yaml and the opencode.json sync. This selection is the ONLY static model input.

## Error handling

- Catalog fetch failure → serve last-known-good cache; if none, provider keeps no models (logged) rather than stale hardcoded list.
- Malformed upstream payload → fail that provider only; other providers unaffected.
- opencode.json unreadable/invalid JSON → back up to `opencode.json.bak.<ts>` and rewrite; log.

## Out of scope

- ModelAliasMapper rewrite table (proxy-internal rewrite, not a model list).
- FACTORY_SETUP.md sample config (user-owned surface, documents `~/.factory/config.json`).
- README marketing claims.

## Verification

- `muse-spark-1.2-contributor` (or any newly cataloged model) appears in `~/.config/opencode/opencode.json` after catalog refresh, without manual edit.
- `swift build` + verification suites pass.
- Proxy `/v1/models` still serves full effective list after stripping bundled lists.