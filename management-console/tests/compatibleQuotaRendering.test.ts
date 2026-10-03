import { beforeAll, describe, expect, test } from 'bun:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import i18n from '@/i18n';
import { CompatibleQuotaBody } from '@/features/quota/components/CompatibleQuotaBody';
import type { CompatibleQuotaResult } from '@/services/api/vibeproxy';
import { isQuotaTabId } from '@/features/quota/uiState';

beforeAll(async () => {
  await i18n.changeLanguage('en');
});
const result: CompatibleQuotaResult = {
  credential: {
    id: 'fixture',
    providerName: 'Ollama Cloud',
    keyNumber: 1,
    enabled: true,
    supported: true,
    scope: 'account',
  },
  status: 'success',
  windows: [{ id: 'monthly', usedPercent: 75, remainingPercent: 25, resetAt: null }],
  balances: [],
  fetchedAt: null,
};
const render = (value: CompatibleQuotaResult) =>
  renderToStaticMarkup(createElement(CompatibleQuotaBody, { result: value, classes: {} }));

describe('compatible quota display', () => {
  test('shows remaining rather than used capacity and labels missing dollar/reset data', () => {
    const markup = render(result);
    expect(markup).toContain('25% remaining');
    expect(markup).toContain('75% used');
    expect(markup).toContain('aria-valuenow="25"');
    expect(markup).toContain('Account allowance');
    expect(markup).toContain('Dollar balance not reported');
    expect(markup).toContain('Reset time not reported');
    expect(markup).not.toContain('$0');
  });
  test('renders zero key budget as a real currency value', () => {
    const markup = render({
      ...result,
      credential: { ...result.credential, scope: 'key' },
      windows: [],
      balances: [{ id: 'key_remaining', amount: 0, currency: 'USD' }],
    });
    expect(markup).toContain('Key budget remaining');
    expect(markup).toContain('$0.00');
    expect(markup).not.toContain('Dollar balance not reported');
  });
  test.each(['error', 'unsupported', 'disabled', 'unavailable'] as const)(
    'does not display old quota after %s',
    (status) => {
      const markup = render({ ...result, status });
      expect(markup).not.toContain('25% remaining');
      expect(markup).not.toContain('progressbar');
    }
  );
  test('compatible provider filter is a valid saved tab', () => {
    expect(isQuotaTabId('compatible')).toBe(true);
  });
  test.each(['en', 'zh-CN', 'zh-TW', 'ru'])(
    'translated meter labels exist in %s',
    async (language) => {
      await i18n.changeLanguage(language);
      try {
        expect(render(result)).not.toContain('compatible_quota.');
      } finally {
        await i18n.changeLanguage('en');
      }
    }
  );
});
