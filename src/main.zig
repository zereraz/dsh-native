const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

// One source, two installs: the main app (127.0.0.1:41730, ~/.dsh/web-url.txt)
// and the z2 tunnel app (127.0.0.1:41731, ~/.dsh/z2-web-url.txt) build from
// this same main.zig. The z2 LaunchAgent sets the env overrides; the main
// app keeps the defaults. Env values are resolved once, at runtime, in main.
fn envOrDefault(name: [:0]const u8, fallback: []const u8) []const u8 {
    const value = std.c.getenv(name) orelse return fallback;
    const spanned = std.mem.span(value);
    return if (spanned.len > 0) spanned else fallback;
}

const DEFAULT_UI_URL = "http://127.0.0.1:41730/";
const DEFAULT_WEB_URL_FILE = "/Users/zereraz/.dsh/web-url.txt";
var web_url_file: []const u8 = DEFAULT_WEB_URL_FILE;
var ui_url_fallback: []const u8 = DEFAULT_UI_URL;
const SHELL_ROOT = "/Users/zereraz/Code/Zereraz/voice/apps/dsh-shell";
const LOG = "/Users/zereraz/.dsh/menubar.log";

// The supervisor writes the authoritative URL (alpha+: carries the session
// token) to WEB_URL_FILE as soon as boots land. Resolve it dynamically so the
// native window loads exactly the session URL the server authenticated.
var url_buf: [512]u8 = undefined;
fn resolveUiUrl(io: std.Io) []const u8 {
    // ~20s tolerance for cold boots; beyond that the plain URL is the least-bad
    // choice (older bundles never write the file).
    var waited_ms: u64 = 0;
    while (waited_ms < 20_000) : (waited_ms += 200) {
        if (std.Io.Dir.cwd().readFileAlloc(io, web_url_file, std.heap.page_allocator, .limited(2048))) |raw| {
            const url = std.mem.trimEnd(u8, raw, "\r\n ");
            if (url.len > 7 and url.len <= url_buf.len) {
                @memcpy(url_buf[0..url.len], url);
                return url_buf[0..url.len];
            }
        } else |_| {}
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
    }
    return ui_url_fallback;
}
// Menus are declared in app.zon (manifest owns product chrome; main.zig owns
// native behavior): the .command strings come back through handleEvent.

// ---------------------------------------------------------------------------
// Backend-restart watch. The local dsh backend restarts by design (sentinel
// heap-creep restarts, crash-loop recovery, update applies) and the web
// client has no open-timeout of its own, so a window left on a dead backend
// shows "Loading history…" forever. The supervisor rewrites WEB_URL_FILE
// (fresh process token) on every boot — an exact restart signal. On change
// we reload the window onto the new authenticated URL.
const backend_watch_timer_id: u64 = 0x6473_6877; // "dshw" — below the SDK's reserved timer base
const backend_watch_interval_ns: u64 = 2 * std.time.ns_per_s;

/// Pure decision core for the backend-restart watch — no I/O, no runtime
/// calls, so the whole policy is unit-testable in CI (`zig build test
/// -Dplatform=null`). All state is owned here and touched only from the
/// platform loop thread.
const BackendWatch = struct {
    pending_buf: [512]u8 = undefined,
    pending_len: usize = 0,
    pending_count: u32 = 0,
    last_reload_ms: i64 = 0,

    /// A candidate must be seen on this many consecutive polls before we
    /// act, so a crash-looping backend (file flapping every few seconds)
    /// cannot trigger a reload storm.
    const debounce_polls: u32 = 2;
    /// At most one reload per interval, even if the file keeps changing.
    const min_interval_ms: i64 = 15_000;
    /// Smallest plausible boot url ("http://a.b") and the storage ceiling.
    const min_url_len: usize = 8;

    /// Decide what this poll's observed url means. Returns the url to
    /// reload onto (valid only until the caller frees the buffer it points
    /// into — copy it first), or null when nothing should happen.
    ///
    /// Policy: same url as shown → idle; a new url must survive
    /// `debounce_polls` consecutive polls AND the rate limit before it
    /// wins; anything flapping restarts the debounce.
    fn poll(self: *BackendWatch, current: []const u8, seen: []const u8, now_ms: i64) ?[]const u8 {
        if (seen.len < min_url_len or seen.len > self.pending_buf.len) return null;
        if (std.mem.eql(u8, seen, current)) {
            self.pending_count = 0;
            return null;
        }
        if (seen.len == self.pending_len and
            std.mem.eql(u8, seen, self.pending_buf[0..self.pending_len]))
        {
            self.pending_count += 1;
        } else {
            @memcpy(self.pending_buf[0..seen.len], seen);
            self.pending_len = seen.len;
            self.pending_count = 1;
            return null;
        }
        if (self.pending_count < debounce_polls) return null;
        if (now_ms - self.last_reload_ms < min_interval_ms) return null;
        self.pending_count = 0;
        self.last_reload_ms = now_ms;
        return seen;
    }
};

