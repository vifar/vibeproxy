import type { CodexCreditBalance } from '@/types';
import { normalizeNumberValue } from './parsers';

/** Keep only supported credit fields; missing values never become a zero balance. */
export function normalizeCodexCreditBalance(value: unknown): CodexCreditBalance | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const hasCredits = record.has_credits ?? record.hasCredits;
  const unlimited = record.unlimited;
  const balance = normalizeNumberValue(record.balance);
  if (typeof hasCredits !== 'boolean' && typeof unlimited !== 'boolean' && balance === null) {
    return null;
  }
  return {
    hasCredits: typeof hasCredits === 'boolean' ? hasCredits : null,
    unlimited: typeof unlimited === 'boolean' ? unlimited : null,
    balance,
  };
}

/** Billing caps are spend allowances in cents, rather than Codex credit units. */
export function formatCreditBudget(limit: unknown, used: unknown, locale?: string) {
  const limitCents = normalizeNumberValue(limit);
  const usedCents = normalizeNumberValue(used);
  const format = (cents: number | null) =>
    cents === null
      ? null
      : new Intl.NumberFormat(locale, { style: 'currency', currency: 'USD' }).format(cents / 100);
  return {
    remaining:
      limitCents !== null && usedCents !== null
        ? format(Math.max(0, limitCents - usedCents))
        : null,
    limit: format(limitCents),
    used: format(usedCents),
  };
}
