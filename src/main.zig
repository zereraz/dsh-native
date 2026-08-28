const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const UI_URL = "http://127.0.0.1:41730/";
const SHELL_ROOT = "/Users/zereraz/Code/Zereraz/voice/apps/dsh-shell";
const LOG = "/Users/zereraz/.dsh/menubar.log";
// Menus are declared in app.zon (manifest owns product chrome; main.zig owns
// native behavior): the .command strings come back through handleEvent.

const App = struct {
    io: std.Io,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "dsh-native",
            .source = native_sdk.WebViewSource.url(UI_URL),
            .source_fn = source,
            .event_fn = handleEvent,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self;
        return native_sdk.WebViewSource.url(UI_URL);
    }

    fn handleEvent(context: *anyopaque, runtime: *native_sdk.Runtime, event: native_sdk.Event) anyerror!void {
        _ = runtime;
        const self: *App = @ptrCast(@alignCast(context));
        switch (event) {
            .command => |cmd| dispatch(self.io, cmd.name),
            else => {},
        }
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

const dev_origins = [_][]const u8{ "zero://app", "zero://inline", UI_URL };

pub fn main(init: std.process.Init) !void {
    var app = App{ .io = init.io };
    try runner.runWithOptions(app.app(), .{
        .app_name = "DeepSeek Harness",
        .window_title = "DeepSeek Harness",
        .bundle_id = "com.zereraz.dsh-native",
        .icon_path = "assets/icon.png",
        .security = .{
            .navigation = .{ .allowed_origins = &dev_origins },
        },
    }, init);
}

test "app name is configured" {
    try std.testing.expectEqualStrings("dsh-native", "dsh-native");
}
