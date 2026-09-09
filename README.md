# dsh-native

A standalone **native** desktop app for [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh), built with [vercel-labs/native](https://github.com/vercel-labs/native) ("Native SDK") — no Electron, no bundled Chromium. The shell is a ~3 MB Zig binary; the dsh web dashboard renders in the system WebView (WebKit on macOS), driven by a small supervisor sidecar that runs the dsh runtime.

- One window, its own data home (`~/.dsh-native`) and WebView profile.
- Telemetry and message/command feedback hard-disabled — a privacy patch
  layer is installed into the profile on every boot.
- dsh web served on a fixed loopback port (`41730`), then loaded by the shell.

## Dev

```sh
cd supervisor && npm install   # one-time: fetch the @deepseek-ai/dsh runtime
cd .. && native build          # -> zig-out/bin/dsh-shell
```

Run it (two terminals):

```sh
node supervisor/dsh-web.mjs    # boots dsh web on 127.0.0.1:41730 + installs the privacy patch
zig-out/bin/dsh-shell          # the native window, pointed at the dashboard
```

`native check` validates `app.zon`; `native package --target macos` produces a distributable `.app`.

## Layout

- `app.zon` — window, bundle id, capabilities, `.frontend.dev` (URL + supervisor command), navigation security.
- `src/main.zig` — thin entry: `native_sdk.WebViewSource.url(...)`, window title, allowed origins. No JS runtime ships.
- `src/runner.zig` — SDK runner glue.
- `supervisor/` — Node sidecar: owns `DSH_HOME`, installs `config/cordis.patch.yml`, spawns `dsh web` with `--expose-internals`.
- `config/cordis.patch.yml` — the privacy patch layer (disables telemetry, message/command feedback, client HMR).

## Operational rules (load-bearing — learned from incidents)

These bind **any agent or human** touching this repo's lifecycle scripts. They
are not style preferences; each one exists because skipping it broke the
user's running app. The two mechanical gates at the bottom encode the worst
offenders — do not remove them.

1. **No tail-masked verdicts.** Never pipe a build/verify through `| tail`
   and call it green. Capture full output to a file; grep it for failure
   markers; quote the exit code. *(Incident: builds declared passing while
   failing; a staging run died silently twice mid-pipeline.)*
2. **Instrument before you patch.** When a failure's cause is unknown, add
   logging or a repro probe first — do not change shared code against a
   guess. *(Incident: a blind "fix" scattered 185 stray build files before
   the real root cause — stale ghost-package dirs — was found.)*
3. **Enumerate before you filter.** Any selection predicate (a walk, a
   gate, an allowlist) must print what it **drops**, never skip silently.
   *(Incident 01a06e17: a `lib/`-only gate silently dropped bin-only
   platform addon packages; boot stayed green and every user session
   resume crashed after activation.)*
4. **Interrupt-safe git.** After any aborted commit/rebase (lint hook,
   conflict markers), run `git status` + `git log` before the next
   mutation. Never blind `--amend`. *(Incident: an aborted-by-lint commit
   got folded into an unrelated patch by a later `--amend`.)*
5. **Empirical, not literary.** A claim about runtime behavior gets probed
   — curl, CLI, dynamic import — never asserted from reading source.
   *(Incident: restart-safety advice asserted from source was wrong on
   rollback order, blast radius, and session loss; all three corrected by
   empirical rebuttal.)*
6. **Fail loud, never silent-skip.** Every `catch`/`|| true` that swallows
   an error must print what it swallowed and why that is safe.

**Mechanical gates (do not remove):**
- `stage-app.mjs` — dependency-closure assertion: every `@deepseek-ai`
  internal dependency declared by any package in the candidate must exist
  on disk (host-platform variants required, others exempt). A dangling
  reference aborts staging before signing.
- `update-app.sh` gate — flock smoke: acquires a real file lock through
  the artifact's `node-addon-system` platform binary. Catches missing
  bin-only packages that boot-fresh gates cannot see.

## Roadmap

- Keep the full dsh web dashboard as-is for now.
- Over time, port focused surfaces (session list, status bar, model picker, approvals) to `.native` components beside the embedded dashboard via Native SDK `web_panes` / split windows.
