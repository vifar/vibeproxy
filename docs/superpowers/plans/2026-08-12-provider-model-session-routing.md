# Provider- and Model-Scoped Session Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make mixed-provider round robin select providers evenly per model, keep each session on its selected provider and credential, and ship that behavior as VibeProxy's default.

**Architecture:** Implement hierarchical mixed-route selection inside CLIProxyAPI: canonical provider-set/model round robin chooses a provider, then the existing provider/model shard chooses a credential. Reuse the existing session cache with a mixed-route key containing session, canonical model, and canonical provider set. VibeProxy only supplies and verifies the routing defaults, then bundles the released upstream binary.

**Tech Stack:** Go 1.x, CLIProxyAPI scheduler/auth manager, Swift 5.9, Yams, VibeProxy config composer, YAML, XCTest/standalone Swift verification.

---

## Repository and release sequence

This feature crosses two repositories and must land in this order:

1. `router-for-me/CLIProxyAPI` — scheduler semantics, affinity, observability, and Go tests.
2. `automazeio/vibeproxy` — bundled routing defaults, config verification, documentation, and the first CLIProxyAPI release containing the scheduler change.

Do not describe VibeProxy as provider-equal until the bundled binary contains the upstream implementation.

### Task 1: Establish the upstream CLIProxyAPI feature branch and baseline

**Files:**
- Inspect: `sdk/cliproxy/auth/scheduler.go`
- Inspect: `sdk/cliproxy/auth/selector.go`
- Inspect: `sdk/cliproxy/auth/conductor_selection.go`
- Inspect: `sdk/cliproxy/auth/conductor_execution.go`
- Inspect: `sdk/cliproxy/auth/scheduler_test.go`
- Inspect: `sdk/cliproxy/auth/session_affinity_priority_test.go`
- Inspect: `sdk/cliproxy/auth/conductor_execution_test.go`

- [ ] **Step 1: Create an isolated CLIProxyAPI worktree from the version currently bundled by VibeProxy**

Use the environment's managed worktree command. Register `router-for-me/CLIProxyAPI` as a project if it is not already registered, then create branch `feat/provider-model-session-routing` from the exact release tag reported by VibeProxy's bundled binary or changelog. Do not use a raw `git worktree add` inside a managed workspace.

Expected: a clean managed worktree on `feat/provider-model-session-routing` based on the bundled release tag, currently expected to be `v7.2.92`.

- [ ] **Step 2: Run the focused baseline test packages**

Run:

```bash
go test ./sdk/cliproxy/auth ./sdk/cliproxy
```

Expected: PASS. If the tag differs from the current VibeProxy binary version, use the exact version reported by the binary or changelog and record it in the PR.

- [ ] **Step 3: Confirm the current regression contract**

Run:

```bash
go test ./sdk/cliproxy/auth -run 'Test.*Mixed.*RoundRobin' -count=1 -v
```

Expected: the focused tests pass but do not establish equal provider distribution with unequal credential counts; the new regression test in Task 2 supplies that missing contract.

- [ ] **Step 4: Commit no code in this task**

Record the baseline output in the implementation handoff or issue. Do not commit generated artifacts.

### Task 2: Write failing provider-equality scheduler tests

**Files:**
- Modify: `sdk/cliproxy/auth/scheduler_test.go`

- [ ] **Step 1: Add a fixture with unequal credential counts**

Add helpers that register:

```go
providers := []string{"openai-compatible-ollama-cloud", "openai-compatible-opencode-go"}
model := "deepseek-v4-pro"

// Ollama Cloud: one eligible auth.
// OpenCode Go: three eligible auths.
```

Every auth must register support for `deepseek-v4-pro` in the global model registry and receive the same priority.

- [ ] **Step 2: Add the cold-provider distribution test**

Add:

