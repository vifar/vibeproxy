import { useTranslation } from 'react-i18next';
import { Button } from '@/components/ui/Button';
import { IconRefreshCw } from '@/components/ui/icons';
import type { CompatibleQuotaCredential, CompatibleQuotaResult } from '@/services/api/vibeproxy';
import { CompatibleQuotaBody } from './CompatibleQuotaBody';
import styles from './CompatibleQuotaSection.module.scss';

export function CompatibleQuotaSection({
  credentials,
  results,
  error,
  loading,
  search,
  disabled,
  ledger,
  onRefresh,
}: {
  credentials: CompatibleQuotaCredential[];
  results: Record<string, CompatibleQuotaResult>;
  error: boolean;
  loading: boolean;
  search: string;
  disabled: boolean;
  ledger: boolean;
  onRefresh: (credential: CompatibleQuotaCredential) => void;
}) {
  const { t } = useTranslation();
  const query = search.trim().toLowerCase();
  const filtered = credentials.filter((credential) =>
    `${credential.providerName} ${t('compatible_quota.credential', { number: credential.keyNumber })}`
      .toLowerCase()
      .includes(query)
  );
  return (
    <section className={styles.section} aria-label={t('compatible_quota.title')}>
      <h2 className={styles.title}>
        {t('compatible_quota.title')} <span>{credentials.length}</span>
      </h2>
      {error && (
        <p className={styles.message} role="alert">
          {t('compatible_quota.helper_unavailable')}
        </p>
      )}
      {!error && credentials.length === 0 && (
        <p className={styles.message}>{t(loading ? 'common.loading' : 'compatible_quota.empty')}</p>
      )}
      {!error && credentials.length > 0 && filtered.length === 0 && (
        <p className={styles.message}>{t('quota_management.search_empty_title')}</p>
      )}
      <div className={ledger ? styles.ledger : styles.cards}>
        {filtered.map((credential) => {
          const result = results[credential.id];
          return (
            <article className={ledger ? styles.row : styles.card} key={credential.id}>
              <div className={styles.identity}>
                <h3>{credential.providerName}</h3>
                <span>{t('compatible_quota.credential', { number: credential.keyNumber })}</span>
                <span>{t(`compatible_quota.scope_label_${credential.scope}`)}</span>
              </div>
              <CompatibleQuotaBody result={result} classes={styles} />
              <Button
                variant="ghost"
                size="sm"
                disabled={
                  disabled ||
                  !credential.enabled ||
                  !credential.supported ||
                  result?.status === 'loading'
                }
                aria-label={t('compatible_quota.refresh_credential', {
                  provider: credential.providerName,
                  number: credential.keyNumber,
                })}
                onClick={() => onRefresh(credential)}
              >
                <IconRefreshCw size={14} /> {t('compatible_quota.refresh')}
              </Button>
            </article>
          );
        })}
      </div>
    </section>
  );
}
