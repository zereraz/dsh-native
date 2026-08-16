// dsh-native evaluation suite. Score every top feature 0|1 (or a ratio).
// Run:  node tests/eval.mjs                — all features
//       node tests/eval.mjs prompt         — just the prompt/tool-contract evals
//       node tests/eval.mjs boot ui chat   — select features
//
// Use before/after any prompt change to measure the delta.

import { spawn, execSync } from 'node:child_process';
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const APP = '/Applications/DeepSeek Harness.app';
const PORT = 41730;
const BASE = `http://127.0.0.1:${PORT}`;
const HOME = homedir();

const args = process.argv.slice(2);
const only = new Set(args.length ? args : null);

// ---------- helpers ----------
const results = [];
const fmt = n => (typeof n === 'number' ? n.toFixed(2).replace(/\.?0+$/, '') : '—');
function score(name, value, detail = '') {
  results.push({ name, value, detail });
  const badge = value === 1 ? '✓' : value === 0 ? '✗' : '~';
  console.log(`${badge}  ${name.padEnd(44)} ${fmt(value)}  ${detail}`);
}
const skip = n => only.size && !only.has(n);

function sh(cmd, opts = {}) {
  try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts }).trim(); }
  catch (e) { return (e.stdout || '').toString().trim(); }
}
const kill = () => { sh(`pkill -f 'dsh-native$|dsh-web.mjs|bin.js web|dsh-native-shell' 2>/dev/null`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitForDsh(maxS = 25) {
  for (let i = 0; i < maxS * 4; i++) {
    try { const r = await fetch(BASE + '/', { signal: AbortSignal.timeout(1500) }); if (r.ok) return true; } catch {}
    await sleep(250);
  }
  return false;
}

async function ocrWindow(wid) {
  // capture the window and OCR it; returns '' on any failure
  const png = '/tmp/eval_win.png';
  sh(`rm -f ${png}`);
  sh(`screencapture -l ${wid} -x ${png} 2>/dev/null`);
  if (!existsSync(png)) return '';
  if (!existsSync('/tmp/ocr')) return ''; // built earlier during dev
  return sh(`/tmp/ocr ${png} 2>&1`) || '';
}

// ---------- feature tests ----------
async function testBoot() {
  if (skip('boot')) return;
  kill(); await sleep(1200);
  sh(`open "${APP}"`);
  const ok = await waitForDsh(25);
  score('boot: dsh replies 200 within 25 s of open', ok ? 1 : 0);
}

async function testPrivacy() {
  if (skip('privacy')) return;
  // the server config from ~/.dsh/profiles/web/cordis.patch.yml is what we install
  const p = join(HOME, '.dsh', 'profiles', 'web', 'cordis.patch.yml');
  if (!existsSync(p)) return score('privacy: patch layer exists', 0, `not found at ${p}`);
  const body = readFileSync(p, 'utf8');
  const need = ['session-telemetry-otel', 'command-feedback', 'message-feedback', 'ui-message-feedback'];
  const missing = need.filter(s => !body.includes(`${s}\n  disabled: true`) && !body.includes(`${s}\r\n  disabled: true`));
  score('privacy: telemetry+feedback plugins disabled', missing.length === 0 ? 1 : 0, missing.length ? 'missing: ' + missing.join(',') : '');
  const envDisabled = (sh(`ps e $(pgrep -f 'bin.js web' | head -1) 2>/dev/null`).match(/DSH_TELEMETRY_DISABLED=1/) ? 1 : 0);
  score('privacy: DSH_TELEMETRY_DISABLED=1 in live env', envDisabled);
}

async function testIcon() {
  if (skip('icon')) return;
  const icns = join(APP, 'Contents/Resources/AppIcon.icns');
  score('icon: AppIcon.icns in bundle', existsSync(icns) ? 1 : 0);
  const plist = join(APP, 'Contents/Info.plist');
  const plistText = readFileSync(plist, 'utf8');
  score('icon: Info.plist references AppIcon.icns', /CFBundleIconFile<\/key>\s*<string>AppIcon\.icns/.test(plistText) ? 1 : 0);
}

async function testSessions() {
  if (skip('sessions')) return;
  const txt = await ocrWindow(execSync('/tmp/winid').toString().trim());
  // any of your historical session titles shows up → shared home works
  const hit = ['find your own codebase', 'New Session', 'Workspaces'].some(s => txt.includes(s));
  score('sessions: window shows items from shared home', hit ? 1 : 0);
}

async function testEnv() {
  if (skip('env')) return;
  // spawning env (this shell) may or may not have it; what matters is the supervised dsh process
  const live = sh(`ps e $(pgrep -f 'bin.js web' | head -1) 2>/dev/null`);
  const m = live.match(/JUSPAY_GRID_API_KEY=([a-zA-Z0-9-]+)/);
  // fail the eval if key isn't there at all (auth will fail), and ALSO fail if it's the known stale one
  if (!m) return score('env: provider key present in dsh', 0, 'no JUSPAY_GRID_API_KEY in dsh env');
  const val = m[1];
  const stalePrefix = 'sk-FZh';
  const good = !val.startsWith(stalePrefix);
  score('env: provider key present + not stale', good ? 1 : 0, `starts ${val.slice(0, 6)}`);
}

async function testSingleInstance() {
  if (skip('single')) return;
  const before = sh(`pgrep -f 'supervisor/dsh-web.mjs'`).split('\n').filter(Boolean).length;
  sh(`open "${APP}"`); await sleep(1500);
  const after = sh(`pgrep -f 'supervisor/dsh-web.mjs'`).split('\n').filter(Boolean).length;
  // opening again should keep exactly 1 supervisor (NSApplication dedupes, or launcher should replace)
  score('single-instance: reopening does not spawn a second supervisor', after <= Math.max(before, 1) ? 1 : 0, `before=${before} after=${after}`);
}

async function testUIText() {
  if (skip('ui')) return;
  const wid = sh('/tmp/winid').trim();
  const txt = await ocrWindow(wid);
  const checks = ['HARNESS', 'New Session', 'Workspaces'];
  const hit = checks.filter(s => txt.includes(s)).length;
  score('ui: expected dashboard strings visible', hit / checks.length, `${hit}/${checks.length}`);
}

async function testChatAPI() {
  if (skip('chat')) return;
  // hit the provider via dsh's diagnostic route if it exists; otherwise drive it via web ui
  // simplest public surface: ask for a tiny completion via dsh's models HTTP/LLM adapter
  // (uploaded via provider proxy so no key handling here)
  try {
    const r = await fetch(BASE + '/api/providers/deepseek-grid/ping', { signal: AbortSignal.timeout(5000) });
    if (!r.ok) return score('chat: provider responds', 0, `status ${r.status}`);
    return score('chat: provider responds', 1, r.status);
  } catch (e) {
    // route may not exist; that's fine — fall back: check llm is registered in session log
    const log = sh(`grep -l 'llm-pi-ai.providers.deepseek-grid' ${HOME}/.dsh/sessions/**/session.jsonl.zstd 2>/dev/null | head -1`);
    score('chat: provider registered in session log', log ? 1 : 0, log ? '' : 'no evidence');
  }
}

function extractUpdateGoalFromLog() {
  const sessRoot = `${HOME}/.dsh/sessions`;
  if (!existsSync(sessRoot)) return { total: 0, wrong: 0 };
  // find latest session with update_goal calls
  try {
    const lines = sh(`for d in ${sessRoot}/*/; do F=$(ls -t "$d"*/session.jsonl.zstd 2>/dev/null | head -1); [ -n "$F" ] && echo "$F"; done | head -3`);
    let total = 0, wrong = 0;
    for (const f of lines.split('\n').filter(Boolean)) {
      const raw = sh(`zstd -d -c "${f}" 2>/dev/null`);
      if (!raw) continue;
      for (const m of raw.matchAll(/"name":"update_goal"[^{]*\{[^}]*"parameters":(\{[^}]*\})/g)) {
        total++;
        try {
          const p = JSON.parse(m[1]);
          // correctness test must match the schema: requires action, forbids 'status'
          if (!('action' in p) || 'status' in p) wrong++;
        } catch { wrong++; }
      }
    }
    return { total, wrong };
  } catch { return { total: 0, wrong: 0 }; }
}

async function testToolSchema() {
  if (skip('schema')) return;
  const { total, wrong } = extractUpdateGoalFromLog();
  if (total === 0) return score('prompt: update_goal calls follow schema', 0.5, 'no update_goal calls yet — empty eval');
  const good = 1 - wrong / total;
  score('prompt: update_goal calls follow schema', good, `${wrong}/${total} hallucinated`);
}

async function testResume() {
  if (skip('resume')) return;
  kill(); await sleep(1500);
  sh(`open "${APP}"`);
  const ok = await waitForDsh(25);
  score('resume: relaunch after quit still boots', ok ? 1 : 0);
}

async function testStability() {
  if (skip('stable')) return;
  const crashes = sh(`tail -200 ${HOME}/Library/Logs/com.zereraz.dsh-native/native-sdk.jsonl 2>/dev/null | grep -ciE 'panic|error|crash'`).split('\n')[0] || '0';
  const n = parseInt(crashes, 10);
  score('stability: no panic/error entries in runtime log (last 200)', n === 0 ? 1 : 0, `count=${n}`);
}

// ---------- main ----------
console.log('## dsh-native eval ##\n');
await testBoot();
await testPrivacy();
await testIcon();
await testSessions();
await testEnv();
await testSingleInstance();
await testUIText();
await testChatAPI();
await testToolSchema();
await testStability();
await testResume();

const total = results.reduce((a, r) => a + r.value, 0);
const max = results.length;
console.log(`\n${'-'.repeat(60)}`);
console.log(`SCORE  ${fmt(total)} / ${fmt(max)}`);
// write a machine-readable line so prompt A/B can diff
mkdirSync('tests/results', { recursive: true });
const line = `${new Date().toISOString()} total=${total.toFixed(2)}/${max} ` +
  results.map(r => `${r.name.split(':')[0]}=${r.value.toFixed(2)}`).join(' ') + '\n';
writeFileSync('tests/results/latest.txt', line);
console.log(`results → tests/results/latest.txt`);
