# REVIEW.md — honest audit of the native app engineering (2026-08-26)

Prompt for this pass: "did we make things in a hurry or do it right?"
Method: read the SDK's own rulebook (skill-data in @native-sdk/cli 0.10.1),
diff every rule against our repo, replay our full history with incidents on it.

## Verdict

**Half and half.** The backbone (supervisor-launch + sanctioned pipeline +
rollback + gates) is solid and has already survived real failures. The app
surface (config drift in main.zig / owned runner / packaging) accumulated
hurry debt — mostly in the Aug-24→Aug-26 stretch where we were firefighting
instead of engineering, and a couple of times recently shipped WITHOUT
running the pipeline's own gates. Every hurry item found is listed below,
each tagged FIXED (this session) / GUARD (script now prevents) / DEBT (filed).

## The journey, replayed

| When | What happened | Class |
|---|---|---|
| Aug 15–21 | First zig shell built (then-SDK 0.9.5 era, owned build.zig + runner) | legitimate early scaffold |
| Aug 22 | Stack rewired through npm install inside supervisor; `dsh-native-launcher` binary left in zig-out/bin | hurry (artifact rot) |
| Aug 23 | dsh-split saga: heredoc-generated code, watched-then-killed restarts, embed-flag bug shipped into prod | hurry (tooling discipline) |
| Aug 24 15:21 | Watcher swapped app bundle UNDER the live host (rm -rf + ditto) → deleted-cwd incident #2 (uv_cwd wipe out of every PTC run for 24h) | hurry (no quit-before-swap) |
| Aug 25 | Root-caused uv_cwd, fix + 211 tests + bundle verification — done RIGHT | solid |
| Aug 25 11:19 | Fix commit 933bcc176c — but app not rebuilt until 26th | solid analysis, delayed release |
| 26th 04:01/04:47 | Two agent-host restarts while guzzling fixes | enforced etiquette since |
| 26th ~05:00 | update-app.sh run with health gate + rollback: the FIRST fully sanctioned update | solid |
| 26th ~05:30 | I shortcut a shell-only swap with bare `native package` → bundle RESEEDED supervisor from npm metadata, silently dropping the local PTC fix | hurry — CAUGHT before shipping, fixed |
| 26th ~06:00 | Menus + tutorial-correct open_system_browser published | solid |

## What's solid (keep, celebrate)

- **supervisor/dsh-web.mjs**: singleton, reuse-or-spawn, ready-file gating;
  launchctl KeepAlive as the honest supervisor (it crashed/restarted ~15 times
  this week and kept coming back correctly).
- **update-app.sh**: snapshot → pull/rebase → build -> runtime sync (incl.
  third-party alignment) → HEALTH GATE on a THROWAWAY port with a throwaway
  home → swap + rollback copy. The gate already blocked bad ships.
- **restart-app.sh**: activity gate against live chats, graceful drain,
  verify-or-rollback. The "everything you kill stops every agent" complaint is
  structurally answered.
- **~/.dsh git autosnap** every 15 min: crash insurance has paid off twice.
- **Session corruption fixed properly**: fail-soft listing + session-doctor,
  upstreamable patches in dsh-repair/patches/.
- **PTC fix** (worker-thread cwd re-anchor): minimal, tested, three-layer
  verified.
- Privacy profile (cordis.patch.yml) cleanly central.

## What was made in a hurry (and the fix for each)

1. `native build --manifest''` style mixing + version bumps by sed —
   FIXED: version is read from Info.plist everywhere now;
   `scripts/package-and-install.sh` is the single shell-only install path.
2. Shell-only swap skipping runtime sync (npm-reseed regression) —
   GUARD: package-and-install.sh REFUSES to install when the harness-repo
   runtime is absent from the artifact (checks for the PTC fix marker).
3. `say + "graceful relaunch cycle"` (typo shipped to main) — FIXED.
4. `native check` never ran before ships — GUARD: package-and-install.sh runs it.
5. Stale `dsh-native-launcher` in zig-out/bin from Aug 22 — FIXED (removed).
6. Menus declared in main.zig instead of the manifest —
   FIXED: moved to app.zon (manifest owns product chrome per the anatomy doc's
   layering rule; `native check` validates it).
