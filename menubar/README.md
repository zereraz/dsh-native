# DSH Menubar

Build/install: `bash menubar/build.sh`. It compiles and signs before replacing only the menubar, retaining `~/Applications/DSH Menubar.previous.app`. Add `--login-item` to register login startup.

## Everyday controls

- **Check & Update** builds/checks a harness candidate and stages the bundle. It does not replace the running app. The harness checkout must be clean and the upstream update must fast-forward; local patch rebases require review rather than an automatic merge.
- **Reload Backend** works whether or not an app update is pending. It refuses recent chat activity, stops only the primary launchd job, activates staged app/plugin candidates, and requires an authenticated boot graph and PTC success before marking completion. Failures drain the new host before recovery. No global `pkill` is used.
- **Build & Check** copies a plugin's current source and resolved dependencies to a separate release directory, runs its declared build/typecheck/test scripts, then imports its host entry. A failure leaves the profile and live source untouched.
- **Update & Check** fetches the plugin's configured upstream in a private clone, then performs those checks. It does not overwrite the developer checkout. Changed dependency declarations or lockfiles trigger a frozen-lock install in the private clone.
- **Log / Open Log** opens the complete command log, including while a build is running.

Plugin discovery reads `~/.dsh/profiles/web/package.json`. Plugins without a build script (currently Memory) can still be picked up by Reload Backend. Source revision is distinct from an activated release; “behavior unverified” means a real UI test is still needed. Changes to source after staging require rebuilding before activation.

Successful plugin preparation does not trigger automatic reload. Automatic app activation retains the user's Auto-apply preference and attempts each staged release at most once per menubar process. All menubar operations are mutually exclusive, and build/update/reload scripts share the lifecycle lock.

## Files and recovery

Logs: `~/.dsh/menubar-runs/<id>.log`, private permissions, with a 64 KiB result tail returned to the UI. Full output goes to a file rather than a pipe, avoiding verbose-build deadlocks. Discovery retains its latest output in `~/.dsh/menubar-runs/discovery.log`; a discovery failure directs Open Log there. Commands inherit the menubar environment unless an explicit environment is supplied.

Plugin releases: `~/Library/Application Support/DSH/plugin-releases/`. They include a copy of the resolved dependency graph, preserving cycles without links back to the developer dependency tree. The original source stays recorded in `~/.dsh/plugin-control.json`. Activation changes the profile dependency and its node_modules symlink to the checked release. `~/.dsh/plugin-activation.json` journals the old profile and links until readiness passes; failure restores them. Releases/logs are retained for diagnosis and are not automatically pruned.

App candidates: `~/Library/Application Support/DSH/app-releases/`, selected by `~/.dsh/app-candidate.json`. Reload copies the candidate beside the installed app before draining, then renames it into place. The previous app is retained for rollback. Candidate assembly no longer mirrors changes into the installed pocket-server runtime.

## Validation

`bash menubar/test.sh` runs the output regression, plugin preparation/activation/rollback tests, auth-readiness tests, and fully mocked update/restart lifecycle tests. No production process controls are exercised by these tests. Do not substitute the older preflight batteries for this suite; they retain unrelated legacy assumptions.

The idle gate is based on session-log modification times, not authoritative active-run state. A long-running tool with no recent writes can appear idle. Finish active work before reloading. Authenticated readiness and host import checks do not prove the plugin's UI behavior; use the plugin after reload.

This work does not rebuild the native Zig shell on every harness update, solve arbitrary upstream/local-patch conflicts, or replace the separate legacy shell-only `package-and-install.sh` path. That shell-only installer still needs its own lifecycle migration before use.

Log selection persists across launches in `menubar-runs/history.json`. A plugin Log button is disabled until that plugin has a recorded run. With no operation recorded, the general button opens Discovery Log, never the historical combined menubar log.
