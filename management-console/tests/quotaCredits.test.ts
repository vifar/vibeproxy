import { beforeAll, describe, expect, test } from 'bun:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import i18n from '@/i18n';
import { CodexQuotaBody } from '@/features/quota/providers/codex/CodexQuotaBody';
import { ClaudeQuotaBody } from '@/features/quota/providers/claude/ClaudeQuotaBody';
import { XaiQuotaBody } from '@/features/quota/providers/xai/XaiQuotaBody';
import { QUOTA_CLASS_KEYS, bindQuotaClasses } from '@/features/quota/types';
import { formatCreditBudget, normalizeCodexCreditBalance } from '@/utils/quota';
import type { CodexQuotaState } from '@/types';

const classes = bindQuotaClasses(
  Object.fromEntries(QUOTA_CLASS_KEYS.map((key) => [key, key])),
  'test-host'
);
const renderCodex = (credits?: CodexQuotaState['credits']) =>
  renderToStaticMarkup(
    createElement(CodexQuotaBody, {
      classes,
      quota: { status: 'success', windows: [], credits, rateLimitResetCreditsAvailableCount: 0 },
    })
  );

beforeAll(async () => {
  await i18n.changeLanguage('en');
});

describe('per-credential credits', () => {
  test('normalizes live Codex credit units without retaining unrelated fields', () => {
    expect(
      normalizeCodexCreditBalance({
        has_credits: true,
        unlimited: false,
        balance: '12345.6789000000',
        private_field: 'fixture',
      })
    ).toEqual({
      hasCredits: true,
      unlimited: false,
      balance: 12345.6789,
    });
    expect(
      normalizeCodexCreditBalance({ hasCredits: false, unlimited: false, balance: '0' })?.balance
    ).toBe(0);
    expect(normalizeCodexCreditBalance({ balance: 'NaN' })).toBeNull();
    expect(normalizeCodexCreditBalance(null)).toBeNull();
  });

  test('distinguishes finite, unlimited, hidden, zero and missing balances', () => {
    const markup = renderCodex({ hasCredits: true, unlimited: false, balance: 12345.6789 });
    expect(markup).toContain('12,345.68');
    expect(markup).toContain('Credit balance');
    expect(markup).toContain('Manual resets');
    expect(renderCodex({ hasCredits: true, unlimited: true, balance: null })).toContain(
      'Unlimited'
    );
    expect(renderCodex({ hasCredits: true, unlimited: false, balance: null })).toContain(
      'Available'
    );
    expect(renderCodex({ hasCredits: false, unlimited: false, balance: 0 })).toContain('>0</dd>');
    expect(renderCodex()).toContain('Not reported');
    expect(renderCodex({ hasCredits: false, unlimited: false, balance: -1.25 })).toContain('-1.25');
  });

  test('does not infer a spend allowance from a missing cap or used amount', () => {
    expect(formatCreditBudget(15000, 3000, 'en').remaining).toBe('$120.00');
    expect(formatCreditBudget(15000, null, 'en').remaining).toBeNull();
    expect(formatCreditBudget(null, 0, 'en').remaining).toBeNull();
    expect(formatCreditBudget(100, 200, 'en').remaining).toBe('$0.00');
  });

  test('shows Claude remaining extra usage and monthly spending per credential', () => {
    const render = (
      extraUsage: {
        is_enabled: boolean;
        monthly_limit: number;
        used_credits: number;
        utilization: null;
      } | null
    ) =>
      renderToStaticMarkup(
        createElement(ClaudeQuotaBody, {
          classes,
          quota: { status: 'success', windows: [], extraUsage },
        })
      );
    const markup = render({
      is_enabled: true,
      monthly_limit: 5000,
      used_credits: 1250,
      utilization: null,
    });
    expect(markup).toContain('$37.50 remaining');
    expect(markup).toContain('Used $12.50 of $50.00');
    expect(render(null)).toContain('Not reported');
    expect(
      render({ is_enabled: false, monthly_limit: 0, used_credits: 0, utilization: null })
    ).toContain('Disabled');
  });

  test('does not fabricate xAI credits when only paid service health is available', () => {
    const markup = renderToStaticMarkup(
      createElement(XaiQuotaBody, {
        classes,
        quota: {
          status: 'success',
          billing: {
            mode: 'paid-health',
            periodType: 'unknown',
            usagePercent: null,
            productUsage: [],
            monthlyLimitCents: null,
            usedCents: null,
            includedUsedCents: null,
            onDemandCapCents: null,
            onDemandUsedCents: null,
            onDemandUsedPercent: null,
            usedPercent: null,
          },
        },
      })
    );
    expect(markup).toContain('Not reported');
    expect(markup).not.toContain('$0.00');
  });
});
