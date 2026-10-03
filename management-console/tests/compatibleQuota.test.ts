import { describe, expect, test } from 'bun:test';
import {
  compatibleQuotaAdapter,
  createCompatibleQuotaReader,
  listCompatibleQuotaCredentials,
  parseCompatibleQuota,
} from '../scripts/compatible-quota.mjs';

const config = (key = 'fixture-key', base = 'https://ollama.com/v1', disabled = false) => ({
  'openai-compatibility': [
    {
      name: 'fixture-cloud',
      'base-url': base,
      disabled,
      'api-key-entries': [{ 'api-key': key }],
    },
  ],
});
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });

describe('compatible provider meters', () => {
  test('oversized utilization cannot produce an infinite percentage', () => {
    expect(
      parseCompatibleQuota('ollama', { limits: { monthly: { usage: Number.MAX_VALUE } } }).windows
    ).toEqual([]);
  });
  test('Ollama utilization ratios become remaining capacity, without summing windows', () => {
    const result = parseCompatibleQuota('ollama', {
      limits: { session: { usage: 0.25 }, weekly: { usage: 0.6 }, monthly: { usage: 0.8 } },
    });
    expect(result.windows.map((window) => window.remainingPercent)).toEqual([75, 40, 20]);
    expect(result.balances).toEqual([]);
    expect(result.windows.every((window) => window.resetAt === null)).toBe(true);
  });

  test('zero use, exhausted and over-limit windows remain distinct', () => {
    expect(
      parseCompatibleQuota('ollama', { limits: { monthly: { usage: 0 } } }).windows[0]
        .remainingPercent
    ).toBe(100);
    expect(
      parseCompatibleQuota('ollama', { limits: { monthly: { usage: 1 } } }).windows[0]
        .remainingPercent
    ).toBe(0);
    expect(
      parseCompatibleQuota('ollama', { limits: { monthly: { usage: 1.2 } } }).windows[0].usedPercent
    ).toBe(120);
    expect(
      parseCompatibleQuota('ollama', { limits: { monthly: { usage: 1.2 } } }).windows[0]
        .remainingPercent
    ).toBe(0);
  });

  test.each([null, undefined, '', ' ', true, false, 'unknown', -1, Infinity])(
    'does not turn invalid utilization %s into zero',
    (usage) => {
      expect(parseCompatibleQuota('ollama', { limits: { monthly: { usage } } }).windows).toEqual(
        []
      );
    }
  );

  test('only a valid provider-reported reset timestamp is retained', () => {
    const time = '2030-01-02T00:00:00Z';
    expect(
      parseCompatibleQuota('ollama', { limits: { monthly: { usage: 0.5, reset_at: time } } })
        .windows[0].resetAt
    ).toBe(time);
    expect(
      parseCompatibleQuota('ollama', { limits: { monthly: { usage: 0.5, reset_at: 'bad' } } })
        .windows[0].resetAt
    ).toBeNull();
  });

  test('OpenRouter key budget is separate from total spend and preserves zero remaining', () => {
    const result = parseCompatibleQuota('openrouter', {
      data: { limit: 10, limit_remaining: 0, usage: 42 },
    });
    expect(result.balances).toEqual([
      { id: 'key_remaining', amount: 0, currency: 'USD' },
      { id: 'key_spent', amount: 42, currency: 'USD' },
    ]);
    expect(result.windows[0].remainingPercent).toBe(0);
  });

  test('an unlimited key does not invent an account credit balance', () => {
    const result = parseCompatibleQuota('openrouter', {
      data: { limit: null, limit_remaining: null, usage: 0 },
    });
    expect(result.windows).toEqual([]);
    expect(result.balances).toEqual([{ id: 'key_spent', amount: 0, currency: 'USD' }]);
  });
});