```go
func TestAuthSchedulerPickMixedRoundRobinBalancesProvidersBeforeCredentials(t *testing.T) {
    scheduler, providers, model := newUnequalMixedProviderScheduler(t)

    gotProviders := make([]string, 0, 8)
    for i := 0; i < 8; i++ {
        _, provider, err := scheduler.pickMixed(
            context.Background(), providers, model,
            cliproxyexecutor.Options{}, nil,
        )
        if err != nil {
            t.Fatalf("pick %d: %v", i, err)
        }
        gotProviders = append(gotProviders, provider)
    }

    want := []string{
        providers[0], providers[1], providers[0], providers[1],
        providers[0], providers[1], providers[0], providers[1],
    }
    if !reflect.DeepEqual(gotProviders, want) {
        t.Fatalf("providers = %v, want %v", gotProviders, want)
    }
}
```

- [ ] **Step 3: Add independent provider/model credential cursor tests**

Add tests that call two models through the same two providers and assert:

```go
// Provider alternation for model A does not advance model B.
// Credential rotation inside OpenCode Go/model A does not advance
// Ollama Cloud/model A or OpenCode Go/model B.
```

Capture selected auth IDs and providers; assert both sequences explicitly.

- [ ] **Step 4: Add canonical provider-set ordering coverage**

Call `pickMixed` with provider orders `[A, B]` and `[B, A]`. Assert both calls use one canonical cursor scope rather than independent order-sensitive cursors.

- [ ] **Step 5: Run the new tests and confirm failure**

Run:

```bash
go test ./sdk/cliproxy/auth -run 'TestAuthSchedulerPickMixedRoundRobinBalancesProvidersBeforeCredentials|TestAuthSchedulerPickMixedRoundRobinScopesCursors|TestAuthSchedulerPickMixedRoundRobinCanonicalizesProviderSet' -count=1 -v
```

Expected: FAIL because current mixed round robin weights providers by ready credential count and keys state by input provider order.

- [ ] **Step 6: Commit the failing tests**

```bash
git add sdk/cliproxy/auth/scheduler_test.go
git commit -m "test: define provider-first mixed round robin"
```

### Task 3: Implement provider-first mixed round robin

**Files:**
- Modify: `sdk/cliproxy/auth/scheduler.go`

- [ ] **Step 1: Add canonical provider-set normalization**

Add a helper next to `normalizeProviderKeys`:

```go
func canonicalProviderKeys(providers []string) []string {
    canonical := normalizeProviderKeys(providers)
    sort.Strings(canonical)
    return canonical
}
```

Use canonical keys for mixed cursor state and deterministic provider rotation.

- [ ] **Step 2: Add a provider-level ready candidate structure**

Add:

```go
type mixedProviderCandidate struct {
    providerKey string
    shard       *modelScheduler
    priority    int
}
```

Build one candidate per eligible provider/model shard. A provider's priority is its highest ready priority after request predicates are applied.

- [ ] **Step 3: Filter to the winning priority tier before rotation**

Replace credential-count `weights`, `segmentStarts`, and `segmentEnds` construction with:

```go
candidates := collectMixedProviderCandidates(...)
winning := candidatesAtHighestPriority(candidates)
```

Only providers in `winning` participate in equal round robin. Lower tiers remain excluded until the higher tier is unavailable, matching existing priority semantics.

- [ ] **Step 4: Advance one provider slot, then one credential slot**

Use:

```go
cursorKey := strings.Join(canonicalProviders, ",") + ":" + modelKey
start := normalizeCursor(s.mixedCursors[cursorKey], len(winning))

for offset := 0; offset < len(winning); offset++ {
    candidate := winning[(start+offset)%len(winning)]
    picked := candidate.shard.pickReadyAtPriorityLocked(
        false, candidate.priority, schedulerStrategyRoundRobin, predicate,
    )
    if picked == nil {
        continue
    }
    s.mixedCursors[cursorKey] = start + offset + 1
    return picked, candidate.providerKey, nil
}
```

Do not use credential counts to size provider segments.

- [ ] **Step 5: Preserve fill-first and weighted-round-robin paths**

Keep the existing fill-first implementation unchanged. Keep weighted-round-robin credential semantics unchanged until a separate weighted-provider design exists.

- [ ] **Step 6: Run focused scheduler tests**