7. Docs DISCOVERED DURING THIS REVIEW that capacity existed (menus,
   tray, dialog, notifications as declared capabilities; Update feeds) — we
   BROKE the layering rule by inventing parallel custom systems first.
   DEBT: document "ask SDK docs first" in AGENTS-level flow.

## Real debt (filed, not silently left)

A. **Owned build**: we carry a 815-line src/runner.zig + build.zig fork of the
   SDK's app_runner. Risk: SDK fixes won't flow to us unless re-ejected and
   re-diffed. DEBT: quarterly `native eject` diff, or migrate to the
   zero-config lane (`.native/build/`, no owned build files).
B. **native update feeds**: the REAL update channel (signed Ed25519).
   Today: custom update-app.sh + update-state.json + menubar extra. DEBT:
   migrate when SDK updates work end-to-end (Debug-test linking is broken in
   0.10.1 for our config — upstream issue: `_native_sdk_update_verify_*`
   unresolved in the Debug test target; production build unaffected).
C. **StreamTooLong** in `native package` on libvips-cpp.8.18.3.dylib (17.7MB).
   Both 0.9.5 and 0.10.1. DEBT: report upstream with the repro
   (attempt: pack a big Mach-O inside frontend dist).
D. **Parallel node installs**: @native-sdk/cli found in BOTH the nvm prefix
   and ~/.pocket-server — `npm root -g` whichever terminal resolves — two
   different installs with potentially different SDK pins. DEBT: pick ONE
   prefix (pocket-server, since that's where 0.10.1 currently lives) and wipe
   the other.
E. **No identity signing / notarization** — adhoc only. Fine on this Mac;
   DEBT: Developer ID + notarize before ANY other machine consumes the app.
F. **CEF fallback untested** — if system WebKit eats a DSH UI update badly,
   we have a documented fallback (`native cef install` + manifest flip) but
   never rehearsed it.
G. **Hardcoded /Users/zereraz/Code/... path in src/main.zig (SHELL_ROOT and
   LOG)**: the app binary only works on THIS machine's directory layout.
   DEBT: resolve scripts + state/logs relative to the bundle or via env vars
   (DSH_HOME-style), or admit permanently local-only usage.
H. **Menubar extra**: SwiftUI MenuBarExtra app (~180 lines, no Xcode project,
   hand-signed adhoc, login item via osascript System Events). Working v1;
   DEBT: worth re-implementing as the SDK's native `tray` capability once the
   app becomes more than a WebView wrapper.

## What the docs changed my mind about DURING this review

- `.menus` belongs in the manifest (done).
- `native check` belongs in the pipeline (done).
- The `--service-binary` packaged daemon should eventually swallow
  supervisor+launchd-plist entirely (README-shaped future).
- `external_links` should have been `open_system_browser` from day one —
  fixed in v0.2.1 (the "links in the chat do nothing" report).

## Release-grade recommendation

1. Keep the current pipeline as-is for USD (it's honest and gated).
2. Use ONLY update-app.sh (full) or package-and-install.sh (shell-only);
   anything else is now an unknown-risk manual act.
3. Rub the machine onto ONE npm prefix (item D).
4. Resume `native test` after filing the SDK Debug-link issue upstream.
5. When update feeds stabilize, retire: update-state.json, menubar extra,
   restart-app.sh — replacing with `native update sign` + in-app
   checkForUpdatesMenu — and document the retirement in release notes.

## 2026-08-28 (pull sweep): alpha's authentication break — STAY on dsh-v0.1.1-rc.2
- Upstream shipped dsh-0.1.2-alpha.1 (1000+ commits): `dsh web` now issues a
  URL token and answers `/` with **401** when token-less. The native app flow
  embeds the UI via plain webview URL — it CANNOT ride this contract today.
- Decision: app pins **dsh-v0.1.1-rc.2 + our 3 patches** (pristine worktree
  build + marker census proven) until a tagged mild version with a documented
  embedded-app auth handoff (or upstream documents the token's local path).
- DEBT: pipelines must fetch-with-token when the token becomes primary; the
  health gate's bare `curl /` will need the token URL from the boot log.
