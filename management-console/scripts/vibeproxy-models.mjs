import { createHash } from 'node:crypto';

// Matches VibeProxy's ServiceType and ProviderCatalog. Custom entries are discovered.
export const SERVICES = [
  ['antigravity', 'Antigravity', 'antigravity'],
  ['claude', 'Claude Code', 'claude'],
  ['codex', 'Codex', 'codex'],
  ['gemini', 'Gemini', 'gemini-cli'],
  ['github-copilot', 'GitHub Copilot', 'github-copilot'],
  ['kimi', 'Kimi', 'kimi'],
  ['qwen', 'Qwen', 'qwen'],
  ['xai', 'Grok (xAI)', 'xai'],
  ['zai', 'Z.AI GLM', null],
  ['ollama', 'Ollama', null],
  ['openrouter', 'OpenRouter', null],
  ['vercel', 'Vercel', null],
  ['ollama-cloud', 'Ollama Cloud', null],
  ['opencode-go', 'OpenCode Go', null],
].map(([id, name, oauthKey]) => ({ id, name, oauthKey }));

const unique = (items) => [...new Set(items.filter((id) => typeof id === 'string' && id))];
const modelID = (row) => row.alias || row.name || row.id;
const normalizeProvider = (id) => ({ anthropic: 'claude', 'gemini-cli': 'gemini' })[id] || id;

export function buildProviders({ user, runtime, base, cache, files, definitions = {} }) {
  const configured = runtime['openai-compatibility'] || [];
  const originals = base['openai-compatibility'] || [];
  const names = unique([...configured, ...originals].map((entry) => entry.name));
  const services = [...SERVICES];
  for (const id of names) {
    if (!services.some((service) => service.id === id)) {
      services.push({ id, name: id, oauthKey: null });
    }
  }
  return services.map((service) => {
    const effective = configured.find((entry) => entry.name === service.id);
    const original = originals.find((entry) => entry.name === service.id);
    const override = (user['openai-compatibility'] || []).find(
      (entry) => entry.name === service.id
    );
    const catalog = cache.providers?.[service.id] || cache.uiPools?.[service.id];
    const saved = service.oauthKey
      ? user['oauth-included-models']?.[service.oauthKey]
      : override && Object.hasOwn(override, 'models')
        ? (override.models || []).map(modelID)
        : undefined;
    const catalogBacked = Boolean(catalog?.models?.length);
    const available = unique([
      ...(catalogBacked ? catalog.models : definitions[service.id] || []).map((model) => model.id),
      ...(effective?.models || original?.models || []).map(modelID),
      ...(saved || []),
    ]).sort();
    const exclusions = runtime['oauth-excluded-models']?.[service.oauthKey] || [];
    // Disabled providers still retain their model choices. Without an explicit
    // selection the desktop follows the complete catalog, including before login.
    const selected =
      saved ??
      (service.oauthKey
        ? available.filter(
            (id) =>
              !matchesExclusion(
                id,
                exclusions.filter((pattern) => pattern !== '*')
              )
          )
        : !effective
          ? available
          : (effective.models || []).map(modelID));
    const accounts = files.filter(
      (file) =>
        normalizeProvider(file.provider || file.type) === service.id || file.label === service.id
    );
    const keyCount = (effective?.['api-key-entries'] || []).length;
    const activeAccounts = accounts.filter((file) => !file.disabled).length;
    const enabled = service.oauthKey
      ? !exclusions.includes('*')
      : Boolean(effective && !effective.disabled);
    const revision = createHash('sha256')
      .update(
        JSON.stringify({
          available,
          selected,
          exclusions,
          enabled,
        })
      )
      .digest('hex');
    return {
      ...service,
      catalogBacked,
      kind: service.oauthKey ? 'subscription' : 'compatible',
      models: available,
      selected: unique(selected),
      enabled,
      accountCount: Math.max(accounts.length, keyCount),
      activeAccounts: Math.max(activeAccounts, effective?.disabled ? 0 : keyCount),
      configured: Boolean(effective || accounts.length),
      canSave: Boolean(service.oauthKey || effective || original || catalogBacked),
      revision,
    };
  });
}

export function matchesExclusion(id, patterns) {
  return patterns.some((pattern) => {
    const escaped = pattern.split('*').map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    return new RegExp(`^${escaped.join('.*')}$`, 'i').test(id);
  });
}

export function selectionUpdate(provider, selected, user, runtime, base = {}) {
  if (
    !Array.isArray(selected) ||
    selected.some((id) => typeof id !== 'string') ||
    selected.some((id) => !provider.models.includes(id))
  ) {
    throw new Error('Invalid model selection');
  }
  const ids = unique(selected);
  const nextUser = structuredClone(user);
  if (provider.oauthKey) {
    nextUser['oauth-included-models'] ||= {};
    nextUser['oauth-included-models'][provider.oauthKey] = ids;
    // Explicit selection owns the exclusion complement, just as in ConfigComposer.
    const explicitlyDisabled = (user['oauth-excluded-models']?.[provider.oauthKey] || []).includes(
      '*'
    );
    if (nextUser['oauth-excluded-models'] && !explicitlyDisabled) {
      delete nextUser['oauth-excluded-models'][provider.oauthKey];
    }
    const wasEmptySelection =
      Array.isArray(user['oauth-included-models']?.[provider.oauthKey]) &&
      user['oauth-included-models'][provider.oauthKey].length === 0;
    const wasDisabled =
      !wasEmptySelection &&
      (runtime['oauth-excluded-models']?.[provider.oauthKey] || []).includes('*');
    const complement = !ids.length ? ['*'] : provider.models.filter((id) => !ids.includes(id));
    // Services without a desktop catalog keep explicit exclusions through ConfigComposer.
    if (!provider.catalogBacked && !explicitlyDisabled) {
      nextUser['oauth-excluded-models'] ||= {};
      nextUser['oauth-excluded-models'][provider.oauthKey] = complement;
    }
    const exclusions = !ids.length || wasDisabled ? ['*'] : complement;
    return {
      user: nextUser,
      path: '/oauth-excluded-models',
      patch: { provider: provider.oauthKey, models: exclusions },
    };
  }
  if (!ids.length) throw new Error('Select at least one model for an API provider');
  const effective = (runtime['openai-compatibility'] || []).find(
    (entry) => entry.name === provider.id
  );
  const entries = (nextUser['openai-compatibility'] ||= []);
  let entry = entries.find((item) => item.name === provider.id);
  if (!entry) {
    entry = { name: provider.id };
    entries.push(entry);
  }
  const original = (base['openai-compatibility'] || []).find((item) => item.name === provider.id);
  const knownRows = [
    ...(entry.models || []),
    ...(effective?.models || []),
    ...(original?.models || []),
  ];
  entry.models = ids.map((id) =>
    structuredClone(knownRows.find((row) => modelID(row) === id) || { name: id, alias: id })
  );
  return {
    user: nextUser,
    path: effective ? '/openai-compatibility' : null,
    patch: { name: provider.id, value: { models: entry.models } },
  };
}