Run:

```bash
go test ./sdk/cliproxy/auth -run 'TestAuthSchedulerPickMixed|TestAuthSchedulerPickSingle' -count=1 -v
```

Expected: new provider-first tests PASS; existing single-provider, fill-first, cooldown, priority, and weighted tests PASS.

- [ ] **Step 7: Commit the scheduler implementation**

```bash
git add sdk/cliproxy/auth/scheduler.go
git commit -m "feat: balance mixed round robin by provider"
```

### Task 4: Write failing mixed-route session-affinity tests

**Files:**
- Modify: `sdk/cliproxy/auth/session_affinity_priority_test.go`
- Modify if better aligned with current test layout: `sdk/cliproxy/auth/selector_test.go`

- [ ] **Step 1: Add stable session option helpers**

Construct requests with explicit affinity headers:

```go
func affinityOptions(sessionID string) cliproxyexecutor.Options {
    return cliproxyexecutor.Options{
        Headers: http.Header{"X-Session-Affinity": []string{sessionID}},
    }
}
```

- [ ] **Step 2: Add cold-session provider alternation and sticky reuse**

Create two providers serving one model. For sessions `session-a` and `session-b`, assert:

```go
// First requests bind to different providers.
// Repeated requests for each session return the original auth/provider.
```

- [ ] **Step 3: Add model and provider-set isolation**

For one session ID, call:

```text
model A with providers A+B
model B with providers A+B
model A with provider A only
```

Assert the three bindings do not collide.

- [ ] **Step 4: Add failover and non-preemption tests**

Mark the bound auth unavailable. Assert selection first chooses another credential in the same provider. Then mark that provider exhausted and assert failover to the next provider. Restore the first provider and assert the healthy rebound session remains on its current auth while a new session may select the recovered provider.

- [ ] **Step 5: Add no-session coverage**

Call mixed selection without an affinity signal. Assert provider round robin advances but no cache binding is created.

- [ ] **Step 6: Run and confirm failure**

Run:

```bash
go test ./sdk/cliproxy/auth -run 'TestSessionAffinityMixed' -count=1 -v
```

Expected: FAIL because the current `SessionAffinitySelector` keys mixed bindings as `mixed::session::model` and delegates flattened auth selection.

- [ ] **Step 7: Commit the failing affinity tests**

```bash
git add sdk/cliproxy/auth/session_affinity_priority_test.go sdk/cliproxy/auth/selector_test.go
git commit -m "test: define mixed provider session affinity"
```

### Task 5: Implement provider-set/model-scoped mixed affinity

**Files:**
- Modify: `sdk/cliproxy/auth/selector.go`
- Modify: `sdk/cliproxy/auth/conductor_selection.go`
- Modify: `sdk/cliproxy/auth/scheduler.go`

- [ ] **Step 1: Add a canonical mixed-route scope key**

Add:

```go
func mixedRouteScope(providers []string, model string) string {
    canonical := canonicalProviderKeys(providers)
    return strings.Join(canonical, ",") + "::" + canonicalModelKey(model)
}
```

- [ ] **Step 2: Pass the canonical provider set into session-aware mixed selection**

Do not call the generic selector with only provider `mixed`. Add a mixed selection entry point that receives the actual provider set:

```go
func (s *SessionAffinitySelector) PickMixed(
    ctx context.Context,
    providers []string,
    model string,
    opts cliproxyexecutor.Options,
    auths []*Auth,
) (*Auth, error)
```

Its cache key is:

```go
cacheKey := "mixed::" + mixedRouteScope(providers, model) + "::" + primaryID
```

The cached value remains the concrete auth ID.

- [ ] **Step 3: Validate cached auth against live candidates**

On a cache hit, reuse the auth only when it is present in the live eligible auth slice. Do not cache provider eligibility separately.

- [ ] **Step 4: Preserve same-provider preference on bound-auth failure**

When the cached auth is unavailable, identify its provider from current manager/auth state. First run provider-local selection for that provider/model. Only if no eligible credential remains should mixed provider selection choose the next provider and replace the cache binding.