/// Monotonic milliseconds since an arbitrary origin (the duration clock).
/// Zig 0.16 routes std.time.milliTimestamp-style reads through std.Io; this
/// mirrors the SDK's own runtime clock helper (runtime/clock.zig).
fn monotonicMs() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {
            const ns: i128 = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            return @intCast(@divTrunc(@max(ns, 0), std.time.ns_per_ms));
        },
        else => return 0,
    }
}

/// A native window must never alter what the web app does — it is just a
/// window. Two hard rules enforce that here:
///
///  1. NAVIGATION IS NEVER CANCELLED for the app's own origin. The origin
///     allowlist is derived at runtime from the URL we actually load (plus
///     its host-form twin and the SDK's zero:// schemes), so any legitimate
///     navigation — token changes, redirects, host-form drift — always
///     passes the policy gate. The shell cannot silently swallow a
///     navigation and wedge the app on a spinner.
///  2. BACKEND RESTARTS HEAL THE WINDOW (see backend-restart watch above).
const App = struct {
    io: std.Io,
    ui_url: []const u8 = DEFAULT_UI_URL,

    /// Backend-restart watch — driven from the platform loop thread (timer
    /// events); see BackendWatch for the decision policy.
    watch_armed: bool = false,
    watch: BackendWatch = .{},

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "dsh-native",
            .source = native_sdk.WebViewSource.url(self.ui_url),
            .source_fn = source,
            .event_fn = handleEvent,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return native_sdk.WebViewSource.url(self.ui_url);
    }

    fn handleEvent(context: *anyopaque, runtime: *native_sdk.Runtime, event: native_sdk.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (event) {
            .lifecycle => |phase| {
                if (phase == .start and !self.watch_armed) {
                    self.watch_armed = true;
                    runtime.options.platform.services.startTimer(
                        backend_watch_timer_id,
                        backend_watch_interval_ns,
                        true,
                    ) catch {};
                }
            },
            .timer => |timer| {
                if (timer.id == backend_watch_timer_id) self.checkBackendUrl(runtime);
            },
            .command => |cmd| dispatch(self.io, cmd.name),
            else => {},
        }
    }

    /// Poll WEB_URL_FILE and hand the observed url to the watch policy;
    /// on a confirmed backend restart, reload onto the fresh url.
    fn checkBackendUrl(self: *App, runtime: *native_sdk.Runtime) void {
        const raw = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            web_url_file,
            std.heap.page_allocator,
            .limited(2048),
        ) catch return;
        defer std.heap.page_allocator.free(raw);
        const seen = std.mem.trimEnd(u8, raw, "\r\n \t");
        const reload_url = self.watch.poll(self.ui_url, seen, monotonicMs()) orelse return;

        // The backend restarted; the page currently shown is already broken
        // (its streams died with the old process), so reloading onto the
        // fresh authenticated URL is strictly better than leaving it wedged.
        // loadWindowWebView is the platform primitive the SDK's own reload
        // path uses; target the first live window's real id (1 when none
        // is registered yet, matching the SDK's own default).
        @memcpy(url_buf[0..reload_url.len], reload_url);
        self.ui_url = url_buf[0..reload_url.len];
        const window_id = if (runtime.window_count > 0) runtime.windows[0].info.id else 1;
        runtime.options.platform.services.loadWindowWebView(
            window_id,
            native_sdk.WebViewSource.url(self.ui_url),
        ) catch {};
    }
};

