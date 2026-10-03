import { useCallback, useEffect, useRef, useState } from 'react';
import { useQuotaStore } from '@/stores';
import {
  vibeproxyApi,
  type CompatibleQuotaCredential,
  type CompatibleQuotaResult,
} from '@/services/api/vibeproxy';

export function useCompatibleQuota(connected: boolean, generation: number) {
  const [credentials, setCredentials] = useState<CompatibleQuotaCredential[]>([]);
  const [results, setResults] = useState<Record<string, CompatibleQuotaResult>>({});
  const [listing, setListing] = useState(false);
  const [error, setError] = useState(false);
  const [dataGeneration, setDataGeneration] = useState<number | null>(null);
  const epoch = useRef(0);
  const pending = useRef(new Map<string, number>());

  const refreshCredential = useCallback(
    async (credential: CompatibleQuotaCredential, force = true, requestEpoch = epoch.current) => {
      const current = () =>
        requestEpoch === epoch.current && generation === useQuotaStore.getState().cacheGeneration;
      if (!connected || !current() || pending.current.get(credential.id) === requestEpoch) return;
      pending.current.set(credential.id, requestEpoch);
      setResults((previous) => ({
        ...previous,
        [credential.id]: {
          credential,
          status: 'loading',
          windows: [],
          balances: [],
          fetchedAt: null,
        },
      }));
      try {
        const result = await vibeproxyApi.compatibleQuota(credential.id, force);
        if (current()) setResults((previous) => ({ ...previous, [credential.id]: result }));
      } catch (error) {
        if (current()) {
          setResults((previous) => ({
            ...previous,
            [credential.id]: {
              credential,
              status: 'error',
              windows: [],
              balances: [],
              fetchedAt: null,
              ...(error instanceof Error && 'status' in error && typeof error.status === 'number'
                ? { httpStatus: error.status }
                : {}),
            },
          }));
        }
      } finally {
        if (pending.current.get(credential.id) === requestEpoch)
          pending.current.delete(credential.id);
      }
    },
    [connected, generation]
  );

  const refresh = useCallback(
    async (force = true) => {
      const requestEpoch = ++epoch.current;
      const current = () =>
        requestEpoch === epoch.current && generation === useQuotaStore.getState().cacheGeneration;
      if (!connected) return;
      setListing(true);
      setError(false);
      try {
        const data = await vibeproxyApi.compatibleQuotaCredentials();
        if (!current()) return;
        setDataGeneration(generation);
        setCredentials(data.credentials);
        setResults({});
        setListing(false);
        // Bound upstream concurrency; each credential has independent data and errors.
        const queue = [...data.credentials];
        await Promise.all(
          Array.from({ length: 3 }, async () => {
            while (queue.length && current()) {
              const credential = queue.shift();
              if (credential) await refreshCredential(credential, force, requestEpoch);
            }
          })
        );
      } catch {
        if (current()) {
          setDataGeneration(generation);
          setError(true);
          setCredentials([]);
          setResults({});
        }
      } finally {
        if (current()) setListing(false);
      }
    },
    [connected, generation, refreshCredential]
  );

  useEffect(() => {
    setCredentials([]);
    setDataGeneration(null);
    setResults({});
    setError(false);
    setListing(false);
    if (connected) void refresh(false);
    return () => {
      epoch.current += 1;
    };
  }, [connected, refresh]);

  const currentData = connected && dataGeneration === generation;
  const currentResults = currentData ? results : {};
  return {
    credentials: currentData ? credentials : [],
    results: currentResults,
    error: currentData && error,
    refresh,
    refreshCredential,
    loading:
      connected &&
      (listing ||
        !currentData ||
        Object.values(currentResults).some((result) => result.status === 'loading')),
    loadedCount: Object.values(currentResults).filter((result) => result.status === 'success')
      .length,
    attentionCount: Object.values(currentResults).filter((result) => result.status === 'error')
      .length,
  };
}
