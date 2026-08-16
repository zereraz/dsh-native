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

## Roadmap

- Keep the full dsh web dashboard as-is for now.
- Over time, port focused surfaces (session list, status bar, model picker, approvals) to `.native` components beside the embedded dashboard via Native SDK `web_panes` / split windows.