/// Menu clicks must never block the UI event loop: each action is handed to a
/// bash that forks the real work and exits, so the GUI only ever does a
/// spawn+wait of a wrapper. Outcomes arrive as macOS notifications; details
/// land in ~/.dsh/menubar.log.
fn dispatch(io: std.Io, command: []const u8) void {
    if (std.mem.eql(u8, command, "dsh.update.check")) {
        run(io, "nohup bash -c 'HARNESS_REPO=$HOME/Code/ds4/deepseek-harness bash \"" ++ SHELL_ROOT ++ "/scripts/update-app.sh\" && " ++
            "/usr/bin/osascript -e \"display notification \\\"Update installed — Apply & Restart whenever ready (DeepSeek Harness menu).\\\" with title \\\"DeepSeek Harness\\\"\" || " ++
            "/usr/bin/osascript -e \"display notification \\\"Update FAILED — see ~/.dsh/menubar.log\\\" with title \\\"DeepSeek Harness\\\"\" " ++
            "' >>" ++ LOG ++ " 2>&1 &");
    } else if (std.mem.eql(u8, command, "dsh.update.apply")) {
        run(io, "nohup bash -c 'bash \"" ++ SHELL_ROOT ++ "/scripts/restart-app.sh\" && " ++
            "/usr/bin/osascript -e \"display notification \\\"Restarted & verified.\\\" with title \\\"DeepSeek Harness\\\"\" || " ++
            "/usr/bin/osascript -e \"display notification \\\"Restart aborted or failed (active chats?) — see ~/.dsh/menubar.log\\\" with title \\\"DeepSeek Harness\\\"\" " ++
            "' >>" ++ LOG ++ " 2>&1 &");
    } else if (std.mem.eql(u8, command, "dsh.update.autoapply")) {
        // content-bearing flag: "1"/"0" (shares the menubar's new semantics;
        // missing file = ON, since 2026-08-28 default-ON product decision).
        run(io, "f=/Users/zereraz/.dsh/autoapply.enabled; cur=$(cat \"$f\" 2>/dev/null || echo 1); if [ \"$cur\" = 0 ]; then echo 1 > \"$f\"; n=ON; else echo 0 > \"$f\"; n=OFF; fi; " ++
            "/usr/bin/osascript -e \"display notification \\\"Auto-apply when idle: $n\\\" with title \\\"DeepSeek Harness\\\"\"");
    }
}

fn run(io: std.Io, script: []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/bash", "-c", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

// ---------------------------------------------------------------------------
// Navigation allowlist: derived at runtime from the URL we load (see App).
// Globals because the security policy references these slices for the whole
// app lifetime.
var origin_storage: [8][160]u8 = undefined;
var origin_slices: [8][]const u8 = undefined;
var origin_count: usize = 0;
var origin_twin_buf: [160]u8 = undefined;

fn rememberOrigin(origin: []const u8) void {
    if (origin_count >= origin_slices.len or origin.len > origin_storage[0].len) return;
    @memcpy(origin_storage[origin_count][0..origin.len], origin);
    origin_slices[origin_count] = origin_storage[origin_count][0..origin.len];
    origin_count += 1;
}

/// `scheme://host[:port]` of a URL, or the URL itself when it has no
/// authority component.
fn originOf(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    var end = url.len;
    for (url[scheme_end + 3 ..], scheme_end + 3 ..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            end = i;
            break;
        }
    }
    return url[0..end];
}

/// Same origin with the other loopback host spelling (127.0.0.1 <-> localhost),
/// so a host-form change between boots can never cancel a navigation.
fn twinOrigin(origin: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, origin, "://127.0.0.1")) |marker| {
        const at = marker + 3;
        return std.fmt.bufPrint(&origin_twin_buf, "{s}localhost{s}", .{
            origin[0..at],
            origin[at + "127.0.0.1".len ..],
        }) catch null;
    }
    if (std.mem.indexOf(u8, origin, "://localhost")) |marker| {
        const at = marker + 3;
        return std.fmt.bufPrint(&origin_twin_buf, "{s}127.0.0.1{s}", .{
            origin[0..at],
            origin[at + "localhost".len ..],
        }) catch null;
    }
    return null;
}

fn buildAllowedOrigins(loaded_url: []const u8) []const []const u8 {
    origin_count = 0;
    const origin = originOf(loaded_url);
    rememberOrigin(origin);
    if (twinOrigin(origin)) |twin| rememberOrigin(twin);
    rememberOrigin("zero://app");
    rememberOrigin("zero://inline");
    return origin_slices[0..origin_count];
}

// External links (anything outside the allowlist) keep going to the system
// browser, exactly as before.
const external_urls = [_][]const u8{"*"};

pub fn main(init: std.process.Init) !void {
    web_url_file = envOrDefault("DSH_WEB_URL_FILE", DEFAULT_WEB_URL_FILE);
    ui_url_fallback = envOrDefault("DSH_NATIVE_UI_URL", DEFAULT_UI_URL);
    const url = resolveUiUrl(init.io);
    var app = App{ .io = init.io, .ui_url = url };
    const allowed = buildAllowedOrigins(url);
    try runner.runWithOptions(app.app(), .{
        .app_name = "DeepSeek Harness",
        .window_title = "DeepSeek Harness",
        .bundle_id = "com.zereraz.dsh-native",
        .icon_path = "assets/icon.png",
        .security = .{
            .navigation = .{
                .allowed_origins = allowed,
                .external_links = .{ .action = .open_system_browser, .allowed_urls = &external_urls },
            },
        },
    }, init);
}

