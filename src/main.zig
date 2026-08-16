const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const App = struct {
    env_map: *std.process.Environ.Map,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name ="dsh-native",
            .source = native_sdk.WebViewSource.url("http://127.0.0.1:41730/"),
            .source_fn = source,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self;
        return native_sdk.WebViewSource.url("http://127.0.0.1:41730/");
    }
};

const dev_origins = [_][]const u8{ "zero://app", "zero://inline", "http://127.0.0.1:41730" };

pub fn main(init: std.process.Init) !void {
    var app = App{ .env_map = init.environ_map };
    try runner.runWithOptions(app.app(), .{
        .app_name ="DeepSeek Harness",
        .window_title ="DeepSeek Harness",
        .bundle_id ="com.zereraz.dsh-native",
        .icon_path = "assets/icon.png",
        .security = .{
            .navigation = .{ .allowed_origins = &dev_origins },
        },
    }, init);
}

test "app name is configured" {
    try std.testing.expectEqualStrings("dsh-native","dsh-native");
}