describe('authenticated compatible quota reader', () => {
  test.each([
    'http://ollama.com/v1',
    'https://ollama.com.attacker.test/v1',
    'https://attacker.test/ollama.com/v1',
    'https://ollama.com:8443/v1',
    'https://user:password@ollama.com/v1',
    'https://ollama.com/v1?key=secret',
    'https://ollama.com/proxy/v1',
  ])('rejects unsupported origins and credentials in URL: %s', (url) => {
    expect(compatibleQuotaAdapter(url)).toBeNull();
  });

  test('public credential metadata never includes API keys, headers, or base URL secrets', () => {
    const input = config();
    input['openai-compatibility'][0]['headers'] = { Authorization: 'private-header' };
    const result = listCompatibleQuotaCredentials(input);
    expect(result).toHaveLength(1);
    expect(JSON.stringify(result)).not.toContain('fixture-key');
    expect(JSON.stringify(result)).not.toContain('private-header');
    expect(result[0].scope).toBe('account');
  });

  test('skips disabled and unsupported credentials without sending keys anywhere', async () => {
    let calls = 0;
    const read = createCompatibleQuotaReader({
      fetcher: async () => {
        calls++;
        return json({});
      },
    });
    for (const [input, status] of [
      [config('fixture-key', 'https://ollama.com/v1', true), 'disabled'],
      [config('fixture-key', 'https://example.test/v1'), 'unsupported'],
    ] as const) {
      expect((await read(input, listCompatibleQuotaCredentials(input)[0].id)).status).toBe(status);
    }
    expect(calls).toBe(0);
  });

  test('queries fixed GET endpoints, rejects redirects, and filters raw account metadata', async () => {
    const input = config();
    const read = createCompatibleQuotaReader({
      fetcher: async (url, options) => {
        expect(url).toBe('https://ollama.com/api/usage');
        expect(options.method).toBe('GET');
        expect(options.redirect).toBe('error');
        expect(options.headers.Authorization).toBe('Bearer fixture-key');
        return json({
          email: 'private@example.test',
          token: 'private-token',
          limits: { monthly: { usage: 0.5 } },
        });
      },
    });
    const result = await read(input, listCompatibleQuotaCredentials(input)[0].id);
    expect(result.status).toBe('success');
    expect(result.windows[0].remainingPercent).toBe(50);
    expect(JSON.stringify(result)).not.toContain('private');
    expect(JSON.stringify(result)).not.toContain('fixture-key');
  });

  test('cache is credential-specific, expires, and manual refresh bypasses it', async () => {
    let time = 0;
    let calls = 0;
    const input = config();
    const read = createCompatibleQuotaReader({
      now: () => time,
      fetcher: async () => {
        calls++;
        return json({ limits: { monthly: { usage: 0.5 } } });
      },
    });
    const id = listCompatibleQuotaCredentials(input)[0].id;
    await read(input, id);
    await read(input, id);
    expect(calls).toBe(1);
    await read(input, id, true);
    expect(calls).toBe(2);
    time = 31000;
    await read(input, id);
    expect(calls).toBe(3);
    const other = config('another-fixture');
    await read(other, listCompatibleQuotaCredentials(other)[0].id);
    expect(calls).toBe(4);
    await expect(read(other, id)).rejects.toThrow('Credential changed');
  });

  test('concurrent requests share one upstream read and do not cache failures', async () => {
    let calls = 0;
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const input = config();
    const id = listCompatibleQuotaCredentials(input)[0].id;
    const read = createCompatibleQuotaReader({
      fetcher: async () => {
        calls++;
        await gate;
        return json({ key: 'private-key' }, 401);
      },
    });
    const first = read(input, id);
    const second = read(input, id);
    release();
    const results = await Promise.all([first, second]);
    expect(calls).toBe(1);
    expect(results[0].status).toBe('error');
    expect(results[0].httpStatus).toBe(401);
    expect(JSON.stringify(results)).not.toContain('private-key');
    await read(input, id);
    expect(calls).toBe(2);
  });

  test('unknown payloads remain unavailable instead of showing full allowance', async () => {
    const input = config();
    const read = createCompatibleQuotaReader({
      fetcher: async () => json({ activity: { cost: '9.50' } }),
    });
    const result = await read(input, listCompatibleQuotaCredentials(input)[0].id);
    expect(result.status).toBe('unavailable');
    expect(result.windows).toEqual([]);
    expect(result.balances).toEqual([]);
  });

  test('a failed manual refresh invalidates the previous cached balance', async () => {
    let calls = 0;
    const input = config();
    const id = listCompatibleQuotaCredentials(input)[0].id;
    const read = createCompatibleQuotaReader({
      fetcher: async () => {
        calls++;
        return calls === 2 ? json({}, 401) : json({ limits: { monthly: { usage: 0.5 } } });
      },
    });
    expect((await read(input, id)).status).toBe('success');
    expect((await read(input, id, true)).status).toBe('error');
    expect((await read(input, id)).status).toBe('success');
    expect(calls).toBe(3);
  });
});
