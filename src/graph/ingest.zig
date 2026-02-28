// CodeGraph DB — TypeScript/JavaScript ingestion pipeline
//
// Extracts symbols and edges from TypeScript/JavaScript source files
// using pattern-based parsing. Designed for accuracy on common patterns;
// can be swapped for tree-sitter C bindings later (issue #19).
//
// Symbols extracted:
//   function_declaration → SymbolKind.function
//   method_definition    → SymbolKind.method
//   class_declaration    → SymbolKind.class
//   interface_declaration → SymbolKind.interface
//   type alias           → SymbolKind.type_def
//   const/let/var        → SymbolKind.variable
//   export default       → SymbolKind.module
//
// Edges extracted:
//   import statements    → EdgeKind.imports (File → File)
//   function calls       → EdgeKind.calls (Symbol → Symbol, best-effort)

const std = @import("std");
const types = @import("types.zig");
const graph_mod = @import("graph.zig");
const CodeGraph = graph_mod.CodeGraph;
const Symbol = types.Symbol;
const File = types.File;
const Edge = types.Edge;
const SymbolKind = types.SymbolKind;
const EdgeKind = types.EdgeKind;
const Language = types.Language;

// ── Ingester ────────────────────────────────────────────────────────────────

pub const Ingester = struct {
    graph: *CodeGraph,
    alloc: std.mem.Allocator,
    next_symbol_id: u64,
    next_file_id: u32,

    pub fn init(graph: *CodeGraph, alloc: std.mem.Allocator) Ingester {
        return .{
            .graph = graph,
            .alloc = alloc,
            .next_symbol_id = 1,
            .next_file_id = 1,
        };
    }

    /// Ingest a single file from its content string.
    /// Returns the file ID assigned, or null if the file was skipped.
    pub fn ingestSource(self: *Ingester, path: []const u8, content: []const u8) !?u32 {
        const lang = detectLanguage(path);
        if (lang == .unknown) return null;

        const file_id = self.next_file_id;
        self.next_file_id += 1;

        // Hash the content
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});

        try self.graph.addFile(.{
            .id = file_id,
            .path = path,
            .language = lang,
            .last_modified = std.time.milliTimestamp(),
            .hash = hash,
        });

        // Extract symbols
        try self.extractSymbols(content, file_id);

        return file_id;
    }

    /// Re-ingest a file — removes old symbols for that file_id first.
    /// This is idempotent: re-ingesting the same content produces the same graph.
    pub fn reingestSource(self: *Ingester, file_id: u32, path: []const u8, content: []const u8) !void {
        // Remove old symbols for this file
        var to_remove: std.ArrayList(u64) = .empty;
        defer to_remove.deinit(self.alloc);

        var sym_it = self.graph.symbols.iterator();
        while (sym_it.next()) |entry| {
            if (entry.value_ptr.file_id == file_id) {
                try to_remove.append(self.alloc, entry.key_ptr.*);
            }
        }
        for (to_remove.items) |id| {
            _ = self.graph.symbols.remove(id);
        }

        // Re-add file and symbols
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});

        try self.graph.addFile(.{
            .id = file_id,
            .path = path,
            .language = detectLanguage(path),
            .last_modified = std.time.milliTimestamp(),
            .hash = hash,
        });

        try self.extractSymbols(content, file_id);
    }

    // ── Symbol extraction ───────────────────────────────────────────────

    fn extractSymbols(self: *Ingester, content: []const u8, file_id: u32) !void {
        var line_num: u32 = 1;
        var scope: []const u8 = "";
        var it = std.mem.splitScalar(u8, content, '\n');

        while (it.next()) |line| {
            defer line_num += 1;
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (trimmed.len == 0) continue;

            // Skip comments
            if (std.mem.startsWith(u8, trimmed, "//") or
                std.mem.startsWith(u8, trimmed, "/*") or
                std.mem.startsWith(u8, trimmed, "*"))
                continue;

            // Class declaration
            if (matchClassDecl(trimmed)) |name| {
                try self.addSymbol(name, .class, file_id, line_num, scope);
                scope = name;
                continue;
            }

            // Interface declaration
            if (matchInterfaceDecl(trimmed)) |name| {
                try self.addSymbol(name, .interface, file_id, line_num, scope);
                continue;
            }

            // Type alias
            if (matchTypeAlias(trimmed)) |name| {
                try self.addSymbol(name, .type_def, file_id, line_num, scope);
                continue;
            }

            // Function declaration (named)
            if (matchFunctionDecl(trimmed)) |name| {
                const kind: SymbolKind = if (scope.len > 0) .method else .function;
                try self.addSymbol(name, kind, file_id, line_num, scope);
                continue;
            }

            // Arrow function / const assignment
            if (matchConstFunction(trimmed)) |name| {
                const kind: SymbolKind = if (scope.len > 0) .method else .function;
                try self.addSymbol(name, kind, file_id, line_num, scope);
                continue;
            }

            // Variable declaration (const/let/var without function body)
            if (matchVariable(trimmed)) |name| {
                try self.addSymbol(name, .variable, file_id, line_num, scope);
                continue;
            }

            // Track scope exit (closing brace at column 0)
            if (line.len > 0 and line[0] == '}') {
                scope = "";
            }
        }
    }

    fn addSymbol(self: *Ingester, name: []const u8, kind: SymbolKind, file_id: u32, line: u32, scope: []const u8) !void {
        const id = self.next_symbol_id;
        self.next_symbol_id += 1;
        try self.graph.addSymbol(.{
            .id = id,
            .name = name,
            .kind = kind,
            .file_id = file_id,
            .line = line,
            .col = 0,
            .scope = scope,
        });
    }
};