- [ ] **Step 5: Integrate the mixed affinity entry point**

Update `pickNextMixedLegacy` and the scheduler fast path so session-affinity mixed routes use `PickMixed`, while single-provider calls keep `Pick`.

- [ ] **Step 6: Run affinity and scheduler tests**

Run:

```bash
go test ./sdk/cliproxy/auth -run 'TestSessionAffinity|TestAuthSchedulerPickMixed' -count=1 -v
```

Expected: PASS.

- [ ] **Step 7: Commit mixed affinity**

```bash
git add sdk/cliproxy/auth/selector.go sdk/cliproxy/auth/conductor_selection.go sdk/cliproxy/auth/scheduler.go
git commit -m "feat: scope mixed affinity by providers and model"
```

### Task 6: Protect execution and streaming failover boundaries

**Files:**
- Modify: `sdk/cliproxy/auth/conductor_execution_test.go`
- Inspect and modify when the new failure-order tests fail: `sdk/cliproxy/auth/conductor_execution.go`

- [ ] **Step 1: Add non-streaming failure-order tests**

Create a recording executor and assert this order:

```text
bound credential in provider A
next credential in provider A
credential in provider B
```

Use a retryable 429/502 for the first attempts. Assert a 400/422 invalid request stops after one call.

- [ ] **Step 2: Add streaming bootstrap and committed-output tests**

Add two tests:

```go
// First provider returns an error before any chunk: provider B is tried.
// First provider emits one chunk then errors: provider B is not tried.
```

Assert the call log and downstream chunks explicitly.

- [ ] **Step 3: Run the tests and confirm current behavior**

Run:

```bash
go test ./sdk/cliproxy/auth -run 'TestManagerExecute.*MixedProvider|TestManagerExecuteStream.*MixedProvider' -count=1 -v
```

Expected: the invalid-request test passes without fallback. The retryable failure-order test either fails at the first incorrect cross-provider selection or passes and proves no execution change is required.

- [ ] **Step 4: Implement only the exposed execution gap**

Preserve `tried` auth tracking. Ensure the selection loop exhausts eligible credentials from the affinity-bound provider before selecting another provider, while retaining the existing first-byte streaming boundary.

- [ ] **Step 5: Run focused and package tests**

Run:

```bash
go test ./sdk/cliproxy/auth -count=1
go test ./sdk/cliproxy -count=1
```

Expected: PASS.

- [ ] **Step 6: Commit execution semantics**

```bash
git add sdk/cliproxy/auth/conductor_execution.go sdk/cliproxy/auth/conductor_execution_test.go
git commit -m "test: enforce mixed provider failover boundaries"
```

If the failure-order tests prove existing execution code already satisfies the contract, leave `conductor_execution.go` unchanged and commit the new regression tests only.

### Task 7: Add routing transition events and counters

**Files:**
- Modify: the existing CLIProxyAPI auth-selection event/hook package identified by repository search.
- Modify: the existing CLIProxyAPI metrics package identified by repository search.
- Modify: `sdk/cliproxy/auth/selector.go`
- Modify: `sdk/cliproxy/auth/conductor_selection.go`
- Test: colocated event and metric tests beside the identified packages.

- [ ] **Step 1: Identify the authoritative event and metric primitives**

Use repository-native search for `prometheus`, `CounterVec`, routing hooks, and result callbacks under `internal/` and `sdk/cliproxy/`. Record the exact packages in the task notes before editing.

Use those existing packages. Do not create a VibeProxy-side cache, polling surface, independent metrics server, or duplicate transition bus.

- [ ] **Step 2: Define transition names**

Use stable outcomes:

```text
provider_binding_created
binding_hit
credential_reselected
provider_failed_over
no_eligible_provider
```

Labels must be bounded: provider, model, and outcome. Do not label metrics with session IDs or auth IDs.

- [ ] **Step 3: Emit one event and increment one counter per transition**

Logs may include a truncated session ID; events and counters must not expose secrets or prompt content.

- [ ] **Step 4: Add exact-once tests**

