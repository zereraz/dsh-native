// dsh-native launcher: the .app's CFBundleExecutable. Boots the dsh web
// runtime via the system Node on PATH, waits until it answers HTTP 200,
// then hands off to the real Native SDK shell binary. `zig build run` /
// `native dev` skip this file entirely; it exists so a double-clicked .app
// is self-starting.
const std = @import("std");

const URL = "http://127.0.0.1:41730/";
const REUSE_CANDIDATES = [_][]const u8{ "http://127.0.0.1:41730/", "http://127.0.0.1:3080/" };

/// Probe an existing dsh web server before spawning ours: a workbench server
/// (3080) or a leftover app server (41730) is reused so only ONE dsh web
/// process owns the session state at a time. DSH_NATIVE_SERVER_URL wins.
fn dshServerUrl(io: std.Io, alloc: std.mem.Allocator) ?[]const u8 {
    var client: std.http.Client = .{ .io = io, .allocator = alloc };
    defer client.deinit();
    for (&REUSE_CANDIDATES) |url| {
        const res = client.fetch(.{ .location = .{ .url = url }, .keep_alive = false }) catch continue;
        if (res.status != .ok) continue;
        return url;
    }
    return null;
}

/// Locate the node binary without assuming an install manager: newest nvm
/// install first, then homebrew, then /usr/local. Caller wraps in `try`.
fn findNode(io: std.Io, alloc: std.mem.Allocator, home: []const u8) ![]const u8 {
    const nvm_dir = try std.fs.path.join(alloc, &.{ home, ".nvm/versions/node" });
    if (newestNvmNode(io, alloc, nvm_dir) catch null) |best| return best;
    const fixed = [_][]const u8{ "/opt/homebrew/bin/node", "/usr/local/bin/node" };
    for (fixed) |candidate| {
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return candidate;
    }
    return error.NodeBinaryNotFound;
}

/// Pick `vMAJOR.MINOR.PATCH/bin/node` with the highest version under dir.
fn newestNvmNode(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) !?[]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    // Versions packed into u128 compare as plain ints: major<<60|minor<<30|patch.
    var best: u128 = 0;
    var best_path: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const name = entry.name;
        if (name.len < 2 or name[0] != 'v') continue;
        var parts: [3]u128 = .{ 0, 0, 0 };
        var tok = std.mem.tokenizeScalar(u8, name[1..], '.');
        var i: usize = 0;
        var valid = true;
        while (tok.next()) |piece| : (i += 1) {
            if (i >= parts.len) break;
            parts[i] = std.fmt.parseInt(u128, piece, 10) catch {
                valid = false;
                break;
            };
        }
        if (!valid) continue;
        const packed_v = (parts[0] << 60) | (parts[1] << 30) | parts[2];
        if (packed_v <= best) continue;
        const candidate = try std.fs.path.join(alloc, &.{ dir_path, name, "bin", "node" });
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        best = packed_v;
        best_path = candidate;
    }
    return best_path;
}

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

    // 1) Server: reuse an already-running dsh web (DSH_NATIVE_SERVER_URL
    // override first) so at most ONE harness server runs at a time; only
    // when nothing answers do we spawn our own supervisor (which owns
    // DSH_HOME, installs the privacy patch layer, binds 127.0.0.1:41730).
    const target_url: []const u8 = init.environ_map.get("DSH_NATIVE_SERVER_URL") orelse
        dshServerUrl(init.io, alloc) orelse spawn: {
        const home = init.environ_map.get("HOME") orelse "/tmp";
        const node_path = init.environ_map.get("DSH_NODE") orelse try findNode(init.io, alloc, home);
        const sup = try std.process.spawn(init.io, .{
            .argv = &.{ node_path, supervisor },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = sup;
        // Wait for dsh to answer before opening the window — otherwise the
        // WebView paints a blank page that never recovers even after dsh is up.
        waitForDsh(init.io, alloc);
        break :spawn URL;
    };

    // 3) The real shell, in the foreground, pointing at the local dashboard.
    // Environ.Map has no (environ_map) init in 0.16; skip env tweaking —
    // the shell's default source already points at 127.0.0.1:41730.
    var env = init.environ_map.*;
    try env.put("NATIVE_SDK_FRONTEND_URL", target_url);
    var shell = try std.process.spawn(init.io, .{
        .argv = &.{shell_path},
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
    });
    _ = try shell.wait(init.io);
}
