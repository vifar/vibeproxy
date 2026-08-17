# Proxy Provider Catalog Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synchronize VibeProxy's managed `ollama-cloud` and `opencode-go` routes with exact model IDs from the live `https://models.opencode.ai/api.json` catalog without blocking startup or losing offline fallback.

**Architecture:** A reusable `ProxyProviderCatalog` decodes, validates, caches, and refreshes both managed provider entries independently. `ServerManager` uses cached data synchronously and refreshes in the background; `ConfigComposer` replaces bundled model rows per provider unless the user explicitly overrides that provider's models.

**Tech Stack:** Swift 5.9, Foundation `URLSession`, Codable, Yams, standalone Swift verification.

---

### Task 1: Catalog parsing and validation

**Files:**
- Create: `src/Sources/ProxyProviderCatalog.swift`
- Create: `src/Verification/ProxyProviderCatalogSpec.swift`

- [ ] Write failing fixture checks for exact provider IDs, upstream API URLs, model IDs, limits, capabilities, missing provider, and empty models.
- [ ] Compile and run the verification executable; confirm failure because the catalog types do not exist.
- [ ] Implement immutable Codable catalog/provider/model types and per-provider validation returning normalized, sorted model lists.
- [ ] Re-run the verification executable and confirm all parsing checks pass.

### Task 2: Cache and fallback behavior

**Files:**
- Modify: `src/Sources/ProxyProviderCatalog.swift`
- Modify: `src/Verification/ProxyProviderCatalogSpec.swift`

- [ ] Add failing checks for valid cache loading, malformed-cache rejection, atomic save/reload, unchanged-model comparison, and per-provider independence.
- [ ] Run the focused executable and confirm the new checks fail.
- [ ] Implement cache envelope persistence with fetch timestamp and atomic writes.
- [ ] Re-run the executable and confirm all cache checks pass.

### Task 3: Managed provider ownership and config composition

**Files:**
- Modify: `src/Sources/ProviderCatalog.swift`
- Modify: `src/Sources/ConfigComposer.swift`
- Modify: `src/Verification/ConfigComposerSpec.swift`

- [ ] Add failing checks that catalog rows replace bundled rows per provider, catalog data applies only when a provider entry exists, and explicit user model rows remain authoritative independently per provider.
- [ ] Run `ConfigComposerSpec` and confirm the new checks fail.
- [ ] Add shared managed provider definitions and a provider-keyed catalog-model input to runtime composition without reserving providers away from the existing credential UI.
- [ ] Re-run `ConfigComposerSpec` and confirm all checks pass.

### Task 4: Background refresh integration

**Files:**
- Modify: `src/Sources/ProxyProviderCatalog.swift`
- Modify: `src/Sources/ServerManager.swift`

- [ ] Add focused catalog checks for remote response validation and changed-set detection using injected data/transport boundaries.
- [ ] Run them and confirm failure.
- [ ] Add bounded asynchronous refresh, per-provider cache update, startup cache loading, periodic refresh, and config regeneration only when any model-ID set changes.
- [ ] Keep synchronous config resolution network-free and use bundled fallback when cache is unavailable.
- [ ] Re-run focused verification.

### Task 5: Bundled fallback and end-to-end verification

**Files:**
- Modify: `src/Sources/Resources/config.yaml`
- Verify: all modified Swift sources and verification files

- [ ] Add a bundled `opencode-go` offline fallback entry with exact current catalog model IDs; keep the existing `ollama-cloud` fallback.
- [ ] Compile and run `ProxyProviderCatalogSpec`.
- [ ] Compile and run `ConfigComposerSpec`.
- [ ] Run `swift build` from `src`.
- [ ] Validate the bundled YAML parses with both provider entries.
- [ ] Fetch the live catalog and confirm `ollama-cloud` and `opencode-go` exact model IDs equal the normalized IDs accepted by the parser.
- [ ] Confirm the bundled static lists remain present as offline fallback and no local Ollama or OpenCode client behavior changed.