Assert each routing transition produces one event and one counter increment. Assert a successful binding hit does not increment failover counters.

- [ ] **Step 5: Run observability tests**

Run the focused tests in the exact event and metrics packages identified in Step 1, then:

```bash
go test ./sdk/cliproxy/auth -count=1
```

Expected: PASS.

- [ ] **Step 6: Commit observability**

```bash
git add sdk/cliproxy/auth internal
git commit -m "feat: observe mixed provider routing transitions"
```

Stage only files actually changed.

### Task 8: Document and release the CLIProxyAPI behavior

**Files:**
- Modify: `config.example.yaml`
- Modify: the existing routing documentation or README section.
- Modify: changelog/release notes according to CLIProxyAPI convention.

- [ ] **Step 1: Update round-robin documentation**

Document:

```yaml
routing:
  strategy: round-robin
  session-affinity: true
  session-affinity-ttl: 1h
```

State that mixed routes balance providers equally first, then rotate credentials inside the selected provider/model shard.

- [ ] **Step 2: Document affinity and failover**

State that bindings are scoped by session, canonical model, and canonical eligible provider set; retryable failures can rebind before output, but never after first byte.

- [ ] **Step 3: Run upstream verification**

Run:

```bash
gofmt -w sdk/cliproxy/auth/*.go
go test ./sdk/cliproxy/auth ./sdk/cliproxy
go test ./...
```

Expected: PASS.

- [ ] **Step 4: Commit documentation**

```bash
git add config.example.yaml README.md CHANGELOG.md
git commit -m "docs: define provider-first round robin"
```

Adjust staged documentation paths to repository convention.

- [ ] **Step 5: Open the upstream PR and obtain a release**

The PR description must include the unequal-credential regression, session-affinity behavior, failover boundary, and verification commands. Wait for an official release tag before updating VibeProxy's bundled binary.

### Task 9: Add VibeProxy routing defaults with failing config verification

**Files:**
- Modify: `src/Sources/Resources/config.yaml`
- Modify: `src/Verification/ConfigComposerSpec.swift`

- [ ] **Step 1: Add failing bundled-default assertions**

In `ConfigComposerSpec`, add a test with bundled routing:

```swift
let bundledRoot: [String: Any] = [
    "routing": [
        "strategy": "round-robin",
        "session-affinity": true,
        "session-affinity-ttl": "1h"
    ]
]
let userRoot: [String: Any] = ["request-timeout": "30m"]
let merged = ConfigComposer.composeAdditiveBaseConfig(
    bundledRoot: bundledRoot,
    userRoot: userRoot
)
let routing = dictionary(merged["routing"])
expectEqual(routing["strategy"] as? String, "round-robin", "bundled strategy should remain", recorder: recorder)
expectEqual(routing["session-affinity"] as? Bool, true, "session affinity should remain", recorder: recorder)
expectEqual(routing["session-affinity-ttl"] as? String, "1h", "affinity ttl should remain", recorder: recorder)
```

- [ ] **Step 2: Add explicit user override assertions**

Use:

```swift
let userRoot: [String: Any] = [
    "routing": [
        "session-affinity": false,
        "session-affinity-ttl": "15m"
    ]
]
```

Assert strategy remains bundled while the two explicit user values win.

- [ ] **Step 3: Run standalone verification and confirm failure**

Compile and run using the repository's existing verification command or:

```bash
cd src
swiftc -o /tmp/config-composer-spec   Sources/ConfigComposer.swift   Sources/CustomProviders.swift   Sources/ProviderCatalog.swift   Verification/ConfigComposerSpec.swift   -framework Foundation
/tmp/config-composer-spec
```

Expected: PASS for the existing assertions; the new assertions fail until the bundled config contains the routing defaults.

- [ ] **Step 4: Add the bundled defaults**

Append to `src/Sources/Resources/config.yaml`:

```yaml
routing:
  strategy: round-robin
  session-affinity: true
  session-affinity-ttl: "1h"
```

- [ ] **Step 5: Run standalone verification**

Expected output:

