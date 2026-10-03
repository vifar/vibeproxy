import { describe, expect, test } from 'bun:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { I18nextProvider } from 'react-i18next';
import { createInstance } from 'i18next';
import { ProviderResourceTable } from '../src/features/providers/components/ProviderResourceTable';
import { openaiToResource } from '../src/features/providers/adapters';
import { buildRecentRequestCompositeKey } from '../src/utils/recentRequests';
import en from '../src/i18n/locales/en.json';

const i18n = createInstance();
await i18n.init({ lng: 'en', resources: { en: { translation: en } } });
const noop = () => {};
const config = {
  name: 'ollama-cloud',
  baseUrl: 'https://example.test/long-provider-endpoint/that-must-remain-readable/v1',
  apiKeyEntries: [{ apiKey: 'fixture-secret-key-never-render' }],
  models: [{ name: 'model-a' }, { name: 'model-b' }],
  prefix: 'cloud',
};
const resource = openaiToResource(config, 0);
const usage = new Map([
  [
    config.name,
    new Map([
      [
        buildRecentRequestCompositeKey(config.baseUrl, config.apiKeyEntries[0].apiKey),
        { success: 17752, failed: 47, recentRequests: [] },
      ],
    ]),
  ],
]);
const render = (disabled = false) =>
  renderToStaticMarkup(
    createElement(
      I18nextProvider,
      { i18n },
      createElement(ProviderResourceTable, {
        resources: [resource],
        disableMutations: disabled,
        usageByProvider: usage,
        onView: noop,
        onEdit: noop,
        onModels: noop,
        onDelete: noop,
        onToggleDisabled: noop,
      })
    )
  );

describe('responsive provider resource rows', () => {
  test('keeps endpoints and complete usage counts readable while masking credentials', () => {
    const markup = render();
    expect(markup).toContain(config.baseUrl);
    expect(markup).toContain('17,752');
    expect(markup).toContain('47');
    expect(markup).toContain('cloud');
    expect(markup).not.toContain(config.apiKeyEntries[0].apiKey);
  });

  test('exposes model selection and labeled view/edit actions', () => {
    const markup = render();
    expect(markup).toContain('Models');
    expect(markup).toContain('<strong>2</strong>');
    expect(markup).toContain('View');
    expect(markup).toContain('Edit');
    expect(markup).toContain('aria-label="Delete"');
  });

  test('keeps viewing available while disabling mutation controls', () => {
    const markup = render(true);
    expect((markup.match(/disabled=""/g) || []).length).toBe(4);
    expect(markup).toContain('View');
  });
});