test "app name is configured" {
    try std.testing.expectEqualStrings("dsh-native", "dsh-native");
}

test "originOf extracts scheme host port" {
    try std.testing.expectEqualStrings("http://127.0.0.1:41730", originOf("http://127.0.0.1:41730/?token=abc"));
    try std.testing.expectEqualStrings("http://localhost:41731", originOf("http://localhost:41731/x/y"));
    try std.testing.expectEqualStrings("zero://app", originOf("zero://app"));
}

test "twinOrigin swaps loopback host spelling" {
    try std.testing.expectEqualStrings("http://localhost:41730", twinOrigin("http://127.0.0.1:41730").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:41731", twinOrigin("http://localhost:41731").?);
}

// BackendWatch policy tests. Timestamps are monotonic-since-boot scale
// (large), so the initial last_reload_ms = 0 never bites the rate limit.
const t0: i64 = 3_600_000; // one hour of uptime

test "BackendWatch ignores the url already shown" {
    var w = BackendWatch{};
    const a = "http://127.0.0.1:41730/?token=aaa";
    try std.testing.expect(w.poll(a, a, t0) == null);
    try std.testing.expect(w.poll(a, a, t0 + 999_999) == null);
}

test "BackendWatch fires only after two consecutive polls" {
    var w = BackendWatch{};
    const a = "http://127.0.0.1:41730/?token=aaa";
    const b = "http://127.0.0.1:41730/?token=bbb";
    try std.testing.expect(w.poll(a, b, t0) == null); // arms the candidate
    const fired = w.poll(a, b, t0 + 2_000);
    try std.testing.expect(fired != null);
    try std.testing.expectEqualStrings(b, fired.?);
}

test "BackendWatch restarts debounce when the url flaps" {
    var w = BackendWatch{};
    const a = "http://127.0.0.1:41730/?token=aaa";
    const b = "http://127.0.0.1:41730/?token=bbb";
    const c = "http://127.0.0.1:41730/?token=ccc";
    try std.testing.expect(w.poll(a, b, t0) == null); // arm b
    try std.testing.expect(w.poll(a, c, t0 + 2_000) == null); // flap resets to c
    // Without the reset this would fire (two b polls); with it, c needs
    // two of its own consecutive polls.
    const fired = w.poll(a, c, t0 + 4_000);
    try std.testing.expect(fired != null);
    try std.testing.expectEqualStrings(c, fired.?);
}

test "BackendWatch clears the candidate when the shown url returns" {
    var w = BackendWatch{};
    const a = "http://127.0.0.1:41730/?token=aaa";
    const b = "http://127.0.0.1:41730/?token=bbb";
    try std.testing.expect(w.poll(a, b, t0) == null); // arm b
    try std.testing.expect(w.poll(a, a, t0 + 2_000) == null); // back to a: reset
    // b must re-arm from scratch (one poll alone must NOT fire).
    try std.testing.expect(w.poll(a, b, t0 + 4_000) == null);
    try std.testing.expect(w.poll(a, b, t0 + 6_000) != null);
}

test "BackendWatch rate-limits reloads" {
    var w = BackendWatch{};
    const b = "http://127.0.0.1:41730/?token=bbb";
    const c = "http://127.0.0.1:41730/?token=ccc";
    const d = "http://127.0.0.1:41730/?token=ddd";
    // first reload fires at t0+2s
    try std.testing.expect(w.poll(b, c, t0) == null);
    try std.testing.expect(w.poll(b, c, t0 + 2_000) != null);
    // a second confirmed change 3s later must be held back…
    try std.testing.expect(w.poll(c, d, t0 + 3_000) == null);
    try std.testing.expect(w.poll(c, d, t0 + 5_000) == null); // blocked by rate limit
    // …and fires once the interval has passed.
    try std.testing.expect(w.poll(c, d, t0 + 18_000) != null);
}

test "BackendWatch rejects malformed urls without arming" {
    var w = BackendWatch{};
    const a = "http://127.0.0.1:41730/?token=aaa";
    const b = "http://127.0.0.1:41730/?token=bbb";
    try std.testing.expect(w.poll(a, "short", t0) == null);
    try std.testing.expect(w.poll(a, "", t0) == null);
    // junk did not arm anything: b still needs its own two polls.
    try std.testing.expect(w.poll(a, b, t0 + 2_000) == null);
    try std.testing.expect(w.poll(a, b, t0 + 4_000) != null);
}