```text
ConfigComposerSpec: all checks passed
```

- [ ] **Step 6: Commit VibeProxy defaults**

```bash
git add src/Sources/Resources/config.yaml src/Verification/ConfigComposerSpec.swift
git commit -m "feat: enable session-sticky round robin"
```

### Task 10: Bundle the released CLIProxyAPI binary

**Files:**
- Modify: `src/Sources/Resources/cli-proxy-api-plus`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Download the official release artifact**

Use the same asset-selection logic as `.github/workflows/update-cliproxyapi.yml`. Verify the tag is the first release containing provider-first mixed round robin.

- [ ] **Step 2: Replace only the bundled binary**

Copy the Darwin arm64 binary to:

```text
src/Sources/Resources/cli-proxy-api-plus
```

Run:

```bash
chmod +x src/Sources/Resources/cli-proxy-api-plus
file src/Sources/Resources/cli-proxy-api-plus
```

Expected: a non-empty Mach-O arm64 executable.

- [ ] **Step 3: Record the version and feature**

Add a changelog entry naming the CLIProxyAPI version and provider-first mixed round robin behavior.

- [ ] **Step 4: Commit the binary update**

```bash
git add src/Sources/Resources/cli-proxy-api-plus CHANGELOG.md
git commit -m "chore: update CLIProxyAPI for provider routing"
```

### Task 11: Verify VibeProxy end to end

**Files:**
- No source changes expected.

- [ ] **Step 1: Run the config verification harness**

Run the exact standalone command established in Task 9.

Expected: `ConfigComposerSpec: all checks passed`.

- [ ] **Step 2: Build VibeProxy**

Run:

```bash
make test
```

Expected: Swift build succeeds. Also run `swift test` and record the known pre-existing `no such module 'XCTest'` environment failure unless the toolchain has been corrected.

- [ ] **Step 3: Build an app bundle without installing it**

Run:

```bash
make app
```

Expected: `VibeProxy.app` is created and code-sign verification completes according to local signing availability.

- [ ] **Step 4: Use an isolated runtime config**

Create temporary OpenCode Go and Ollama Cloud test providers exposing the same alias. Do not overwrite the user's active credentials or main `~/.cli-proxy-api` directory.

- [ ] **Step 5: Exercise session-sticky provider distribution**

Send requests with explicit `X-Session-Affinity` values:

```text
session-a -> provider A
session-b -> provider B
session-a again -> provider A
session-b again -> provider B
```

Use structured routing logs to identify providers.

- [ ] **Step 6: Exercise failover and recovery**

Disable one provider, confirm both sessions succeed through the remaining provider, re-enable it, and confirm new sessions distribute across both while existing healthy bindings remain stable.

- [ ] **Step 7: Run the repository type/build checks**

Run:

```bash
make test
```

Expected: PASS.

- [ ] **Step 8: Commit no generated bundle**

Remove untracked build artifacts if repository conventions require it. Do not commit `VibeProxy.app` or `.build` output.

### Task 12: Final review and delivery

**Files:**
- Review all changed CLIProxyAPI and VibeProxy files.

- [ ] **Step 1: Review invariants against the approved specification**

Confirm:

```text
provider share independent of credential count
provider/model cursor isolation
canonical provider-set scope
session stickiness
same-provider credential retry first
cross-provider failover before first byte only
invalid-request terminal behavior
routing transition event + counter coverage
user override preservation
```

- [ ] **Step 2: Run final upstream checks**

```bash
go test ./...
```

Expected: PASS.

- [ ] **Step 3: Run final VibeProxy checks**

```bash
make test
```

Expected: PASS. Record the separate known `swift test` XCTest limitation if still present.

- [ ] **Step 4: Open or update the VibeProxy PR**

The PR must reference the upstream release, explain the new default, and include the live two-provider session-affinity evidence.

- [ ] **Step 5: Do not merge until the binary/version contract is proven**

Confirm the VibeProxy PR bundles the exact CLIProxyAPI release whose source passed Tasks 2–8. A config-only PR is incomplete.
