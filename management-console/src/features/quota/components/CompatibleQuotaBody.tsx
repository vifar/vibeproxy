import { useTranslation } from 'react-i18next';
import type { CompatibleQuotaResult } from '@/services/api/vibeproxy';

export function CompatibleQuotaBody({
  result,
  classes,
}: {
  result?: CompatibleQuotaResult;
  classes: Record<string, string>;
}) {
  const { t, i18n } = useTranslation();
  if (!result || result.status === 'loading') {
    return (
      <p className={classes.message} role="status">
        {t('common.loading')}
      </p>
    );
  }
  if (result.status !== 'success') {
    return (
      <p className={classes.message} role={result.status === 'error' ? 'alert' : undefined}>
        {t(`compatible_quota.${result.status}`)}
        {result.httpStatus ? ` (HTTP ${result.httpStatus})` : ''}
      </p>
    );
  }
  const formatNumber = (value: number) =>
    new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 1 }).format(value);
  const date = (value: string) => new Date(value).toLocaleString(i18n.language);
  const hasRemainingBalance = result.balances.some((balance) => balance.id === 'key_remaining');

  return (
    <div className={classes.body}>
      <div className={classes.windows}>
        {result.windows.map((window) => (
          <div key={window.id} className={classes.window}>
            <div className={classes.meterHeading}>
              <span>{t(`compatible_quota.window_${window.id}`)}</span>
              <strong>
                {t('compatible_quota.remaining', { value: formatNumber(window.remainingPercent) })}
              </strong>
            </div>
            <div
              className={classes.track}
              role="progressbar"
              aria-label={t(`compatible_quota.window_${window.id}`)}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={window.remainingPercent}
              aria-valuetext={t('compatible_quota.remaining', {
                value: formatNumber(window.remainingPercent),
              })}
            >
              <span
                className={classes.fill}
                data-level={
                  window.remainingPercent < 30
                    ? 'low'
                    : window.remainingPercent < 70
                      ? 'medium'
                      : 'high'
                }
                style={{ width: `${Math.min(100, window.remainingPercent)}%` }}
              />
            </div>
            <span className={classes.hint}>
              {t('compatible_quota.used', { value: formatNumber(window.usedPercent) })}
              {' · '}
              {window.resetAt
                ? t('compatible_quota.resets', { time: date(window.resetAt) })
                : t('compatible_quota.reset_unreported')}
            </span>
          </div>
        ))}
      </div>
      {result.balances.length > 0 && (
        <dl className={classes.balances}>
          {result.balances.map((balance) => (
            <div key={balance.id}>
              <dt>{t(`compatible_quota.${balance.id}`)}</dt>
              <dd>
                {new Intl.NumberFormat(i18n.language, {
                  style: 'currency',
                  currency: balance.currency,
                  maximumFractionDigits: 4,
                }).format(balance.amount)}
              </dd>
            </div>
          ))}
        </dl>
      )}
      <p className={classes.hint}>
        {t(`compatible_quota.scope_${result.credential.scope}`)}
        {!hasRemainingBalance && ` ${t('compatible_quota.balance_unreported')}`}
      </p>
      {result.fetchedAt && (
        <time className={classes.hint} dateTime={result.fetchedAt}>
          {t('compatible_quota.updated', { time: date(result.fetchedAt) })}
        </time>
      )}
    </div>
  );
}
