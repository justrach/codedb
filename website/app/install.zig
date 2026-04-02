const mer = @import("mer");

pub const prerender = true;
pub fn render(req: mer.Request) mer.Response {
    _ = req;
    return .{
        .status = .ok,
        .content_type = .text,
        .body = @embedFile("install_script.sh"),
    };
}
