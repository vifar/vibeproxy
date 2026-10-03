import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import {
  IconAlertTriangle,
  IconCheckCircle2,
  IconEye,
  IconPencil,
  IconTrash2,
  IconSettings,
} from '@/components/ui/icons';
import { ToggleSwitch } from '@/components/ui/ToggleSwitch';
import { ProviderStatusBar } from '@/components/providers/ProviderStatusBar';
import {
  getOpenAIProviderRecentStatusData,
  getOpenAIProviderTotalStats,
  getProviderRecentStatusData,
  getProviderTotalStats,
  getProviderUsageKey,
  type ProviderRecentUsageMap,
} from '@/components/providers/utils';
import type { OpenAIProviderConfig } from '@/types';
import type { StatusBarData } from '@/utils/recentRequests';
import type { ProviderResource } from '../types';
import { isMultiProtocolSponsorBrand } from '../sponsorDefinitions';
import styles from './ProviderResourceTable.module.scss';
import statusBarStyles from './providerStatusBar.module.scss';

interface ProviderResourceTableProps {
  resources: ProviderResource[];
  selectedId?: string | null;
  disableMutations?: boolean;
  usageByProvider?: ProviderRecentUsageMap;
  onView: (resource: ProviderResource) => void;
  onEdit: (resource: ProviderResource) => void;
  onModels?: (resource: ProviderResource) => void;
  onDelete: (resource: ProviderResource) => void;
  onToggleDisabled?: (resource: ProviderResource, disabled: boolean) => void;
}

const isSponsorResource = (resource: ProviderResource): boolean =>
  isMultiProtocolSponsorBrand(resource.brand);

const resolveStatusBarData = (
  resource: ProviderResource,
  usageByProvider: ProviderRecentUsageMap
): StatusBarData => {
  if (resource.brand === 'openaiCompatibility') {
    return getOpenAIProviderRecentStatusData(resource.raw as OpenAIProviderConfig, usageByProvider);
  }
  return getProviderRecentStatusData(
    usageByProvider,
    getProviderUsageKey(resource.brand),
    resource.apiKey ?? undefined,
    resource.baseUrl ?? undefined
  );
};

const resolveTotalStats = (
  resource: ProviderResource,
  usageByProvider: ProviderRecentUsageMap
): { success: number; failure: number } => {
  if (resource.brand === 'openaiCompatibility') {
    return getOpenAIProviderTotalStats(resource.raw as OpenAIProviderConfig, usageByProvider);
  }
  return getProviderTotalStats(
    usageByProvider,
    getProviderUsageKey(resource.brand),
    resource.apiKey ?? undefined,
    resource.baseUrl ?? undefined
  );
};