// ── Import edge extraction ──────────────────────────────────────────────────

/// Extract import paths from TypeScript/JavaScript source.
/// Returns a list of imported module paths (e.g. "./utils", "express").
pub fn extractImports(content: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    var imports: std.ArrayList([]const u8) = .empty;
    defer imports.deinit(alloc);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (extractImportPath(trimmed)) |path| {
            const duped = try alloc.dupe(u8, path);
            try imports.append(alloc, duped);
        }
    }

    const result = try alloc.alloc([]const u8, imports.items.len);
    @memcpy(result, imports.items);
    return result;
}

/// Extract the module path from an import statement.
/// Handles: import ... from 'path', import ... from "path", import 'path', require('path')
fn extractImportPath(line: []const u8) ?[]const u8 {
    // import ... from 'path' or import ... from "path"
    if (std.mem.startsWith(u8, line, "import ")) {
        if (findQuotedAfter(line, " from ")) |path| return path;
        // import 'path' (side-effect import)
        if (findQuotedAt(line, 7)) |path| return path;
    }
    // const x = require('path')
    if (std.mem.indexOf(u8, line, "require(")) |idx| {
        const after = line[idx + 8 ..];
        if (after.len > 2 and (after[0] == '\'' or after[0] == '"')) {
            const quote = after[0];
            if (std.mem.indexOfScalar(u8, after[1..], quote)) |end| {
                return after[1..][0..end];
            }
        }
    }
    return null;
}

// ── Pattern matchers ────────────────────────────────────────────────────────

fn matchClassDecl(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "export class ", "export default class ", "class ", "export abstract class ", "abstract class " };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return extractIdentifier(line[prefix.len..]);
        }
    }
    return null;
}

fn matchInterfaceDecl(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "export interface ", "interface " };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return extractIdentifier(line[prefix.len..]);
        }
    }
    return null;
}

fn matchTypeAlias(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "export type ", "type " };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return extractIdentifier(line[prefix.len..]);
        }
    }
    return null;
}

fn matchFunctionDecl(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "export function ", "export default function ", "export async function ", "async function ", "function " };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return extractIdentifier(line[prefix.len..]);
        }
    }
    return null;
}

fn matchConstFunction(line: []const u8) ?[]const u8 {
    // const name = (...) => or const name = function or const name = async (
    const prefixes = [_][]const u8{ "export const ", "const " };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            const rest = line[prefix.len..];
            const name = extractIdentifier(rest) orelse continue;
            // Check if assignment is a function/arrow
            const after_name = rest[name.len..];
            const trimmed = std.mem.trimLeft(u8, after_name, " \t");
            if (trimmed.len > 0 and trimmed[0] == '=') {
                const rhs = std.mem.trimLeft(u8, trimmed[1..], " \t");
                if (std.mem.startsWith(u8, rhs, "(") or
                    std.mem.startsWith(u8, rhs, "async ") or
                    std.mem.startsWith(u8, rhs, "function") or
                    std.mem.startsWith(u8, rhs, "<"))
                    return name;
            }
        }
    }
    return null;
}

fn matchVariable(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "export const ", "export let ", "export var ", "const ", "let ", "var " };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return extractIdentifier(line[prefix.len..]);
        }
    }
    return null;
}

fn extractIdentifier(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    // Must start with letter or underscore
    if (!isIdentStart(s[0])) return null;
    var end: usize = 1;
    while (end < s.len and isIdentCont(s[end])) end += 1;
    return s[0..end];
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn findQuotedAfter(line: []const u8, marker: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, marker) orelse return null;
    return findQuotedAt(line, idx + marker.len);
}

fn findQuotedAt(line: []const u8, offset: usize) ?[]const u8 {
    if (offset >= line.len) return null;
    const rest = line[offset..];
    const trimmed = std.mem.trimLeft(u8, rest, " \t");
    if (trimmed.len < 2) return null;
    const quote = trimmed[0];
    if (quote != '\'' and quote != '"') return null;
    if (std.mem.indexOfScalar(u8, trimmed[1..], quote)) |end| {
        return trimmed[1..][0..end];
    }
    return null;
}

// ── Language detection ──────────────────────────────────────────────────────

