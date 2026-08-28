// sync-runtime.mjs <harness-repo> <supervisor-dir>
// Copies the git-built dsh runtime into the app bundle's supervisor
// node_modules: the CLI package + every @deepseek-ai/* package whose name
// exists on the target, each per its own `files` field. No registry calls.
import { execSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync, copyFileSync, cpSync } from 'node:fs'
import { join, basename, dirname } from 'node:path'

const [harness, sup] = process.argv.slice(2)
if (!harness || !sup) { console.error('usage: sync-runtime.mjs <harness> <supervisor>'); process.exit(1) }

const target = join(sup, 'node_modules', '@deepseek-ai')
let synced = 0
const put = (srcDir, dstDir) => {
  const pkg = JSON.parse(readFileSync(join(srcDir, 'package.json'), 'utf8'))
  const files = pkg.files ?? ['lib']
  if (files.some(f => f === 'lib' || f.startsWith('lib/'))) cpSync(join(srcDir, 'lib'), join(dstDir, 'lib'), { recursive: true })
  for (const f of files) {
    const s = join(srcDir, f)
    if (f !== 'lib' && existsSync(s) && !s.includes('*')) cpSync(s, join(dstDir, f), { recursive: true })
  }
  copyFileSync(join(srcDir, 'package.json'), join(dstDir, 'package.json'))
  synced++
}

put(join(harness, 'apps/cli'), join(target, 'dsh'))
for (const group of ['packages', 'vendor']) {
  const walk = (dir) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name)
      if (e.name === 'node_modules' || !e.isDirectory()) continue
      if (existsSync(join(p, 'package.json'))) {
        try {
          const pkg = JSON.parse(readFileSync(join(p, 'package.json'), 'utf8'))
          // Install every built @deepseek-ai package — filtering by prior
          // presence silently drops NEW packages the release added (e.g. the
          // ui-renderer → infinite 'Loading plugins…').
          if (pkg.name?.startsWith('@deepseek-ai/') && existsSync(join(p, 'lib'))) put(p, join(target, basename(pkg.name)))
        } catch { /* unparseable manifests are not runtime */ }
      }
      walk(p)
    }
  }
  walk(join(harness, group))
}
// web frontend ships dist, not lib
const webDist = join(harness, 'apps/web/dist')
if (existsSync(join(target, 'dsh-web-frontend'))) {
  execSync(`rsync -a --delete --exclude '*.map' "${webDist}/" "${join(target, 'dsh-web-frontend', 'dist')}/"`)
  copyFileSync(join(harness, 'apps/web/package.json'), join(target, 'dsh-web-frontend', 'package.json'))
}
console.log(`synced ${synced} packages + web frontend`)

// --- mirror into EVERY runtime copy on the machine (2026-08 lesson) ---------
// The npm-global `dsh` under the POCKET-SERVER prefix shipped a THIRD copy of
// the runtime that drifted away from the harness repo (uv_cwd ghost returned
// there). Any future pipeline run keeps all known copies in lockstep — the
// source of truth is always the harness checkout, so every mirror gets the
// same never-downgrade safety as the app bundle gets from the repo versions.
const extraTargets = [
  `${process.env.HOME}/.pocket-server/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai`,
]
for (const extra of extraTargets) {
  if (!existsSync(extra)) continue
  let mirrored = 0
  const maybe = (srcDir, dstDir) => { if (existsSync(dstDir)) { put(srcDir, dstDir); mirrored++ } }
  maybe(join(harness, 'apps/cli'), join(extra, 'dsh'))
  for (const group of ['packages', 'vendor']) {
    const walk = (dir) => {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, e.name)
        if (e.name === 'node_modules' || !e.isDirectory()) continue
        if (existsSync(join(p, 'package.json'))) {
          try {
            const pkg = JSON.parse(readFileSync(join(p, 'package.json'), 'utf8'))
            if (pkg.name?.startsWith('@deepseek-ai/') && existsSync(join(p, 'lib')))
              maybe(p, join(extra, basename(pkg.name)))
          } catch { /* unparseable */ }
        }
        walk(p)
      }
    }
    walk(join(harness, group))
  }
  console.log(`mirrored ${mirrored} packages → ${extra}`)
}

