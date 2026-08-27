# CODEBASE.md — code-and-setup audit of dsh-native (2026-08-26, round 2)

Complement to REVIEW.md: that pass audited the *journey and docs*; this pass
read every line we own (1,931 LOC + launchd + manifests + menubar) and rates
each file on its own merits.

## Scoreboard

| File | Verdict | Notes |
|---|---|---|
| src/main.zig (90) | GOOD, 1 debt | hardcoded SHELL_ROOT/LOG (debt G) |
| src/runner.zig (815) | GOOD as-is | owned/ejected copy of SDK app_runner; resolve-manifest logic CONFIRMED; guard: re-eject clearly, diff quarterly |
| supervisor/dsh-web.mjs (84) | GOOD | shell-rc-env loading is deliberately lax; documented |
| scripts/update-app.sh (83) | GOOD, hardened today | flock added (concurrent fire = race) |
| scripts/restart-app.sh (115) | GOOD, hardened today | flock added |
| scripts/sync-runtime.mjs (117) | GOOD, 2 notes | satisfies() ignores prerelease semantics; alignDep first-resolution-wins per name (range-declare-skew edge) |
| scripts/package-and-install.sh | GOOD | never exercised; --skip-build exists for a dry run |
| scripts/verify-ptc.mjs | GOOD | tiny |
| config/cordis.patch.yml | GOOD | minimal |
| menubar/DSHMenubarApp.swift (249) | FIXED | file/UserDefaults auto-apply split-brain (see below) |
| build.zig | DEBT | `zig build package` hardcodes …-0.1.0-…; vestigial next to package-and-install (but UNUSED in the sanctioned path, so not harmful) |
| tests/eval.mjs (211) | LEGACY | old smoke eval; kept |
| .github | SMALL | fine |

## Setup

| Item | Verdict |
|---|---|
| LaunchAgents: com.zereraz.dsh-app (node, supervisor, KeepAlive, stdout log) | GOOD — note the pinned node path `/Users/zereraz/.nvm/versions/node/v22.22.3/bin/node` couples the supervisor to one nvm version (REVIEW debt D) |
| com.zereraz.dsh-autosnap (every 15m script into `~/.dsh/tools/`) | GOOD |
| com.zereraz.dsh-bridge.plist.bak | REMOVED today (retired-era file — final Electron residue) |
| ~/.dsh state (sessions, profiles, keystores, git autosnap) | GOOD |
| Host env hygiene: no NODE_OPTIONS, minimal PATH in launchd | GOOD |

## Findings fixed in this round

1. **Concurrent-fire race**: clicking the app-menu item fast (or menubar
   auto-apply + a manual Apply overlapping) could run update-app.sh +
   restart-app.sh in parallel — pipeline never had a mutual-exclusion guard.
   FIXED: `exec 9>…/.dsh/app-update.lock; flock -n 9` in both scripts; parser
   verified; runner.sh exits 4 when locked.
2. **Auto-apply toggle had TWO sources of truth** (SwiftUI UserDefaults in
   the menubar, `~/.dsh/autoapply.enabled` file from the app menu — desyncs on
   launch order). FIXED: file is the authority; UserDefaults synced from it;
   the menubar polls the file and writes back.
3. **The last Electron-era file on the machine**
   (`~/Library/LaunchAgents/com.zereraz.dsh-bridge.plist.bak`) — removed.

## Honest residual notes (accepted, documented)

- sync-runtime's satisfies() is a semver-lite that won't reject an rc-series
  mismatch — accepted because ALL install changes gate further downstream.
- runner.zig divergence from upstream is a living risk only on SDK releases
  that TOUCH app_runner (update-feeds era, maybe). Quarterly re-diff remains.
- `build.zig`'s step untouched ("-0.1.0-" artifact naming) — a trap for anyone
  who runs `zig build package` without the wrapper. Wrapper is the only blessed
  path; DEBT: delete that step or wire it to the manifest version.

## Verified in this round (mechanisms, not narration)

- `bash -n` parses on every script after edits (flock insertions + wrapper)
- menubar rebuilt/installed/running with the synced toggle contract
- rebuild of zig shell NOT required (no zig-src edits in this round)
- the only `/tmp` documentation I kept is the settings backup (copied to
  dsh-repair)

## Round 3 (goal-driven): the update pipeline, made testable, and the bug THAT exposed

Test-first iteration over the whole click path (update-app.sh --restart,
restart-app.sh, package-and-install.sh):
- UNIFIED the stamp function: the Python 3 duplicate implementations with
  drifting shapes became ONE script (scripts/stamp-update-state.mjs) with
  environment-overridable state path. Property-checked: ISO8601 parseability,
  install→applied order, install-invalidates-appliedAt.
- CRITICAL CATCH: the flock-based lock(PREV commit of this repo) breaks under
  the users' own launchd PATH (no flock binary) — and a MISSING flock is
  identify-identical to a held lock, meaning the pipeline would have died
  politely on every menu-click from TODAY onward. Ported the lock to POSIX
  atomic `mkdir`: no external dep, no false-gate failure mode, trap-released.
- Live behavioral evidence (not log-babble): held lock ⇒ exit 4; busy chats
  ⇒ exit 3 + port 41730 untouched; stamp semantics round-trip; all wrappers
  `bash -n`.
Know-limit: the end-to-end REAL cycle (quit→drain→relaunch→rollback) was
piecewise exercised (prelim cycles + drain/health probes) but the user-owned
final fire remains HIS click. No further self-incident last words.