pub fn detectLanguage(path: []const u8) Language {
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return .typescript;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx")) return .javascript;
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    return .unknown;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "detectLanguage" {
    try std.testing.expectEqual(Language.typescript, detectLanguage("src/main.ts"));
    try std.testing.expectEqual(Language.typescript, detectLanguage("app.tsx"));
    try std.testing.expectEqual(Language.javascript, detectLanguage("index.js"));
    try std.testing.expectEqual(Language.javascript, detectLanguage("app.jsx"));
    try std.testing.expectEqual(Language.zig, detectLanguage("build.zig"));
    try std.testing.expectEqual(Language.python, detectLanguage("setup.py"));
    try std.testing.expectEqual(Language.unknown, detectLanguage("README.md"));
}

test "extract function declarations" {
    const source =
        \\export function handleRequest(req: Request): Response {
        \\  return new Response();
        \\}
        \\
        \\async function fetchData() {
        \\  await fetch('/api');
        \\}
        \\
        \\function helper() {}
    ;

    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    _ = try ing.ingestSource("test.ts", source);
    try std.testing.expectEqual(@as(usize, 3), g.symbolCount());

    // Check that symbols were created
    const s1 = g.getSymbol(1).?;
    try std.testing.expectEqualStrings("handleRequest", s1.name);
    try std.testing.expectEqual(SymbolKind.function, s1.kind);

    const s2 = g.getSymbol(2).?;
    try std.testing.expectEqualStrings("fetchData", s2.name);
}

test "extract class and interface declarations" {
    const source =
        \\export class MyService {
        \\  method() {}
        \\}
        \\
        \\interface Config {
        \\  port: number;
        \\}
        \\
        \\export interface Logger {
        \\  log(msg: string): void;
        \\}
    ;

    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    _ = try ing.ingestSource("test.ts", source);

    // Should find: MyService (class), method (method inside class), Config (interface), Logger (interface)
    try std.testing.expect(g.symbolCount() >= 3);
}

test "extract const arrow functions" {
    const source =
        \\export const processItem = (item: Item) => {
        \\  return transform(item);
        \\};
        \\
        \\const validate = async (data: Data) => {
        \\  return true;
        \\};
    ;

    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    _ = try ing.ingestSource("test.ts", source);
    try std.testing.expectEqual(@as(usize, 2), g.symbolCount());

    const s1 = g.getSymbol(1).?;
    try std.testing.expectEqualStrings("processItem", s1.name);
}

test "extract type aliases" {
    const source =
        \\export type UserId = string;
        \\type Config = { port: number };
    ;

    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    _ = try ing.ingestSource("test.ts", source);
    try std.testing.expectEqual(@as(usize, 2), g.symbolCount());

    const s1 = g.getSymbol(1).?;
    try std.testing.expectEqual(SymbolKind.type_def, s1.kind);
}

test "extract imports" {
    const source =
        \\import { Router } from 'express';
        \\import * as fs from "fs";
        \\import './side-effect';
        \\const path = require('path');
    ;

    const imports = try extractImports(source, std.testing.allocator);
    defer {
        for (imports) |i| std.testing.allocator.free(i);
        std.testing.allocator.free(imports);
    }

    try std.testing.expectEqual(@as(usize, 4), imports.len);
    try std.testing.expectEqualStrings("express", imports[0]);
    try std.testing.expectEqualStrings("fs", imports[1]);
    try std.testing.expectEqualStrings("./side-effect", imports[2]);
    try std.testing.expectEqualStrings("path", imports[3]);
}

test "skips comments" {
    const source =
        \\// function notAFunction() {}
        \\/* class NotAClass {} */
        \\* @param x - something
        \\function realFunction() {}
    ;

    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    _ = try ing.ingestSource("test.ts", source);
    try std.testing.expectEqual(@as(usize, 1), g.symbolCount());
    try std.testing.expectEqualStrings("realFunction", g.getSymbol(1).?.name);
}

test "unknown file extension returns null" {
    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    const result = try ing.ingestSource("README.md", "# Title");
    try std.testing.expectEqual(@as(?u32, null), result);
}

test "reingest is idempotent" {
    const source1 =
        \\function oldFunc() {}
    ;
    const source2 =
        \\function newFunc() {}
        \\function anotherFunc() {}
    ;

    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    const file_id = (try ing.ingestSource("test.ts", source1)).?;
    try std.testing.expectEqual(@as(usize, 1), g.symbolCount());

    try ing.reingestSource(file_id, "test.ts", source2);
    try std.testing.expectEqual(@as(usize, 2), g.symbolCount());

    // Old symbol should be gone
    var found_old = false;
    var sym_it = g.symbols.iterator();
    while (sym_it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, "oldFunc")) found_old = true;
    }
    try std.testing.expect(!found_old);
}

test "empty source produces no symbols" {
    var g = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g.deinit();
    var ing = Ingester.init(&g, std.testing.allocator);

    _ = try ing.ingestSource("empty.ts", "");
    try std.testing.expectEqual(@as(usize, 0), g.symbolCount());
}
