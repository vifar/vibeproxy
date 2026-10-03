import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import YAML from 'yaml';
import { buildProviders, selectionUpdate, SERVICES } from './vibeproxy-models.mjs';

const directory = path.join(os.homedir(), '.cli-proxy-api');
const userPath = path.join(directory, 'config.yaml');
const runtimePath = path.join(directory, 'merged-config.yaml');
const basePath = '/Applications/VibeProxy.app/Contents/Resources/config.yaml';
const cachePath = path.join(os.homedir(), 'Library/Caches/VibeProxy/proxy-provider-catalog.json');
const backend = 'http://127.0.0.1:8318/v0/management';
let mutation = Promise.resolve();

async function management(key, endpoint, options = {}) {
  const response = await fetch(`${backend}${endpoint}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      ...options.headers,
    },
    signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) {
    const error = new Error(`Management request failed (${response.status})`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

async function readOptional(filename, fallback) {
  try {
    return await fs.readFile(filename, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return fallback;
    throw error;
  }
}

async function snapshot(key) {
  const [userText, runtimeText, baseText, cacheText, auth] = await Promise.all([
    readOptional(userPath, '{}'),
    fs.readFile(runtimePath, 'utf8'),
    fs.readFile(basePath, 'utf8'),
    readOptional(cachePath, '{}'),
    management(key, '/auth-files'),
  ]);
  const definitions = Object.fromEntries(
    await Promise.all(
      SERVICES.filter((service) => service.oauthKey).map(async (service) => {
        try {
          const data = await management(
            key,
            `/model-definitions/${encodeURIComponent(service.oauthKey)}`
          );
          return [service.id, data.models || []];
        } catch (error) {
          // Older backends may lack this catalog endpoint; keep desktop's cached pool.
          if (![400, 404].includes(error.status)) throw error;
          return [service.id, []];
        }
      })
    )
  );
  const data = {
    user: YAML.parse(userText) || {},
    runtime: YAML.parse(runtimeText) || {},
    base: YAML.parse(baseText) || {},
    cache: JSON.parse(cacheText),
    files: auth.files || [],
    definitions,
  };
  return { ...data, userText, providers: buildProviders(data) };
}

async function atomicWrite(filename, text) {
  const temporary = `${filename}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, text, { mode: 0o600, flag: 'wx' });
    await fs.rename(temporary, filename);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

async function saveSelection(key, id, input) {
  const current = await snapshot(key);
  const provider = current.providers.find((item) => item.id === id);
  if (!provider) throw Object.assign(new Error('Provider not found'), { status: 404 });
  if (input.revision !== provider.revision) {
    throw Object.assign(new Error('Models changed. Refresh and try again.'), { status: 409 });
  }
  const update = selectionUpdate(
    provider,
    input.selected,
    current.user,
    current.runtime,
    current.base
  );
  // Preserve comments and unrelated settings in the user-authored YAML document.
  const document = YAML.parseDocument(current.userText);
  for (const field of ['openai-compatibility', 'oauth-included-models', 'oauth-excluded-models']) {
    if (update.user[field] !== undefined) document.set(field, update.user[field]);
  }
  const nextText = document.toString();
  if ((await readOptional(userPath, '{}')) !== current.userText) {
    throw Object.assign(new Error('VibeProxy settings changed. Refresh and try again.'), {
      status: 409,
    });
  }
  await atomicWrite(userPath, nextText);
  try {
    const existing = current.runtime['oauth-excluded-models']?.[provider.oauthKey];
    if (update.path && (update.patch.models?.length || existing || !provider.oauthKey)) {
      await management(key, update.path, { method: 'PATCH', body: JSON.stringify(update.patch) });
    }
  } catch (error) {
    if ((await fs.readFile(userPath, 'utf8')) === nextText)
      await atomicWrite(userPath, current.userText);
    throw error;
  }
  return { status: 'ok' };
}

function send(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}

const server = http.createServer(async (request, response) => {
  try {
    const key = /^Bearer (.+)$/i.exec(request.headers.authorization || '')?.[1];
    if (!key) return send(response, 401, { error: 'Management key required' });
    // Reuse backend authentication, including its password rotation and lockout rules.
    await management(key, '/config');
    const url = new URL(request.url, 'http://127.0.0.1:8319');
    if (request.method === 'GET' && url.pathname === '/providers') {
      const current = await snapshot(key);
      return send(response, 200, { providers: current.providers });
    }
    const match = /^\/providers\/([^/]+)\/models$/.exec(url.pathname);
    if (request.method === 'PUT' && match) {
      let body = '';
      for await (const chunk of request) {
        body += chunk;
        if (body.length > 131072)
          throw Object.assign(new Error('Request too large'), { status: 413 });
      }
      const input = JSON.parse(body);
      const task = mutation.then(() => saveSelection(key, decodeURIComponent(match[1]), input));
      mutation = task.catch(() => undefined);
      return send(response, 200, await task);
    }
    send(response, 404, { error: 'Not found' });
  } catch (error) {
    // No request contents, credentials, configuration values, or upstream bodies in logs.
    const publicError =
      error.status ||
      error.message === 'Invalid model selection' ||
      error.message.startsWith('Select at least one') ||
      error.message.startsWith('Connect this provider');
    send(response, error.status || 400, {
      error: publicError ? error.message : 'Unable to read or save VibeProxy settings',
    });
  }
});
server.requestTimeout = 60000;
server.listen(8319, '127.0.0.1', () =>
  console.log('VibeProxy model bridge listening on localhost:8319')
);
