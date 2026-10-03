import { apiCallApi, getApiCallErrorMessage } from './apiCall';
import { useAuthStore } from '@/stores/useAuthStore';

export interface VibeProxyProvider {
  id: string;
  name: string;
  oauthKey: string | null;
  kind: 'subscription' | 'compatible';
  models: string[];
  selected: string[];
  enabled: boolean;
  accountCount: number;
  activeAccounts: number;
  configured: boolean;
  canSave: boolean;
  revision: string;
}

async function request<T>(method: string, path: string, data?: unknown): Promise<T> {
  const { managementKey } = useAuthStore.getState();
  const result = await apiCallApi.request({
    method,
    url: `http://127.0.0.1:8319${path}`,
    header: { Authorization: `Bearer ${managementKey}`, 'Content-Type': 'application/json' },
    ...(data === undefined ? {} : { data: JSON.stringify(data) }),
  });
  if (result.statusCode < 200 || result.statusCode >= 300) {
    throw new Error(getApiCallErrorMessage(result));
  }
  return result.body as T;
}

export const vibeproxyApi = {
  providers: () => request<{ providers: VibeProxyProvider[] }>('GET', '/providers'),
  saveModels: (provider: VibeProxyProvider, selected: string[]) =>
    request('PUT', `/providers/${encodeURIComponent(provider.id)}/models`, {
      revision: provider.revision,
      selected,
    }),
};
