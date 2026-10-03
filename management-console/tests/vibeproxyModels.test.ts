import { describe, expect, test } from 'bun:test';
import { buildProviders, selectionUpdate, matchesExclusion } from '../scripts/vibeproxy-models.mjs';

const input = () => ({
  user: { 'oauth-included-models': { codex: ['gpt-test'] } },
  runtime: {
    'openai-compatibility': [{ name: 'ollama-cloud', models: [{ name: 'deepseek-test' }] }],
    'oauth-excluded-models': { claude: ['*'] },
  },
  base: {
    'openai-compatibility': [{ name: 'my-custom-endpoint', models: [{ name: 'custom-test' }] }],
  },
  cache: {
    providers: { 'ollama-cloud': { models: [{ id: 'deepseek-test' }, { id: 'glm-test' }] } },
    uiPools: { codex: { models: [{ id: 'gpt-test' }, { id: 'gpt-next' }] } },
  },
  definitions: {},
  files: [{ provider: 'codex', disabled: false }],
});

describe('VibeProxy shared model selections', () => {
  test('catalog models can be selected before a compatible provider is connected', () => {
    const data = input();
    data.cache.providers.openrouter = { models: [{ id: 'router-test' }, { id: 'router-next' }] };
    const provider = buildProviders(data).find((item) => item.id === 'openrouter');
    expect(provider.selected).toEqual(['router-next', 'router-test']);
    expect(provider.canSave).toBe(true);
    const update = selectionUpdate(provider, ['router-test'], data.user, data.runtime);
    expect(
      update.user['openai-compatibility'].find((item) => item.name === 'openrouter').models
    ).toEqual([{ name: 'router-test', alias: 'router-test' }]);
    expect(update.path).toBeNull();
  });
  test('uses the desktop catalog rather than expanding it with backend definitions', () => {
    const data = input();
    data.definitions.codex = [{ id: 'backend-only' }];
    expect(buildProviders(data).find((provider) => provider.id === 'codex').models).not.toContain(
      'backend-only'
    );
  });

  test('services without a desktop catalog persist backend exclusions across app reloads', () => {
    const data = input();
    data.definitions.antigravity = [{ id: 'gemini-test' }, { id: 'claude-test' }];
    const provider = buildProviders(data).find((item) => item.id === 'antigravity');
    const update = selectionUpdate(provider, ['gemini-test'], data.user, data.runtime);
    expect(update.user['oauth-excluded-models'].antigravity).toEqual(['claude-test']);
  });
  test('lists every desktop service plus custom providers without exposing credentials', () => {
    const providers = buildProviders(input());
    for (const id of [
      'github-copilot',
      'qwen',
      'antigravity',
      'zai',
      'ollama',
      'openrouter',
      'vercel',
      'ollama-cloud',
      'opencode-go',
      'my-custom-endpoint',
    ]) {
      expect(providers.some((provider) => provider.id === id)).toBe(true);
    }
    const codex = providers.find((provider) => provider.id === 'codex');
    expect(codex.selected).toEqual(['gpt-test']);
    expect(codex.activeAccounts).toBe(1);
    expect(JSON.stringify(providers)).not.toContain('api-key');
  });

  test('OAuth selections persist in the desktop source and apply the exclusion complement', () => {
    const data = input();
    const provider = buildProviders(data).find((item) => item.id === 'codex');
    const update = selectionUpdate(provider, ['gpt-next'], data.user, data.runtime);
    expect(update.user['oauth-included-models'].codex).toEqual(['gpt-next']);
    expect(update.patch).toEqual({ provider: 'codex', models: ['gpt-test'] });
    expect(data.user['oauth-included-models'].codex).toEqual(['gpt-test']);
  });

  test('an empty OAuth selection disables all models and preserves other providers', () => {
    const data = input();
    const provider = buildProviders(data).find((item) => item.id === 'codex');
    const update = selectionUpdate(provider, [], data.user, data.runtime);
    expect(update.patch.models).toEqual(['*']);
    expect(update.user['oauth-included-models'].codex).toEqual([]);
  });

  test('saving a selection never silently enables a disabled provider', () => {
    const data = input();
    data.cache.uiPools.claude = { models: [{ id: 'claude-test' }] };
    const provider = buildProviders(data).find((item) => item.id === 'claude');
    const update = selectionUpdate(provider, ['claude-test'], data.user, data.runtime);
    expect(update.patch.models).toEqual(['*']);
    expect(update.user['oauth-included-models'].claude).toEqual(['claude-test']);
  });

  test('custom selections preserve model aliases, metadata, and unrelated settings', () => {
    const data = input();
    data.user['routing'] = { strategy: 'round-robin' };
    data.runtime['openai-compatibility'][0].models = [
      { name: 'upstream-test', alias: 'friendly', thinking: { levels: ['high'] } },
    ];
    const provider = buildProviders(data).find((item) => item.id === 'ollama-cloud');
    const update = selectionUpdate(provider, ['friendly'], data.user, data.runtime);
    expect(update.patch.value.models).toEqual(data.runtime['openai-compatibility'][0].models);
    expect(update.user.routing).toEqual(data.user.routing);
    expect(update.user['oauth-included-models'].codex).toEqual(['gpt-test']);
  });

  test('rejects unknown models and ambiguous empty API provider selections', () => {
    const data = input();
    const provider = buildProviders(data).find((item) => item.id === 'ollama-cloud');
    expect(() => selectionUpdate(provider, ['invented'], data.user, data.runtime)).toThrow(
      'Invalid model selection'
    );
    expect(() => selectionUpdate(provider, [], data.user, data.runtime)).toThrow(
      'Select at least one'
    );
  });

  test('wildcard exclusions match literal punctuation rather than regular expressions', () => {
    expect(matchesExclusion('gpt-5.4', ['gpt-5.*'])).toBe(true);
    expect(matchesExclusion('gpt-5x4', ['gpt-5.4'])).toBe(false);
  });
});
