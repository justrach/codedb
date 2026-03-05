// mcp-zig — Comptime tool registry
//
// Reduces tool registration from 4 manual steps to 1:
//   const my_tools = registry.define(.{
//       .{ "read_file",  handleReadFile,  read_file_schema },
//       .{ "list_dir",   handleListDir,   list_dir_schema  },
//   });
//
// Generates parse(), dispatch(), and tools_list at comptime.
// Also provides wrapFn() to wrap simple Zig functions as MCP handlers.

const std = @import("std");
const json = @import("json.zig");

/// Handler function signature for MCP tools.
pub const Handler = *const fn (std.mem.Allocator, *const std.json.ObjectMap, *std.ArrayList(u8)) void;

/// A single tool definition.
pub const ToolDef = struct {
    name: []const u8,
    handler: Handler,
    schema: []const u8, // JSON fragment: {"name":"...","description":"...","inputSchema":{...}}
};

/// Define a tool registry from an array of ToolDefs.
/// Returns a struct with parse(), dispatch(), and tools_list.
pub fn Registry(comptime defs: []const ToolDef) type {
    return struct {
        /// Parse a tool name string into an index. Returns null if unknown.
        pub fn parse(name: []const u8) ?usize {
            inline for (defs, 0..) |def, i| {
                if (std.mem.eql(u8, name, def.name)) return i;
            }
            return null;
        }

        /// Dispatch a parsed tool index.
        pub fn dispatch(
            alloc: std.mem.Allocator,
            index: usize,
            args: *const std.json.ObjectMap,
            out: *std.ArrayList(u8),
        ) void {
            inline for (defs, 0..) |def, i| {
                if (index == i) {
                    def.handler(alloc, args, out);
                    return;
                }
            }
        }

        /// Combined tools/list JSON response, generated at comptime.
        pub const tools_list = blk: {
            var buf: []const u8 = "{\"tools\":[";
            for (defs, 0..) |def, i| {
                if (i > 0) buf = buf ++ ",";
                buf = buf ++ def.schema;
            }
            buf = buf ++ "]}";
            break :blk buf;
        };

        /// Number of registered tools.
        pub const count = defs.len;

        /// Get tool name by index.
        pub fn nameAt(index: usize) []const u8 {
            inline for (defs, 0..) |def, i| {
                if (index == i) return def.name;
            }
            return "unknown";
        }
    };
}

// ── wrapFn: wrap simple Zig functions as MCP handlers ────────────────────────
//
// Takes a function with typed parameters and wraps it into the Handler signature.
// Parameter extraction is done via json.getStr/getInt/getBool based on type.
//
// Supported parameter types:
//   []const u8  → json.getStr(args, param_name)
//   i64         → json.getInt(args, param_name)
//   bool        → json.getBool(args, param_name)
//
// The wrapped function can return:
//   []const u8  → written directly to out
//   void        → nothing written
//   ![]const u8 → on error, error message written
//
// Example:
//   fn greet(name: []const u8) []const u8 { return name; }
//   const handler = registry.wrapFn(greet, &.{"name"});

/// Wrap a function with named JSON parameters into an MCP Handler.
/// `param_names` maps positional parameters to JSON field names.
pub fn wrapFn(
    comptime func: anytype,
    comptime param_names: []const []const u8,
) Handler {
    const F = @TypeOf(func);
    const info = @typeInfo(F).@"fn";

    return struct {
        fn handler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
            // Extract parameters at comptime
            var params: std.meta.ArgsTuple(F) = undefined;
            inline for (info.params, 0..) |param, i| {
                const name_str = param_names[i];
                const T = param.type.?;

                if (T == []const u8) {
                    params[i] = json.getStr(args, name_str) orelse {
                        out.appendSlice(alloc, "error: missing '") catch {};
                        out.appendSlice(alloc, name_str) catch {};
                        out.appendSlice(alloc, "'") catch {};
                        return;
                    };
                } else if (T == i64) {
                    params[i] = json.getInt(args, name_str) orelse 0;
                } else if (T == bool) {
                    params[i] = json.getBool(args, name_str);
                } else if (T == std.mem.Allocator) {
                    params[i] = alloc;
                } else {
                    @compileError("wrapFn: unsupported parameter type for '" ++ name_str ++ "'");
                }
            }

            // Call the function
            const ReturnType = info.return_type.?;
            if (@typeInfo(ReturnType) == .error_union) {
                if (@call(.auto, func, params)) |result| {
                    const R = @TypeOf(result);
                    if (R == []const u8 or R == []u8) {
                        out.appendSlice(alloc, result) catch {};
                    }
                } else |err| {
                    out.appendSlice(alloc, "error: ") catch {};
                    out.appendSlice(alloc, @errorName(err)) catch {};
                }
            } else {
                const result = @call(.auto, func, params);
                if (ReturnType == []const u8 or ReturnType == []u8) {
                    out.appendSlice(alloc, result) catch {};
                }
                // void return: nothing to write
            }
        }
    }.handler;
}