// --- Third-party dependency alignment (learned the hard way, 2026-08) -------
// Rules: (1) NEVER downgrade an installed dep whose version still satisfies
// the declared range — native packages (koffi + @koromix/*) break on mismatch;
// (2) copy missing/out-of-range deps from the repo, resolving from the
// dependent package's own directory (pnpm-isolated layout);
// (3) gate afterwards — this routine cannot prove runtime satisfaction.
import { createRequire } from 'node:module'
const supMods = join(sup, 'node_modules')
function satisfies(version, range) {
  const v = version.split('.').map(n => parseInt(n) || 0)
  if (range.startsWith('^')) { const r = range.slice(1).split('.').map(n => parseInt(n) || 0); return v[0] === r[0] && (v[1] > r[1] || (v[1] === r[1] && v[2] >= r[2])) }
  if (/^\d/.test(range)) return version === range
  return true // '*' / exotic ranges: trust the installed one
}
const depSources = new Map()
const repoWalk = (dir) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.name === 'node_modules' || !e.isDirectory()) continue
    if (existsSync(join(p, 'package.json'))) {
      try {
        const pkg = JSON.parse(readFileSync(join(p, 'package.json'), 'utf8'))
        if (pkg.name?.startsWith('@deepseek-ai/'))
          for (const [dep] of Object.entries(pkg.dependencies ?? {}))
            if (!dep.startsWith('@deepseek-ai/') && !depSources.has(dep)) depSources.set(dep, p)
      } catch { /* skip */ }
    }
    repoWalk(p)
  }
}
repoWalk(join(harness, 'packages')); repoWalk(join(harness, 'vendor')); repoWalk(join(harness, 'apps'))
const done = new Set()
// Locate a package directory without honoring its `exports` conditions:
// ESM-only packages (e.g. @earendil-works/pi-ai) expose only "import"
// conditions and no "./package.json", so createRequire().resolve()
// (CJS conditions) throws ERR_PACKAGE_PATH_NOT_EXPORTED for every probe.
// The dependent's pnpm-isolated node_modules always links the real dir,
// so walk ancestors on disk — that's exactly what runtime import does.
function lookupPkgDir(name, fromDir) {
  for (let dir = fromDir; ; dir = dirname(dir)) {
    const candidate = join(dir, 'node_modules', ...name.split('/'))
    if (existsSync(join(candidate, 'package.json'))) return candidate
    const parent = dirname(dir)
    if (parent === dir) return null
  }
}
function alignDep(name, fromDir) {
  if (done.has(name)) return
  done.add(name)
  try {
    const req = createRequire(join(fromDir, 'r.cjs'))
    let root
    try { root = dirname(req.resolve(`${name}/package.json`)) }
    catch {
      let p = null
      try { p = req.resolve(name) } catch { root = lookupPkgDir(name, fromDir) }
      if (!root && p) { while (!existsSync(join(p, 'package.json'))) p = dirname(p); root = p }
      if (!root) throw new Error(`${name} unresolvable by require or on disk`) 
    }
    const srcPkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
    const dst = join(supMods, ...name.split('/'))
    let dstVer = null
    try { dstVer = JSON.parse(readFileSync(join(dst, 'package.json'), 'utf8')).version } catch {}
    const range = JSON.parse(readFileSync(join(fromDir, 'package.json'), 'utf8')).dependencies?.[name] ?? '*'
    if (dstVer === null || !satisfies(dstVer, range)) {
      cpSync(root, dst, { recursive: true })
      console.log(`  aligned ${name} ${dstVer ?? '—'} → ${srcPkg.version}`)
    }
    for (const dep of Object.keys(srcPkg.dependencies ?? {}))
      if (!dep.startsWith('@deepseek-ai/')) alignDep(dep, root)
  } catch (e) { console.log(`  note: ${name} unresolvable from repo (${e?.code ?? e?.message} — optional or bundled; gate decides)`) }
}
for (const [n, d] of depSources) alignDep(n, d)
// koffi native sibling package: version must pair exactly
const koffiDir = join(supMods, 'koffi')
if (existsSync(koffiDir)) {
  const kv = JSON.parse(readFileSync(join(koffiDir, 'package.json'), 'utf8')).version
  const nativePkg = join(supMods, '@koromix', `koffi-${process.platform}-${process.arch}`)
  if (existsSync(nativePkg)) {
    const nv = JSON.parse(readFileSync(join(nativePkg, 'package.json'), 'utf8')).version
    if (nv !== kv) console.log(`  WARNING: koffi ${kv} vs native ${nv} — pair them before gating`)
  }
}
