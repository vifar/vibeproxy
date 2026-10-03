import { useTranslation } from 'react-i18next';
import type { ResolvedTheme } from '@/types';
import { useNow } from '@/hooks/useNow';
import { buildResetDisplay } from '@/utils/quota';
import { getAuthFileIcon, getTypeLabel } from '@/features/authFiles/constants';
import { QUOTA_TAB_ORDER } from '../constants';
import type { QuotaFileEntry } from '../logic';
import type { QuotaCardState } from '../providers';
import { summarizeQuotaEntries } from '../ledger';
import styles from './QuotaSummary.module.scss';

interface QuotaSummaryProps {
  entries: QuotaFileEntry[];
  quotaFor: (entry: QuotaFileEntry) => QuotaCardState | undefined;
  resolvedTheme: ResolvedTheme;
}

export function QuotaSummary({ entries, quotaFor, resolvedTheme }: QuotaSummaryProps) {
  const { t, i18n } = useTranslation();
  const now = useNow();
  const groups = QUOTA_TAB_ORDER.map((type) => ({
    type,
    entries: entries.filter((entry) => entry.type === type),
  })).filter((group) => group.entries.length > 0);
  if (!groups.length) return null;

  return (
    <section className={styles.summary} aria-label={t('quota_management.provider_summary')}>
      {groups.map((group) => {
        const summary = summarizeQuotaEntries(group.entries, quotaFor);
        const reset = buildResetDisplay(null, summary.resetAtMs, now, i18n.resolvedLanguage);
        const icon = getAuthFileIcon(group.type, resolvedTheme);
        return (
          <article className={styles.provider} key={group.type}>
            <header className={styles.header}>
              <span className={styles.name}>
                {icon && <img src={icon} alt="" />}
                {getTypeLabel(t, group.type)}
              </span>
              <span className={styles.count}>
                {t('quota_management.meta_credentials', { count: group.entries.length })}
              </span>
            </header>
            <p className={styles.label}>
              {summary.periodHours === 168
                ? t('quota_management.weekly_limit')
                : summary.periodHours !== null
                  ? t('quota_management.hour_limit', { count: summary.periodHours })
                  : t('quota_management.remaining_quota')}
            </p>
            <p className={styles.value}>
              <strong>{summary.total === null ? '--' : `${Math.round(summary.total)}%`}</strong>
              {summary.knownCount > 0 && (
                <span>{t('quota_management.of_capacity', { capacity: summary.capacity })}</span>
              )}
            </p>
            <div className={styles.segments} aria-hidden="true">
              {summary.segments.map((percent, index) => (
                <span className={styles.track} key={index}>
                  <span
                    className={
                      percent !== null && percent < 30
                        ? styles.low
                        : percent !== null && percent < 70
                          ? styles.medium
                          : styles.high
                    }
                    style={{ width: `${percent ?? 0}%` }}
                  />
                </span>
              ))}
            </div>
            <p className={styles.reset}>
              {reset
                ? `${reset.relative ?? ''} · ${reset.absolute}`
                : t('quota_management.summary_pending')}
            </p>
            <p className={styles.coverage}>
              {t('quota_management.summary_coverage', {
                known: summary.knownCount,
                total: group.entries.length,
              })}
            </p>
          </article>
        );
      })}
    </section>
  );
}
