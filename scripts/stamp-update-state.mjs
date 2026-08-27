// stamp-update-state.mjs — single source of truth for ~/.dsh/update-state.json.
// Replaces the three inline python copies that drifted in shape across
// update-app.sh / restart-app.sh / package-and-install.sh.
//
//   stamp-update-state.mjs installed <app>        (after a swap: resets appliedAt)
//   stamp-update-state.mjs applied <app>          (after restart-app verified: appliedAt=now)
//   stamp-update-state.mjs <custom-status> <app>  (escape hatch)
//
// Env overrides for tests: DSH_STATE_FILE (default ~/.dsh/update-state.json),
// DSH_LOCALE_TZ ignored — always local %z offset (matches the menubar's
// "yyyy-MM-dd'T'HH:mm:ssZ" parser).
import { readFileSync, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

const [action, app] = process.argv.slice(2)
if (!action || !app) {
  console.error('usage: stamp-update-state.mjs <installed|applied|custom> <bundle-path>')
  process.exit(2)
}

const stateFile = process.env.DSH_STATE_FILE || join(homedir(), '.dsh', 'update-state.json')
const version = execFileSync('/usr/libexec/PlistBuddy',
  ['-c', 'Print :CFBundleShortVersionString', join(app, 'Contents', 'Info.plist')],
  { encoding: 'utf8' }).trim()
const d = new Date()
const pad = n => String(n).padStart(2, '0')
const tz = -d.getTimezoneOffset()
const sign = tz >= 0 ? '+' : '-'
const now = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${sign}${pad(Math.floor(Math.abs(tz) / 60))}${pad(Math.abs(tz) % 60)}`

let old = {}
try { old = JSON.parse(readFileSync(stateFile, 'utf8')) } catch { /* fresh */ }
const next = {
  version,
  installedAt: action === 'applied' ? old.installedAt : (old.installedAt ?? now),
  appliedAt: action === 'applied' ? now : (action === 'installed' ? null : old.appliedAt),
  lastAction: action,
  lastActionStatus: `${action}${action === 'installed' ? ` v${version}` : ''}`,
}
// an installed action always invalidates any prior appliedAt from the SAME version
if (action === 'installed') next.appliedAt = null
writeFileSync(stateFile, JSON.stringify(next, null, 2) + '\n')
console.log(`stamped ${action} v${version} → ${stateFile}`)
