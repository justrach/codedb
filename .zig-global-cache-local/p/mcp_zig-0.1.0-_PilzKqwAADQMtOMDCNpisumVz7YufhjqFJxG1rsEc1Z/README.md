<p align="center">
  <img src="assets/mcp-zig.png" alt="mcp-zig" width="600" />
</p>

# mcp-zig

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Build](https://github.com/justrach/mcp-zig/actions/workflows/build.yml/badge.svg)](https://github.com/justrach/mcp-zig/actions)
[![Zig](https://img.shields.io/badge/Zig-0.15-f7a41d.svg)](https://ziglang.org)

**Build MCP servers that fit in a tweet-sized binary.**

131 KB. Zero dependencies. Zero runtime. One static binary that gives Claude Code (or any MCP client) new capabilities.

```
zig build -Doptimize=ReleaseSmall && strip zig-out/bin/mcp-zig
# → 131 KB — 397x smaller than the TypeScript SDK
```

> **Your tools are written in Zig.** This is a Zig template — you write tool handlers as Zig functions. If you want to use Python or TypeScript, use the official SDKs. If you want a 131 KB binary with zero dependencies that starts in milliseconds, keep reading.

---

## Why this exists

Every MCP server I spun up for Claude Code came with 52 MB of `node_modules`. For a process that reads stdin and writes stdout. MCP over stdio is one JSON object per line — it doesn't need an async runtime, a schema validator, or a dependency injection framework.

So I built the thinnest possible implementation. The entire server is ~864 lines of Zig across 8 files. It compiles to a static binary you can drop in a dotfiles repo and forget about.

### How the SDKs compare

| SDK | Language | Distributable | Dependencies |
|-----|----------|---------------|-------------|
| [typescript-sdk](https://github.com/modelcontextprotocol/typescript-sdk) | TypeScript | **~52 MB** node_modules + Node.js | 17 npm packages + zod |
| [python-sdk](https://github.com/modelcontextprotocol/python-sdk) | Python | **~50+ MB** site-packages + Python | pydantic, httpx, anyio, starlette... |
| [csharp-sdk](https://github.com/modelcontextprotocol/csharp-sdk) | C# NativeAOT | **~8-15 MB** binary | System.Text.Json + reflection |
| [go-sdk](https://github.com/modelcontextprotocol/go-sdk) | Go | **~5-8 MB** binary | GC + reflect + encoding/json |
| [rust-sdk](https://github.com/modelcontextprotocol/rust-sdk) | Rust | **~2-4 MB** binary | tokio + serde_json + async runtime |
| **mcp-zig** | **Zig** | **131 KB** binary | **0** — just the Zig stdlib compiled in |

### What you ship

| SDK | Deployment |
|-----|-----------|
| TypeScript | `node_modules/` + your code + Node.js installation |
| Python | Virtual environment + your code + Python installation |
| C# / Go / Rust | Single binary (language toolchain to build) |
| **Zig** | **Single 131 KB binary** (Zig to build, nothing to run) |

---

## Important: tools are Zig

**mcp-zig is a Zig-native template.** Your tool handlers are Zig functions that write results to an `ArrayList(u8)`. You can't drop in a Python script or a TypeScript module.

**But you have escape hatches:**
- **C ABI interop** — Zig calls C natively. You can link against C libraries, Rust (`extern "C"`), or Go (cgo)
- **Shell out** — your handler can spawn any external process (`std.process.Child`) and pipe the output back as the tool response
- **MCP-to-MCP** — the included client library (`client.zig`) can call MCP servers written in *any* language over stdio, so you can build cross-language pipelines

If you're already in a Node.js or Python environment and just want tools fast, use the official SDKs. mcp-zig is for when you care about binary size, startup latency, zero dependencies, and distributable simplicity.

---

## Quick start

```bash
git clone https://github.com/justrach/mcp-zig.git
cd mcp-zig
zig build -Doptimize=ReleaseSmall
strip zig-out/bin/mcp-zig    # optional, shrinks further
```

Register with Claude Code in `~/.claude.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/absolute/path/to/mcp-zig",
      "args": []
    }
  }
}
```

Restart Claude Code. Your tools appear as `mcp__my-server__read_file`, `mcp__my-server__list_dir`, etc.

Requires [Zig 0.15](https://ziglang.org/download/).

---

## Use as a Zig package

Instead of cloning, you can import mcp-zig as a dependency in your own Zig project.

**1. Add to your `build.zig.zon`:**
```zig
.dependencies = .{
    .mcp_zig = .{
        .url = "https://github.com/justrach/mcp-zig/archive/main.tar.gz",
        .hash = "...",  // zig build will tell you the correct hash
    },
},
```

**2. Wire it in your `build.zig`:**
```zig
const mcp_dep = b.dependency("mcp_zig", .{});
exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
```

**3. Import in your code:**
```zig
const mcp = @import("mcp");

// Use the client
const McpClient = mcp.client.McpClient;
var client = try McpClient.init(alloc, &.{"/path/to/server"}, null);

// Use the registry
const my_tools = mcp.registry.Registry(&.{
    .{ .name = "my_tool", .handler = myHandler, .schema = my_schema },
});

// Use JSON helpers
const value = mcp.json.getStr(args, "key");
```

---

## Structure

```
src/
  main.zig           — entry point (5 lines of logic)
  lib.zig            — package root (re-exports public API)
  mcp.zig            — MCP protocol loop (JSON-RPC 2.0 over stdio)
  tools.zig          — YOUR TOOLS GO HERE (read_file + list_dir as examples)
  json.zig           — line reader, field extraction, JSON escaping
  registry.zig       — comptime tool registry (optional, reduces boilerplate)
  client.zig         — MCP client library (spawn server, call tools)
  client_example.zig — client CLI example
build.zig
build.zig.zon        — package manifest
```

**To add your own tools**, edit `tools.zig`. Or use `registry.zig` to cut it down to a single definition.

---

## Adding a tool — 4 steps

**1. Add to the enum:**
```zig
pub const Tool = enum {
    read_file,
    list_dir,
    my_new_tool,  // add here
};
```

**2. Add the JSON schema** (this is what Claude reads to understand your tool):
```zig
pub const tools_list =
    \\{"tools":[
    \\...,
    \\{"name":"my_new_tool","description":"Does something useful.","inputSchema":{"type":"object","properties":{"input":{"type":"string"}},"required":["input"]}}
    \\]}
;
```

**3. Add a dispatch branch:**
```zig
pub fn dispatch(...) void {
    switch (tool) {
        .read_file    => handleReadFile(alloc, args, out),
        .list_dir     => handleListDir(alloc, args, out),
        .my_new_tool  => handleMyNewTool(alloc, args, out),
    }
}
```

**4. Write the handler:**
```zig
fn handleMyNewTool(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const input = json.getStr(args, "input") orelse {
        out.appendSlice(alloc, "error: missing 'input'") catch {};
        return;
    };
    out.appendSlice(alloc, input) catch {};
}
```

Whatever you write to `out` becomes the tool response shown to Claude. Errors go to `out` too — never panic.

---

## Comptime registry — 1 step (optional)

`registry.zig` reduces the 4-step process to a single definition. It generates `parse()`, `dispatch()`, and `tools_list` at compile time.

```zig
const registry = @import("registry.zig");

const my_tools = registry.Registry(&.{
    .{ .name = "read_file",  .handler = handleReadFile,  .schema = read_file_schema },
    .{ .name = "list_dir",   .handler = handleListDir,   .schema = list_dir_schema  },
});

// my_tools.parse("read_file")   → 0
// my_tools.dispatch(alloc, 0, args, out)
// my_tools.tools_list           → combined JSON
```

### wrapFn — zero-boilerplate handlers

Write a normal Zig function and `wrapFn` generates the MCP handler at comptime:

```zig
fn greet(name: []const u8) []const u8 {
    return name;
}
const handler = registry.wrapFn(greet, &.{"name"});
```

`wrapFn` inspects the function signature at compile time and generates parameter extraction from JSON args (`[]const u8` → `getStr`, `i64` → `getInt`, `bool` → `getBool`). Error unions are caught and their error names written as error messages.

---

## Client — calling MCP servers from Zig

mcp-zig includes a client library for calling any MCP server programmatically — regardless of what language that server is written in.

### Library API

```zig
const McpClient = @import("client.zig").McpClient;

var client = try McpClient.init(alloc, &.{"/path/to/server"}, null);
defer client.deinit();

const init_result = try client.initialize();
defer alloc.free(init_result);
try client.notifyInitialized();

const tools = try client.listTools();
defer alloc.free(tools);

const result = try client.callTool("read_file", "{\"path\":\"hello.txt\"}");
defer alloc.free(result);
```

### One-shot convenience

```zig
const callOnce = @import("client.zig").callOnce;

// Spawn → initialize → call → return → clean up, in one call
const result = try callOnce(alloc, &.{"/path/to/server"}, "read_file", "{\"path\":\"hello.txt\"}");
defer alloc.free(result);
```

### CLI example

```bash
zig build
./zig-out/bin/mcp-client ./zig-out/bin/mcp-zig                          # list tools
./zig-out/bin/mcp-client ./zig-out/bin/mcp-zig read_file '{"path":"."}'  # call a tool
```

---

## Build options

```bash
zig build                              # debug (fast compile)
zig build -Doptimize=ReleaseSmall      # release (small binary)
strip zig-out/bin/mcp-zig              # shrink further
codesign --sign - --force zig-out/bin/mcp-zig   # macOS Apple Silicon only
```

---

## Protocol notes

MCP over stdio is **newline-delimited JSON-RPC 2.0** — one JSON object per line, no Content-Length headers (unlike LSP). The critical invariant: every write to stdout is exactly one JSON object followed by `\n`.

The `writeResult` function in `mcp.zig` strips `\n` and `\r` from result strings before writing. This matters because Zig `\\` multiline string literals embed literal newlines — without stripping, Claude Code's ReadBuffer would parse each line as a separate (invalid) JSON-RPC message and kill the server.

---

## Coming soon

- More example tools (database queries, HTTP requests, file watchers)
- Cross-compilation targets (Linux, Windows from macOS)
- Streamable HTTP transport (beyond stdio)
- Tool composition — chain tools together within a single server
- Benchmark suite for latency and throughput profiling

Have ideas? [Open an issue](https://github.com/justrach/mcp-zig/issues).

---

## License

MIT

---

**Blog post:** [mcp-zig: A 131 KB MCP Server Template in Zig](https://justrach.com/blog/building-mcp-servers-in-zig) — deeper dive into the architecture, benchmarks, and how it was built.
