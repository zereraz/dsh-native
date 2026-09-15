// Verifies the APP BUNDLE against the uv_cwd incident class: chdir into a
// fresh tmp dir, delete it, then run code through the app's runtime surface.
// Pre-fix behavior: spawn inherited the deleted host cwd and every run died
// with "ENOENT: ... uv_cwd". Post-fix: absolute cwd wins, run returns 42.
//
// dsh-local 2026-09-15 (0.1.6 port): WorkerThreadCodeRuntime is GONE upstream
// (ptc-runtime-node spawns fresh processes via dsh-subprocess-local), so the
// gate follows the surface. Dual-mode: try the new subprocess check first;
// fall back to the worker-thread check for pre-0.1.6 bundles so activation
// and recovery both stay gated on every version in flight.
import { mkdtemp, rm } from 'node:fs/promises'
import { realpathSync } from 'node:fs'
import { tmpdir, homedir } from 'node:os'
import { join } from 'node:path'

const SUP = process.env.DSH_APP_SUP || '/Applications/DeepSeek Harness.app/Contents/Resources/supervisor'
const { Context } = await import(`${SUP}/node_modules/@deepseek-ai/cordis/lib/index.js`)

const victim = await mkdtemp(join(tmpdir(), 'dsh-verify-victim-'))
process.chdir(victim)
await rm(victim, { recursive: true, force: true })
let deleted = false
try { realpathSync(process.cwd()) } catch { deleted = true }
console.log('precondition cwd deleted:', deleted)

async function subprocessCheck() {
  const { default: LocalSubprocessRuntime } = await import(`${SUP}/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js`)
  const ctx = new Context()
  await ctx.plugin(LocalSubprocessRuntime, {})
  const handle = ctx.subprocess.spawn({
    argv: [process.execPath, '-e', 'console.log(6 * 7)'],
    cwd: homedir(),
    stdio: { stdin: 'ignore', stdout: { collect: { maxBytes: 65536 } }, stderr: { collect: { maxBytes: 65536 } } },
    graceMs: 5000,
  })
  const outcome = await handle.done
  const out = await handle.collected.stdout.readFrom(0)
  const errOut = await handle.collected.stderr.readFrom(0)
  console.log('exit:', outcome.exitCode, 'stdout:', out.text.trim(), 'stderr:', errOut.text.trim().slice(0, 120))
  if (outcome.exitCode !== 0 || out.text.trim() !== '42') throw new Error(`subprocess check failed (exit ${outcome.exitCode}, out ${JSON.stringify(out.text)})`)
  await ctx.fiber.dispose()
  return 'PASS — child spawned from deleted host cwd via LocalSubprocessRuntime, returned 42'
}

async function workerThreadCheck() {
  const { WorkerThreadCodeRuntime } = await import(`${SUP}/node_modules/@deepseek-ai/dsh-code-runtime-worker-thread/lib/index.js`)
  const ctx = new Context()
  await ctx.plugin(WorkerThreadCodeRuntime, {})
  const result = await ctx.codeRuntime.run({ program: 'return 6 * 7;', bindings: [] })
  console.log('result:', JSON.stringify(result))
  if (result.error) throw new Error(`worker error: ${result.error.kind} ${result.error.message}`)
  if (result.value !== 42) throw new Error('wrong value')
  await ctx.fiber.dispose()
  return 'PASS — worker spawned from deleted host cwd, returned 42'
}

let verdict
try {
  verdict = await subprocessCheck()
} catch (e) {
  if (e?.code === 'ERR_MODULE_NOT_FOUND') {
    console.log('subprocess-local not present; falling back to worker-thread check (pre-0.1.6 bundle)')
    verdict = await workerThreadCheck()
  } else {
    throw e
  }
}
console.log('VERDICT:', verdict)
process.exit(0)
