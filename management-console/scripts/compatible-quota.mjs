import { createHmac, randomBytes } from 'node:crypto';

const identitySecret = randomBytes(32);
const number = (value) => {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && !value.trim()) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
};

// Identify the actual endpoint, rather than trusting a user-editable provider name.
// Never forward a configured key to a different origin or follow redirects.
export function compatibleQuotaAdapter(baseUrl) {
  try {
    const url = new URL(baseUrl);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search)
      return null;
    const pathname = url.pathname.replace(/\/+$/, '');
    if (url.hostname === 'ollama.com' && ['', '/v1'].includes(pathname)) {
      return { id: 'ollama', endpoint: 'https://ollama.com/api/usage', scope: 'account' };
    }
    if (url.hostname === 'openrouter.ai' && ['', '/api/v1'].includes(pathname)) {
      return { id: 'openrouter', endpoint: 'https://openrouter.ai/api/v1/key', scope: 'key' };
    }
  } catch {
    // An invalid endpoint has no supported balance API.
  }
  return null;
}

function targets(config) {
  return (config['openai-compatibility'] || []).flatMap((provider) => {
    const adapter = compatibleQuotaAdapter(provider['base-url']);
    return (provider['api-key-entries'] || []).flatMap((entry, index) => {
      const key = entry['api-key'];
      if (typeof key !== 'string' || !key.trim()) return [];
      const id = createHmac('sha256', identitySecret)
        .update(JSON.stringify([provider.name, provider['base-url'], index, key]))
        .digest('hex');
      return [
        {
          key,
          adapter,
          credential: {
            id,
            providerName: provider.name,
            keyNumber: index + 1,
            enabled: !provider.disabled && !entry.disabled,
            supported: Boolean(adapter),
            scope: adapter?.scope || 'account',
          },
        },
      ];
    });
  });
}

export function listCompatibleQuotaCredentials(config) {
  return targets(config).map(({ credential }) => credential);
}

export function parseCompatibleQuota(adapter, payload) {
  const windows = [];
  const balances = [];
  if (adapter === 'ollama') {
    // Ollama /api/usage reports utilization as a ratio, including over-limit values.
    for (const period of ['session', 'weekly', 'monthly']) {
      const limit = payload?.limits?.[period];
      const usage = number(limit?.usage);
      if (usage === null) continue;
      const usedPercent = usage * 100;
      if (!Number.isFinite(usedPercent)) continue;
      const resetAt =
        typeof limit.reset_at === 'string' && Number.isFinite(Date.parse(limit.reset_at))
          ? limit.reset_at
          : null;
      windows.push({
        id: period,
        usedPercent,
        remainingPercent: Math.max(0, 100 - usedPercent),
        resetAt,
      });
    }
  } else if (adapter === 'openrouter') {
    const data = payload?.data;
    const remaining = number(data?.limit_remaining);
    const limit = number(data?.limit);
    const spent = number(data?.usage);
    if (remaining !== null)
      balances.push({ id: 'key_remaining', amount: remaining, currency: 'USD' });
    if (spent !== null) balances.push({ id: 'key_spent', amount: spent, currency: 'USD' });
    if (limit !== null && limit > 0 && remaining !== null) {
      const remainingPercent = Math.min(100, (remaining / limit) * 100);
      windows.push({
        id: 'key_budget',
        usedPercent: 100 - remainingPercent,
        remainingPercent,
        resetAt: null,
      });
    }
  }
  return { windows, balances };
}

export function createCompatibleQuotaReader({
  fetcher = fetch,
  now = Date.now,
  ttlMs = 30000,
} = {}) {
  const cache = new Map();
  const pending = new Map();
  return async (config, id, force = false) => {
    const target = targets(config).find((item) => item.credential.id === id);
    if (!target)
      throw Object.assign(new Error('Credential changed. Refresh the list.'), { status: 404 });
    const { credential, adapter, key } = target;
    const empty = { credential, windows: [], balances: [], fetchedAt: null };
    if (!credential.enabled) return { ...empty, status: 'disabled' };
    if (!adapter) return { ...empty, status: 'unsupported' };
    const previous = cache.get(id);
    if (!force && previous && now() - previous.at < ttlMs) return previous.result;
    if (pending.has(id)) return pending.get(id);
    const task = (async () => {
      try {
        const response = await fetcher(adapter.endpoint, {
          method: 'GET',
          headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' },
          redirect: 'error',
          signal: AbortSignal.timeout(15000),
        });
        if (!response.ok) {
          cache.delete(id);
          return { ...empty, status: 'error', httpStatus: response.status };
        }
        const data = parseCompatibleQuota(adapter.id, await response.json());
        const result = {
          credential,
          ...data,
          status: data.windows.length || data.balances.length ? 'success' : 'unavailable',
          fetchedAt: new Date(now()).toISOString(),
        };
        cache.set(id, { at: now(), result });
        // Retain a small per-credential cache, never raw upstream responses or keys.
        for (const [key, value] of cache) if (now() - value.at >= ttlMs) cache.delete(key);
        if (cache.size > 500) cache.delete(cache.keys().next().value);
        return result;
      } catch {
        cache.delete(id);
        // Upstream error bodies can contain credentials or personal account metadata.
        return { ...empty, status: 'error' };
      }
    })();
    pending.set(id, task);
    try {
      return await task;
    } finally {
      pending.delete(id);
    }
  };
}