export function ProviderResourceTable({
  resources,
  selectedId,
  disableMutations,
  usageByProvider,
  onView,
  onEdit,
  onModels,
  onDelete,
  onToggleDisabled,
}: ProviderResourceTableProps) {
  const { t, i18n } = useTranslation();

  const renderMetric = (key: string, label: string, value: number) => (
    <span key={key} className={styles.metric}>
      <span className={styles.metricLabel}>{label}</span>
      <span className={styles.metricValue}>{value}</span>
    </span>
  );

  const renderFlagTag = (key: string, label: string) => (
    <span key={key} className={styles.flagTag}>
      {label}
    </span>
  );

  const renderProtocolSummary = (r: ProviderResource) =>
    (r.flags.protocols ?? [])
      .map((protocol) => t(`providersPage.sponsor.protocols.${protocol}`))
      .join(' / ');

  const renderModelsSummary = (r: ProviderResource) => {
    const items: ReactNode[] = [];
    if (isSponsorResource(r)) {
      (r.flags.protocols ?? []).forEach((protocol) => {
        items.push(renderFlagTag(protocol, t(`providersPage.sponsor.protocols.${protocol}`)));
      });
      return <div className={styles.metricsCell}>{items}</div>;
    }
    if (r.brand === 'openaiCompatibility') {
      items.push(
        ...(!onModels
          ? [renderMetric('models', t('providersPage.table.metrics.models'), r.modelCount)]
          : []),
        renderMetric('keys', t('providersPage.table.metrics.keys'), r.apiKeyEntryCount),
        ...(r.headerCount
          ? [renderMetric('headers', t('providersPage.table.metrics.headers'), r.headerCount)]
          : [])
      );
    } else {
      items.push(
        ...(!onModels
          ? [renderMetric('models', t('providersPage.table.metrics.models'), r.modelCount)]
          : []),
        ...(r.headerCount
          ? [renderMetric('headers', t('providersPage.table.metrics.headers'), r.headerCount)]
          : [])
      );
      if ((r.brand === 'codex' || r.brand === 'xai') && r.flags.websockets) {
        items.push(renderFlagTag('ws', t('providersPage.table.websocketsTag')));
      }
      if (r.brand === 'claude' && r.flags.cloakEnabled) {
        items.push(renderFlagTag('cloak', t('providersPage.table.cloakTag')));
      }
      if (r.brand === 'claude' && r.flags.claudeCodeCliProfile) {
        items.push(renderFlagTag('cli-profile', t('providersPage.table.cliProfileTag')));
      }
    }
    return <div className={styles.metricsCell}>{items}</div>;
  };

  const renderStatus = (r: ProviderResource) => {
    if (r.disabled) {
      return (
        <span className={`${styles.statusBadge} ${styles.statusDisabled}`}>
          <IconAlertTriangle size={14} />
          {t('providersPage.status.disabled')}
        </span>
      );
    }
    return (
      <span className={`${styles.statusBadge} ${styles.statusActive}`}>
        <IconCheckCircle2 size={14} />
        {t('providersPage.status.active')}
      </span>
    );
  };

  const renderPrimary = (r: ProviderResource) => {
    if (isSponsorResource(r)) {
      return (
        <div className={styles.primaryCell}>
          <span className={styles.primaryName}>{r.name ?? r.identifier}</span>
          <span className={styles.primarySub}>
            {r.apiKeyPreview ?? t('providersPage.status.notConfigured')}
          </span>
        </div>
      );
    }
    if (r.brand === 'openaiCompatibility') {
      const extra = r.apiKeyEntryCount > 1 ? ` · +${r.apiKeyEntryCount - 1}` : '';
      return (
        <div className={styles.primaryCell}>
          <span className={styles.primaryName}>{r.name ?? r.identifier}</span>
          <span className={styles.primarySub}>{(r.apiKeyPreview ?? '—') + extra}</span>
        </div>
      );
    }
    return (
      <div className={styles.primaryCell}>
        <span className={styles.primaryName}>{r.apiKeyPreview ?? '—'}</span>
        {r.authIndex ? <span className={styles.primarySub}>auth: {r.authIndex}</span> : null}
      </div>
    );
  };

  const renderBaseUrl = (r: ProviderResource) => {
    if (isSponsorResource(r)) {
      return <span className={styles.baseUrl}>{renderProtocolSummary(r)}</span>;
    }
    if (r.brand === 'claude' && !r.baseUrl) {
      return (
        <span className={styles.baseUrl}>
          https://api.anthropic.com {t('providersPage.status.defaultSuffix')}
        </span>
      );
    }
    return <span className={styles.baseUrl}>{r.baseUrl ?? t('providersPage.status.notSet')}</span>;
  };

  return (
    <div className={styles.resourceList}>
      <div className={styles.listHeader} aria-hidden="true">
        <span>{t('vibeproxy.providerLabel')}</span>
        <span>{t('providersPage.table.status')}</span>
        <span>{t('providersPage.table.actions')}</span>
      </div>
      {resources.map((resource) => {
        const stats =
          usageByProvider && !isSponsorResource(resource)
            ? resolveTotalStats(resource, usageByProvider)
            : null;
        return (
          <article
            key={resource.id}
            className={`${styles.resource} ${resource.id === selectedId ? styles.resourceSelected : ''}`}
            aria-label={resource.name ?? resource.apiKeyPreview ?? resource.identifier}
          >
            <div className={styles.identity}>
              {renderPrimary(resource)}
              <div className={styles.endpoint}>
                <span className={styles.fieldLabel}>{t('providersPage.table.baseUrl')}</span>
                {renderBaseUrl(resource)}
              </div>
              <div className={styles.configuration}>
                {onModels && !isSponsorResource(resource) ? (
                  <button
                    type="button"
                    className={styles.modelsButton}
                    disabled={disableMutations}
                    onClick={() => onModels(resource)}
                  >
                    <IconSettings size={14} />
                    {t('providersPage.table.metrics.models')} <strong>{resource.modelCount}</strong>
                  </button>
                ) : null}
                {renderModelsSummary(resource)}
                {resource.prefix && (
                  <span className={styles.chip}>
                    {t('providersPage.table.prefix')}: {resource.prefix}
                  </span>
                )}
              </div>
            </div>
            <div className={styles.statusCell}>
              <div className={styles.statusTop}>
                {renderStatus(resource)}
                {onToggleDisabled && (
                  <ToggleSwitch
                    checked={!resource.disabled}
                    disabled={disableMutations}
                    onChange={(value) => onToggleDisabled(resource, !value)}
                    ariaLabel={
                      resource.disabled
                        ? t('providersPage.actions.enable')
                        : t('providersPage.actions.disable')
                    }
                  />
                )}
              </div>
              {stats && (
                <>
                  <dl className={styles.stats}>
                    <div>
                      <dt>{t('stats.success')}</dt>
                      <dd className={styles.statSuccess}>
                        {stats.success.toLocaleString(i18n.language)}
                      </dd>
                    </div>
                    <div>
                      <dt>{t('stats.failure')}</dt>
                      <dd className={styles.statFailure}>
                        {stats.failure.toLocaleString(i18n.language)}
                      </dd>
                    </div>
                  </dl>
                  <div className={styles.statusBarWrap}>
                    <ProviderStatusBar
                      statusData={resolveStatusBarData(resource, usageByProvider!)}
                      styles={statusBarStyles}
                    />
                  </div>
                </>
              )}
            </div>
            <div className={styles.actions}>
              <button
                type="button"
                className={styles.actionButton}
                onClick={() => onView(resource)}
              >
                <IconEye size={15} /> {t('providersPage.actions.view')}
              </button>
              <button
                type="button"
                className={styles.actionButton}
                disabled={disableMutations}
                onClick={() => onEdit(resource)}
              >
                <IconPencil size={15} /> {t('providersPage.actions.edit')}
              </button>
              <button
                type="button"
                className={`${styles.actionButton} ${styles.deleteButton}`}
                disabled={disableMutations}
                aria-label={t('providersPage.actions.delete')}
                title={t('providersPage.actions.delete')}
                onClick={() => onDelete(resource)}
              >
                <IconTrash2 size={15} />
              </button>
            </div>
          </article>
        );
      })}
    </div>
  );
}
