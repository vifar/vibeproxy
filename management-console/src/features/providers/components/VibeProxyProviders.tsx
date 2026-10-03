import { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/Button';
import { Modal } from '@/components/ui/Modal';
import { SelectionCheckbox } from '@/components/ui/SelectionCheckbox';
import { IconRefreshCw, IconSearch, IconSettings } from '@/components/ui/icons';
import { vibeproxyApi, type VibeProxyProvider } from '@/services/api/vibeproxy';
import { useAuthStore, useConfigStore, useNotificationStore } from '@/stores';
import styles from './VibeProxyProviders.module.scss';

export function VibeProxyProviders({
  onSaved,
  modelRequest,
}: {
  onSaved: () => void;
  modelRequest?: { id: string; version: number } | null;
}) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const apiBase = useAuthStore((state) => state.apiBase);
  const managementKey = useAuthStore((state) => state.managementKey);
  const connected = useAuthStore((state) => state.connectionStatus === 'connected');
  const notify = useNotificationStore((state) => state.showNotification);
  const [providers, setProviders] = useState<VibeProxyProvider[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [editing, setEditing] = useState<VibeProxyProvider | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [modelSearch, setModelSearch] = useState('');
  const [saving, setSaving] = useState(false);
  const requestID = useRef(0);
  const handledModelRequest = useRef(0);
  const session = useRef('');
  const sessionID = `${apiBase}|${managementKey}|${connected}`;

  const refresh = useCallback(async () => {
    const id = ++requestID.current;
    const connection = session.current;
    setLoading(true);
    setError('');
    try {
      const data = await vibeproxyApi.providers();
      if (id === requestID.current && connection === session.current) setProviders(data.providers);
    } catch (err) {
      if (id === requestID.current && connection === session.current) {
        setError(err instanceof Error ? err.message : String(err));
      }
    } finally {
      if (id === requestID.current && connection === session.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    session.current = sessionID;
    setProviders([]);
    setEditing(null);
    setSaving(false);
    if (connected) void refresh();
    return () => {
      requestID.current += 1;
    };
  }, [connected, sessionID, refresh]);

  useEffect(() => {
    if (!modelRequest || handledModelRequest.current === modelRequest.version) return;
    const provider = providers.find((item) => item.id === modelRequest.id);
    if (!provider) return;
    handledModelRequest.current = modelRequest.version;
    setEditing(provider);
    setSelected(new Set(provider.selected));
    setModelSearch('');
  }, [modelRequest, providers]);

  const save = async () => {
    if (!editing || saving) return;
    const connection = session.current;
    setSaving(true);
    try {
      await vibeproxyApi.saveModels(
        editing,
        editing.models.filter((id) => selected.has(id))
      );
      if (connection !== session.current) return;
      useConfigStore.getState().clearCache();
      notify(t('vibeproxy.modelsSaved'), 'success');
      setEditing(null);
      onSaved();
      await refresh();
    } catch (err) {
      if (connection === session.current) {
        notify(err instanceof Error ? err.message : String(err), 'error');
      }
    } finally {
      if (connection === session.current) setSaving(false);
    }
  };
  const visible = providers
    .filter((provider) =>
      `${provider.name} ${provider.id}`.toLowerCase().includes(search.toLowerCase())
    )
    .sort(
      (a, b) =>
        Number(Boolean(b.activeAccounts && b.enabled)) -
        Number(Boolean(a.activeAccounts && a.enabled))
    );
  const models =
    editing?.models.filter((id) => id.toLowerCase().includes(modelSearch.toLowerCase())) ?? [];

  return (
    <section className={styles.panel} aria-label={t('vibeproxy.title')}>
      <div className={styles.header}>
        <div>
          <h1>{t('vibeproxy.title')}</h1>
          <p>{t('vibeproxy.description')}</p>
        </div>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => void refresh()}
          disabled={loading || !connected}
        >
          <IconRefreshCw size={15} /> {t('vibeproxy.refresh')}
        </Button>
      </div>
      <label className={styles.search}>
        <IconSearch size={16} />
        <input
          type="search"
          aria-label={t('vibeproxy.searchProviders')}
          placeholder={t('vibeproxy.searchProviders')}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
      </label>
      {error && (
        <div className="error-box">
          {t('vibeproxy.unavailable')} {error}
        </div>
      )}
      {loading && !providers.length && <p className={styles.empty}>{t('common.loading')}</p>}
      <div className={styles.grid}>
        {visible.map((provider) => (
          <article key={provider.id} className={styles.card}>
            <div className={styles.cardHeader}>
              <h3>{provider.name}</h3>
              <span
                className={
                  provider.activeAccounts && provider.enabled ? styles.connected : styles.status
                }
              >
                {provider.activeAccounts && provider.enabled
                  ? t('vibeproxy.connected')
                  : t('vibeproxy.notConnected')}
              </span>
            </div>
            <p className={styles.kind}>{t(`vibeproxy.${provider.kind}`)}</p>
            <div className={styles.count}>
              <strong>{provider.selected.length}</strong>
              <span>{t('vibeproxy.ofModels', { total: provider.models.length })}</span>
            </div>
            <div className={styles.actions}>
              <Button
                variant="secondary"
                size="sm"
                disabled={!provider.models.length || !provider.canSave}
                onClick={() => {
                  setEditing(provider);
                  setSelected(new Set(provider.selected));
                  setModelSearch('');
                }}
              >
                <IconSettings size={14} /> {t('vibeproxy.selectModels')}
              </Button>
              {provider.accountCount > 0 ? (
                <button
                  type="button"
                  className={styles.link}
                  onClick={() => navigate('/auth-files')}
                >
                  {t('vibeproxy.accounts', { count: provider.accountCount })}
                </button>
              ) : (
                <span className={styles.hint}>{t('vibeproxy.connectDesktop')}</span>
              )}
            </div>
          </article>
        ))}
      </div>
      {!loading && !error && !visible.length && (
        <p className={styles.empty}>{t('vibeproxy.noProviders')}</p>
      )}
      <Modal
        open={Boolean(editing)}
        closeDisabled={saving}
        onClose={() => {
          if (!saving) setEditing(null);
        }}
        title={t('vibeproxy.modelTitle', { name: editing?.name ?? '' })}
        footer={
          <>
            <Button variant="secondary" onClick={() => setEditing(null)} disabled={saving}>
              {t('common.cancel')}
            </Button>
            <Button
              onClick={() => void save()}
              disabled={saving || (editing?.kind === 'compatible' && !selected.size)}
            >
              {saving ? t('vibeproxy.saving') : t('common.save')}
            </Button>
          </>
        }
      >
        <p className={styles.modalHint}>{t('vibeproxy.persistHint')}</p>
        {editing && !editing.enabled && (
          <p className={styles.modalHint}>{t('vibeproxy.disabledHint')}</p>
        )}
        <label className={styles.search}>
          <IconSearch size={16} />
          <input
            type="search"
            aria-label={t('vibeproxy.searchModels')}
            placeholder={t('vibeproxy.searchModels')}
            value={modelSearch}
            onChange={(event) => setModelSearch(event.target.value)}
          />
        </label>
        <div className={styles.batch}>
          <button
            type="button"
            className={styles.link}
            disabled={saving}
            onClick={() => setSelected(new Set(editing?.models))}
          >
            {t('vibeproxy.selectAll')}
          </button>
          <button
            type="button"
            className={styles.link}
            disabled={saving}
            onClick={() => setSelected(new Set())}
          >
            {t('vibeproxy.deselectAll')}
          </button>
          <span>
            {t('vibeproxy.selectedCount', {
              count: selected.size,
              total: editing?.models.length ?? 0,
            })}
          </span>
        </div>
        <div className={styles.modelList}>
          {models.map((id) => (
            <SelectionCheckbox
              key={id}
              checked={selected.has(id)}
              disabled={saving}
              label={<span className={styles.modelName}>{id}</span>}
              onChange={() =>
                setSelected((previous) => {
                  const next = new Set(previous);
                  if (next.has(id)) next.delete(id);
                  else next.add(id);
                  return next;
                })
              }
            />
          ))}
        </div>
      </Modal>
    </section>
  );
}
