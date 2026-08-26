// Verifies the APP BUNDLE's own WorkerThreadCodeRuntime against the uv_cwd incident:
// chdir into a fresh tmp dir, delete it, then run a program. Pre-fix: every run dies
// with "worker error: ENOENT: ... uv_cwd". Post-fix: cwd re-anchors to home, run returns 42.
import { mkdtemp, rm } from 'node:fs/promises'
import { realpathSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const SUP = '/Applications/DeepSeek Harness.app/Contents/Resources/supervisor'
const { Context } = await import(`${SUP}/node_modules/@deepseek-ai/cordis/lib/index.js`)
const { WorkerThreadCodeRuntime } = await import(`${SUP}/node_modules/@deepseek-ai/dsh-code-runtime-worker-thread/lib/index.js`)

const ctx = new Context()
await ctx.plugin(WorkerThreadCodeRuntime, {})
const runtime = ctx.codeRuntime

const victim = await mkdtemp(join(tmpdir(), 'dsh-verify-victim-'))
process.chdir(victim)
await rm(victim, { recursive: true, force: true })
let deleted = false
try { realpathSync(process.cwd()) } catch { deleted = true }
console.log('precondition cwd deleted:', deleted)

const result = await runtime.run({ program: 'return 6 * 7;', bindings: [] })
console.log('result:', JSON.stringify(result))
if (result.error) { console.log('VERDICT: FAIL —', result.error.kind, result.error.message); process.exit(1) }
if (result.value !== 42) { console.log('VERDICT: FAIL — wrong value'); process.exit(1) }
console.log('VERDICT: PASS — worker spawned from deleted cwd, returned 42')
await ctx.fiber.dispose()
process.exit(0)
