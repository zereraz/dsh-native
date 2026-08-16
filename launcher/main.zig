// dsh-native launcher: the .app's CFBundleExecutable. Boots the dsh web
// runtime via the system Node on PATH, waits until it answers HTTP 200,
// then hands off to the real Native SDK shell binary. `zig build run` /
// `native dev` skip this file entirely; it exists so a double-clicked .app
// is self-starting.
const std = @import("std");

const URL = "http://127.0.0.1:41730/";

fn waitForDsh(io: std.Io, alloc: std.mem.Allocator) void {
    var client: std.http.Client = .{ .io = io, .allocator = alloc };
    defer client.deinit();
    var i: u32 = 0;
    while (i < 300) : (i += 1) { // ~30 s @ 100 ms
        const res = client.fetch(.{ .location = .{ .url = URL }, .keep_alive = false }) catch {
            std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .boot) catch {};
            continue;
        };
        if (res.status == .ok) return;
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .boot) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;

    // .../dsh-native.app/Contents/MacOS/<this binary>
    const exe_path = try std.process.executablePathAlloc(init.io, alloc);
    const macos_dir = std.fs.path.dirname(exe_path).?;
    const contents_dir = std.fs.path.dirname(macos_dir).?;
    const resources_dir = try std.fs.path.join(alloc, &.{ contents_dir, "Resources" });
    const shell_path = try std.fs.path.join(alloc, &.{ macos_dir, "dsh-native-shell" });
    const supervisor = try std.fs.path.join(alloc, &.{ resources_dir, "supervisor", "dsh-web.mjs" });

    // 1) dsh web runtime as a detached child (owns DSH_HOME, installs the
    // privacy patch layer, binds 127.0.0.1:41730).
    const sup = try std.process.spawn(init.io, .{
        .argv = &.{ "node", supervisor },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = sup;

    // 2) Wait for dsh to answer before opening the window — otherwise the
    // WebView paints a blank page that never recovers even after dsh is up.
    waitForDsh(init.io, alloc);

    // 3) The real shell, in the foreground, pointing at the local dashboard.
    // Environ.Map has no (environ_map) init in 0.16; skip env tweaking —
    // the shell's default source already points at 127.0.0.1:41730.
    var env = init.environ_map.*;
    try env.put("NATIVE_SDK_FRONTEND_URL", URL);
    var shell = try std.process.spawn(init.io, .{
        .argv = &.{shell_path},
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
    });
    _ = try shell.wait(init.io);
}
