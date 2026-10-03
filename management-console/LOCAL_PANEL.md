# VibeProxy management console

This frontend and its model helper are maintained inside the `vifar/vibeproxy`
repository under `management-console/`. The original upstream license remains in
`LICENSE`; `UPSTREAM.json` records the imported source revision. No separate
frontend clone or Git submodule is required.

Install Node.js 24 and Bun 1.3.14, and run the VibeProxy desktop app with a
management key configured in `~/.cli-proxy-api/config.yaml`. From the repository
root:

```sh
cd management-console
bun install --frozen-lockfile
cd ..
make management-verify
make management-install
```

The installer backs up the previous page, installs the built page, disables
automatic upstream panel replacement, and registers the model helper to start
at login. It preserves the existing management key, network settings, provider
credentials, and model selections. It does not enable remote management or
Tailscale Serve. Keep the checkout and its installed dependencies available
while the helper runs from this source tree.

This checkout is based on CPAMC v1.24.2 and uses the existing `/v0/management`
API. The local changes add a default ledger layout, provider quota summaries,
and an email visibility toggle to Quota Management. Summary percentages add
remaining capacity across known credentials with the same quota period;
unavailable data is excluded and the coverage count is shown.

Each Codex credential now shows the upstream credit balance separately from
earned manual reset credits. Unlimited, hidden, zero, and unreported balances
remain distinct. Claude shows its remaining extra usage budget and spending;
xAI shows monthly and on-demand remaining budgets when billing data is available.
These figures use the existing authenticated quota refresh requests. Credit
units and dollar spend budgets are not combined across providers.

OpenAI-compatible API credentials also appear in Quota Management. The local
helper queries Ollama Cloud's account utilization through
`https://ollama.com/api/usage` and OpenRouter's per-key spending allowance through
`https://openrouter.ai/api/v1/key`. Ollama session, weekly, and monthly windows
are displayed when reported, with remaining percentages and any reported reset
time. OpenRouter shows the key's remaining dollar budget and spend. These are
provider-reported meters, including use outside VibeProxy; proxy request counts
are not used to estimate the remaining allowance. Account meters are not summed
across keys, and unreported dollar balances stay unavailable.

Usage loads when the quota page opens, with three concurrent queries at most.
Each credential has a 30-second helper cache and a manual refresh action that
requests fresh data. Keys stay inside the local helper; responses expose only
meter data and opaque credential IDs. Requests use fixed provider URLs, require
matching configured origins, and reject redirects. Unsupported providers remain
visible with an explicit unavailable status.

AI Providers now includes VibeProxy's subscription services and named compatible
providers (including Ollama Cloud, OpenCode Go, OpenRouter, and Vercel), plus
custom providers from the desktop configuration. Connected providers appear first.
The searchable model checklist uses the desktop's cached catalog, with backend
model definitions as a fallback when the desktop has no catalog for a service.
Refresh reloads the saved catalog and current provider state; pull new upstream
catalogs using VibeProxy's desktop refresh control.

API key resources use responsive rows with wrapping endpoints, fully visible
success/failure counts, and labeled View/Edit actions. The compatible provider's
Models button opens the same searchable model selection checklist.

The local model helper at `127.0.0.1:8319` reads the same desktop configuration and
catalog. It authenticates each request against the running backend using the
console's existing management key. The console reaches it through the backend's
authenticated `/v0/management/api-call`, so browsers on other machines do not
need direct access to port 8319. Responses contain model and account counts;
provider keys and auth-file contents are not returned.

Selections are saved to `~/.cli-proxy-api/config.yaml`, preserving unrelated
settings and existing model aliases/metadata. OAuth choices use
`oauth-included-models`; providers without a desktop catalog also persist the
exclusion complement. Compatible provider choices use the named entry's `models`.
The helper applies a narrow Management API patch for immediate use. VibeProxy's
existing config watcher regenerates the runtime config from the same saved
choices. Disabled providers stay disabled. API providers require at least one
selected model; OAuth supports an empty selection. Concurrent stale selections
are rejected with HTTP 409. Failed runtime updates roll back the helper's user
config write if another writer has not changed it.

The helper is installed as the current user's LaunchAgent:
`~/Library/LaunchAgents/io.vibeproxy.model-bridge.plist`. It runs the checked-in
`scripts/vibeproxy-model-bridge.mjs` with the Node runtime used for installation
and restarts at login.
Keep this checkout and its installed dependencies at their current path. For
manual foreground use after unloading the LaunchAgent:

```sh
node scripts/vibeproxy-model-bridge.mjs
```

To stop the helper:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/io.vibeproxy.model-bridge.plist"
```

To load it again:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/io.vibeproxy.model-bridge.plist"
```

Build and verify with the pinned Bun version:

```sh
npm exec --yes --package=bun@1.3.14 -- bun install --frozen-lockfile
npm exec --yes --package=bun@1.3.14 -- bun run verify
```

The built `dist/index.html` is installed as
`~/.cli-proxy-api/static/management.html`. Each installation saves the previous
page under `~/.cli-proxy-api/panel-releases/management-before-install-<timestamp>.html`.
Restore the desired backup to the installed path to undo that panel installation.

Local configuration disables automatic panel updates to preserve the v0 API
compatibility fix and these customizations. Verify backend compatibility and
reapply or port the source changes before replacing this panel with an upstream
release. Credentials are entered at runtime and are not stored in this checkout.

## Private Tailscale access

Keep the proxy's `host: 127.0.0.1`. Set `remote-management.allow-remote: true` in
the user config (retain the existing management secret), since Tailscale's HTTP
proxy forwards the tailnet client IP and the backend otherwise rejects it.
Then run:

```sh
tailscale serve --bg http://127.0.0.1:8318
```

Use `tailscale status --json` to find this Mac's `Self.DNSName`, then open
`https://<your-mac>.<your-tailnet>.ts.net/management.html#/ai-providers`
from a connected, permitted tailnet device. Serve proxies the panel and the model
API on the same backend; existing authentication remains required. The local
helper works through this proxy without an additional Serve entry. This procedure
does not run automatically during installation. If HTTPS is not yet enabled for
the tailnet, follow the enablement link printed by `tailscale serve` and rerun
the command. Keep VibeProxy and Tailscale running on the Mac; clients must be
connected to the tailnet and still sign in with the existing management key.

Check serving with `tailscale serve status`. To stop this Serve proxy, run
`tailscale serve --https=443 off`.
