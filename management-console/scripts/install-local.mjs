import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import YAML from 'yaml';

if (process.platform !== 'darwin') throw new Error('Local installation requires macOS.');

const project = fileURLToPath(new URL('..', import.meta.url));
const directory = path.join(os.homedir(), '.cli-proxy-api');
const userPath = path.join(directory, 'config.yaml');
const panelPath = path.join(directory, 'static/management.html');
const agentPath = path.join(os.homedir(), 'Library/LaunchAgents/io.vibeproxy.model-bridge.plist');
const logs = path.join(os.homedir(), 'Library/Logs');
const domain = `gui/${process.getuid()}`;

const xml = (value) =>
  value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

async function bootstrap(filename) {
  // launchd may briefly return EIO while the previous job is being removed.
  for (let attempt = 0; ; attempt++) {
    try {
      execFileSync('/bin/launchctl', ['bootstrap', domain, filename], { stdio: 'pipe' });
      return;
    } catch (error) {
      if (error.status !== 5 || attempt >= 3) throw error;
      await new Promise((resolve) => setTimeout(resolve, 200 * (attempt + 1)));
    }
  }
}

async function optionalRead(filename) {
  try {
    return await fs.readFile(filename);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function atomicWrite(filename, contents, mode = 0o600) {
  const temporary = `${filename}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, contents, { mode, flag: 'wx' });
    await fs.rename(temporary, filename);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

const panel = await fs.readFile(path.join(project, 'dist/index.html'));
const source = await fs.readFile(userPath, 'utf8');
const document = YAML.parseDocument(source);
if (document.errors.length) throw new Error('Fix the user configuration YAML before installing.');
if (!document.getIn(['remote-management', 'secret-key'])) {
  throw new Error('Set a management key in the VibeProxy user configuration before installing.');
}
// Keep the v0-compatible custom page from being replaced by an upstream download.
document.setIn(['remote-management', 'disable-auto-update-panel'], true);
const nextSource = document.toString();

const previousPanel = await optionalRead(panelPath);
const previousAgent = await optionalRead(agentPath);
const backupDirectory = path.join(directory, 'panel-releases');
await fs.mkdir(backupDirectory, { recursive: true });
if (previousPanel) {
  await fs.writeFile(
    path.join(backupDirectory, `management-before-install-${Date.now()}.html`),
    previousPanel
  );
}
await fs.mkdir(path.dirname(panelPath), { recursive: true });
await fs.mkdir(path.dirname(agentPath), { recursive: true });
await fs.mkdir(logs, { recursive: true });
const launchAgent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.vibeproxy.model-bridge</string>
<key>ProgramArguments</key><array><string>${xml(process.execPath)}</string><string>${xml(path.join(project, 'scripts/vibeproxy-model-bridge.mjs'))}</string></array>
<key>WorkingDirectory</key><string>${xml(project)}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>${xml(path.join(logs, 'VibeProxyModelBridge.log'))}</string>
<key>StandardErrorPath</key><string>${xml(path.join(logs, 'VibeProxyModelBridge-error.log'))}</string>
</dict></plist>
`;

if ((await fs.readFile(userPath, 'utf8')) !== source) {
  throw new Error('VibeProxy settings changed. Run the installer again.');
}

try {
  execFileSync('/bin/launchctl', ['bootout', `${domain}/io.vibeproxy.model-bridge`], {
    stdio: 'ignore',
  });
} catch {
  // First installation has no running LaunchAgent.
}

let stage = 'configuration write';
try {
  await atomicWrite(userPath, nextSource);
  stage = 'panel write';
  await atomicWrite(panelPath, panel, 0o644);
  stage = 'LaunchAgent write';
  await atomicWrite(agentPath, launchAgent);
  stage = 'LaunchAgent startup';
  await bootstrap(agentPath);
} catch {
  if ((await fs.readFile(userPath, 'utf8')) === nextSource) await atomicWrite(userPath, source);
  if (previousPanel) await atomicWrite(panelPath, previousPanel, 0o644);
  else await fs.rm(panelPath, { force: true });
  if (previousAgent) {
    await atomicWrite(agentPath, previousAgent);
    try {
      await bootstrap(agentPath);
    } catch {
      // Report the failed installation without printing configuration or credentials.
    }
  } else await fs.rm(agentPath, { force: true });
  throw new Error(
    `Installation failed during ${stage}; the previous configuration and panel were restored.`
  );
}

console.log('Installed the management console and local model helper.');
console.log('Open http://127.0.0.1:8318/management.html');
