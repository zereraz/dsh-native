// dsh-native dev supervisor: boot `dsh web` against the SHARED ~/.dsh home
// (same sessions, providers, and profile as `dsh web` on the CLI) on the
// fixed loopback port app.zon expects (41730). Installs the privacy patch
// layer into profiles/web on every boot — harmless to the CLI too, since it
// only disables what you already disabled. Runs in the foreground; the
// Native SDK dev runner kills this process tree on shell exit.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { copyFileSync, mkdirSync } from 'node:fs';
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

// Forward the parent environment so DSH_PROVIDER_API_KEY (from ~/.zshrc)
// and friends reach dsh; only override the dsh-native-specific keys.
const env = {
  ...process.env,
  DSH_HOME,
  DSH_TELEMETRY_DISABLED: '1',
  DSH_TELEMETRY_MODE: 'DISABLED',
};

// cordis-plugin-loader requires --expose-internals when booting with a
// patch layer; pass it as argv (NODE_OPTIONS rejects it on every node).
const child = spawn(
  process.execPath,
  ['--expose-internals', dshBin, 'web', '--host', HOST, '--port', String(PORT), '--trusted-host', `${HOST}:${PORT}`],
  { env, stdio: 'inherit' },
);

child.on('exit', (code) => process.exit(code ?? 0));
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => child.kill(sig));
}
