/**
 * xAI 额度渲染体：套餐 chip 行（SuperGrok Heavy / 付费档=金卡）、
 * 周/月账单水位条、按量付费余额。
 */

import { useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import type { XaiQuotaState } from '@/types';
import {
  buildResetDisplay,
  formatCreditBudget,
  formatQuotaResetTime,
  parseIsoToMs,
} from '@/utils/quota';
import { useNow } from '@/hooks/useNow';
import { QuotaMeter } from '../../components/QuotaMeter';
import { QuotaCreditDetails } from '../../components/QuotaCreditDetails';
import { QuotaResetLabel } from '../../components/QuotaResetLabel';
import { XAI_WEEKLY_ROW_ID, collectQuotaRowInstants, pickUrgentRowId } from '../../resetSchedule';
import type { QuotaBodyProps } from '../../types';

const formatXaiPercent = (value: number | null): string => {
  if (value === null) return '--';
  return `${Math.round(value)}%`;
};

const XAI_SUPERGROK_LIMIT_CENTS = 15_000;
const XAI_SUPERGROK_HEAVY_LIMIT_CENTS = 150_000;

const resolveXaiPlan = (
  monthlyLimitCents: number | null
): { labelKey: string; premium: boolean } | null => {
  if (monthlyLimitCents === XAI_SUPERGROK_LIMIT_CENTS) {
    return { labelKey: 'plan_supergrok', premium: false };
  }
  if (monthlyLimitCents === XAI_SUPERGROK_HEAVY_LIMIT_CENTS) {
    return { labelKey: 'plan_supergrok_heavy', premium: true };
  }
  return null;
};

export function XaiQuotaBody({ quota, classes }: QuotaBodyProps<XaiQuotaState>) {
  const { t, i18n } = useTranslation();
  // Ahead of the early return below — hooks cannot be conditional.
  const now = useNow();
  const locale = i18n.resolvedLanguage;
  // Only the weekly limit is a quota window; the monthly figure is a billing
  // cycle, so it is never the row that "recovers first".
  const weeklySoon = useMemo(
    () => pickUrgentRowId(collectQuotaRowInstants('xai', quota), now) === XAI_WEEKLY_ROW_ID,
    [quota, now]
  );
  const billing = quota.billing;

  if (!billing) {
    return <div className={classes.quotaMessage}>{t('xai_quota.empty_data')}</div>;
  }

  if (billing.mode === 'paid-health') {
    return (
      <>
        <div className={classes.codexPlan}>
          <span className={classes.codexPlanLabel}>{t('xai_quota.plan_label')}</span>
          <span className={classes.premiumPlanValue}>{t('xai_quota.plan_paid')}</span>
        </div>
        <div className={classes.quotaMessage}>{t('xai_quota.paid_health')}</div>
        <QuotaCreditDetails
          classes={classes}
          items={[
            {
              label: t('quota_management.credit_balance'),
              value: t('quota_management.credits_not_reported'),
            },
          ]}
        />
      </>
    );
  }

  const clampedUsed =
    billing.usedPercent === null ? null : Math.max(0, Math.min(100, billing.usedPercent));
  const remaining = clampedUsed === null ? null : Math.max(0, Math.min(100, 100 - clampedUsed));
  const percentLabel = formatXaiPercent(remaining);
  const monthlyBudget = formatCreditBudget(
    billing.monthlyLimitCents,
    billing.includedUsedCents,
    locale
  );
  const onDemandBudget = formatCreditBudget(
    billing.onDemandCapCents,
    billing.onDemandUsedCents,
    locale
  );
  const resetLabel = formatQuotaResetTime(billing.billingPeriodEnd);
  // The monthly row is a billing cycle, so it carries no resetAtMs (that field
  // is derived from periodEnd, the weekly quota window). Parse for the
  // countdown; the summary keeps the two periods deliberately distinct.
  const monthlyResetDisplay = buildResetDisplay(
    resetLabel,
    parseIsoToMs(billing.billingPeriodEnd),
    now,
    locale
  );
  const onDemandCap = billing.onDemandCapCents ?? 0;
  const clampedOnDemandUsed =
    billing.onDemandUsedPercent === null
      ? null
      : Math.max(0, Math.min(100, billing.onDemandUsedPercent));
  const onDemandRemaining =
    clampedOnDemandUsed === null ? null : Math.max(0, Math.min(100, 100 - clampedOnDemandUsed));
  const onDemandPercentLabel = formatXaiPercent(onDemandRemaining);
  const plan = resolveXaiPlan(billing.monthlyLimitCents);
  const weeklyUsed =
    billing.periodType === 'weekly' && billing.usagePercent !== null
      ? Math.max(0, Math.min(100, billing.usagePercent))
      : null;
  const weeklyRemaining = weeklyUsed === null ? null : Math.max(0, Math.min(100, 100 - weeklyUsed));
  const weeklyResetLabel = formatQuotaResetTime(billing.periodEnd);
  const weeklyResetDisplay = buildResetDisplay(
    weeklyResetLabel === '-' ? null : t('xai_quota.reset_at', { time: weeklyResetLabel }),
    billing.resetAtMs,
    now,
    locale
  );
  const hasWeeklyData =
    billing.periodType === 'weekly' &&
    (weeklyUsed !== null || Boolean(billing.periodEnd) || billing.productUsage.length > 0);
  const hasMonthlyData =
    (billing.monthlyLimitCents !== null ||
      billing.usedCents !== null ||
      Boolean(billing.billingPeriodEnd)) &&
    !(hasWeeklyData && billing.monthlyLimitCents === 0 && billing.usedCents === 0);
  const budgetHint = (budget: ReturnType<typeof formatCreditBudget>) =>
    budget.used !== null || budget.limit !== null
      ? t('quota_management.credits_budget', {
          used: budget.used ?? t('quota_management.credits_not_reported'),
          limit: budget.limit ?? t('quota_management.credits_not_reported'),
        })
      : undefined;

  return (
    <>
      {plan && (
        <div className={classes.codexPlan}>
          <span className={classes.codexPlanLabel}>{t('xai_quota.plan_label')}</span>
          <span className={plan.premium ? classes.premiumPlanValue : classes.codexPlanValue}>
            {t(`xai_quota.${plan.labelKey}`)}
          </span>
        </div>
      )}
      {hasWeeklyData && (
        <div
          className={classes.quotaRow}
          title={weeklySoon ? t('quota_management.soonest_row_hint') : undefined}
        >
          <div className={classes.quotaRowHeader}>
            <span className={classes.quotaModel}>{t('xai_quota.weekly_limit')}</span>
            <div className={classes.quotaMeta}>
              <span className={classes.quotaPercent}>
                {weeklyUsed === null
                  ? t('xai_quota.usage_unavailable')
                  : t('xai_quota.used_percent', { percent: formatXaiPercent(weeklyUsed) })}
              </span>
              {weeklyResetDisplay && (
                <QuotaResetLabel display={weeklyResetDisplay} classes={classes} soon={weeklySoon} />
              )}
            </div>
          </div>
          {weeklyRemaining !== null && (
            <QuotaMeter percent={weeklyRemaining} classes={classes} index={0} />
          )}
        </div>
      )}
      {billing.productUsage.map((item, index) => {
        const used =
          item.usagePercent === null ? null : Math.max(0, Math.min(100, item.usagePercent));
        const remainingPercent = used === null ? null : Math.max(0, Math.min(100, 100 - used));
        return (
          <div key={`product-${item.product}`} className={classes.quotaRow}>
            <div className={classes.quotaRowHeader}>
              <span className={classes.quotaModel}>
                {t('xai_quota.product_usage', { product: item.product })}
              </span>
              <div className={classes.quotaMeta}>
                <span className={classes.quotaPercent}>
                  {t('xai_quota.used_percent', {
                    percent: formatXaiPercent(used),
                  })}
                </span>
              </div>
            </div>
            <QuotaMeter percent={remainingPercent} classes={classes} index={index + 1} />
          </div>
        );
      })}
      {onDemandCap > 0 ? (
        <div className={classes.quotaRow}>
          <div className={classes.quotaRowHeader}>
            <span className={classes.quotaModel}>{t('xai_quota.pay_as_you_go_label')}</span>
            <div className={classes.quotaMeta}>
              <span className={classes.quotaPercent}>{onDemandPercentLabel}</span>
            </div>
          </div>
          <QuotaMeter
            percent={onDemandRemaining}
            classes={classes}
            index={billing.productUsage.length + 1}
          />
        </div>
      ) : null}
      {hasMonthlyData && (
        <div className={classes.quotaRow}>
          <div className={classes.quotaRowHeader}>
            <span className={classes.quotaModel}>{t('xai_quota.monthly_credits')}</span>
            <div className={classes.quotaMeta}>
              <span className={classes.quotaPercent}>{percentLabel}</span>
              {monthlyResetDisplay && (
                <QuotaResetLabel display={monthlyResetDisplay} classes={classes} />
              )}
            </div>
          </div>
          <QuotaMeter
            percent={remaining}
            classes={classes}
            index={billing.productUsage.length + 2}
          />
        </div>
      )}
      <QuotaCreditDetails
        classes={classes}
        items={[
          ...(hasMonthlyData
            ? [
                {
                  label: t('xai_quota.monthly_credits'),
                  value:
                    monthlyBudget.remaining === null
                      ? t('quota_management.credits_not_reported')
                      : t('quota_management.credits_remaining', {
                          amount: monthlyBudget.remaining,
                        }),
                  hint: budgetHint(monthlyBudget),
                },
              ]
            : []),
          {
            label: t('xai_quota.pay_as_you_go_label'),
            value:
              billing.onDemandCapCents === 0
                ? t('xai_quota.pay_as_you_go_disabled')
                : onDemandBudget.remaining === null
                  ? t('quota_management.credits_not_reported')
                  : t('quota_management.credits_remaining', { amount: onDemandBudget.remaining }),
            hint: billing.onDemandCapCents === 0 ? undefined : budgetHint(onDemandBudget),
          },
        ]}
      />
    </>
  );
}
