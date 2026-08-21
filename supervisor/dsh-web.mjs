// dsh-native dev supervisor: boot `dsh web` against the SHARED ~/.dsh home
// (same sessions, providers, and profile as `dsh web` on the CLI) on the
// fixed loopback port app.zon expects (41730). Installs the privacy patch
// layer into profiles/web on every boot — harmless to the CLI too, since it
// only disables what you already disabled. Runs in the foreground; the
// Native SDK dev runner kills this process tree on shell exit.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const PORT = 41730;
const HOST = '127.0.0.1';
const DSH_HOME = join(homedir(), '.dsh');
const here = dirname(fileURLToPath(import.meta.url));

// Resolve the dsh CLI from the supervisor's own node_modules.
const require = createRequire(import.meta.url);
const dshPkg = require.resolve('@deepseek-ai/dsh/package.json');
const dshBin = join(dirname(dshPkg), 'lib', 'bin.js');

function installPatch() {
  const profileDir = join(DSH_HOME, 'profiles', 'web');
  mkdirSync(profileDir, { recursive: true });
  copyFileSync(join(here, '..', 'config', 'cordis.patch.yml'), join(profileDir, 'cordis.patch.yml'));
}

installPatch();

// Merge env var-style "export NAME=..." lines from common shell rc files
// (Finder/launchd spawns never source them, so provider apiKeyEnv values
// need to come from shell defaults). Later sources win, so users can put
// secrets in ~/.zshenv for earliest setup or override per-shell later.
function loadShellEnv() {
  const out = {};
  const home = homedir();
  const files = ['.zshenv', '.zprofile', '.zshrc', '.bash_profile', '.bashrc'];
  const re = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/;
  for (const f of files) {
    let text;
    try { text = readFileSync(join(home, f), 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      const m = line.match(re);
      if (!m) continue;
      let v = m[2].trim();
      // strip surrounding quotes if the author quoted the whole value
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
        v = v.slice(1, -1);
      }
      // simple $(...) and $VAR expansion for common cases like $(cmd), $HOME
      v = v.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (_, name) => process.env[name] ?? out[name] ?? '');
      out[m[1]] = v;
    }
  }
  return out;
}

// Forward provider apiKeyEnv values (e.g., whatever your ~/.dsh/settings.yaml
// references) so they reach dsh even when launched via Finder/launchd. The
// rc-file values OVERRIDE process.env: an inherited-but-stale key (from an
// agent runner or launchd boot env) must not shadow the current rc file,
// which is the one place a human edits when rotating a credential.
const env = {
  ...process.env,
  ...loadShellEnv(),
  DSH_HOME,
  DSH_TELEMETRY_DISABLED: '1',
  DSH_TELEMETRY_MODE: 'DISABLED',
};

// cordis-plugin-loader requires --expose-internals when booting with a
// patch layer; pass it as argv (NODE_OPTIONS rejects it on every node).
const child = spawn(
  process.execPath,
  ['--expose-internals', dshBin, 'web', '--host', HOST, '--port', String(PORT), '--trusted-host', `${HOST}:${PORT}`, '--no-open'],
  { env, stdio: 'inherit' },
);

child.on('exit', (code) => process.exit(code ?? 0));
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => child.kill(sig));
}
