// dsh-native launcher: the .app's CFBundleExecutable. Boots the dsh web
// runtime via the system Node on PATH, then hands off to the real Native SDK
// shell binary. `zig build run` / `native dev` skip this file entirely; it
// only exists so a double-clicked .app is self-starting.
const std = @import("std");

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

    // 2) The real shell, in the foreground, pointing at the local dashboard.
    // Environ.Map has no (environ_map) init in 0.16; skip env tweaking —
    // the shell's default source already points at 127.0.0.1:41730.
    var env = init.environ_map.*;
    try env.put("NATIVE_SDK_FRONTEND_URL", "http://127.0.0.1:41730/");
    var shell = try std.process.spawn(init.io, .{
        .argv = &.{shell_path},
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
    });
    _ = try shell.wait(init.io);
}
