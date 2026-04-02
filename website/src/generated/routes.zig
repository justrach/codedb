const Route = @import("../router.zig").Route;

const app_benchmarks = @import("app/benchmarks");
const app_index = @import("app/index");
const app_privacy = @import("app/privacy");
const app_quickstart = @import("app/quickstart");
const app_install = @import("app/install");

pub const routes: []const Route = &.{
    .{ .path = "/benchmarks", .render = app_benchmarks.render, .render_stream = if (@hasDecl(app_benchmarks, "renderStream")) app_benchmarks.renderStream else null, .meta = if (@hasDecl(app_benchmarks, "meta")) app_benchmarks.meta else .{}, .prerender = if (@hasDecl(app_benchmarks, "prerender")) app_benchmarks.prerender else false },
    .{ .path = "/", .render = app_index.render, .render_stream = if (@hasDecl(app_index, "renderStream")) app_index.renderStream else null, .meta = if (@hasDecl(app_index, "meta")) app_index.meta else .{}, .prerender = if (@hasDecl(app_index, "prerender")) app_index.prerender else false },
    .{ .path = "/privacy", .render = app_privacy.render, .render_stream = if (@hasDecl(app_privacy, "renderStream")) app_privacy.renderStream else null, .meta = if (@hasDecl(app_privacy, "meta")) app_privacy.meta else .{}, .prerender = if (@hasDecl(app_privacy, "prerender")) app_privacy.prerender else false },
    .{ .path = "/quickstart", .render = app_quickstart.render, .render_stream = if (@hasDecl(app_quickstart, "renderStream")) app_quickstart.renderStream else null, .meta = if (@hasDecl(app_quickstart, "meta")) app_quickstart.meta else .{}, .prerender = if (@hasDecl(app_quickstart, "prerender")) app_quickstart.prerender else false },
    .{ .path = "/install.sh", .render = app_install.render, .render_stream = null, .meta = .{}, .prerender = false },
};

const app_layout = @import("app/layout");
pub const layout = app_layout.wrap;
pub const streamLayout = if (@hasDecl(app_layout, "streamWrap")) app_layout.streamWrap else null;
const app_404 = @import("app/404");
pub const notFound = app_404.render;
