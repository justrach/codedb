const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const explore = @import("explore.zig");
const Explorer = explore.Explorer;
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const DependencyGraph = explore.DependencyGraph;
const Store = @import("store.zig").Store;


fn expectOutlineSymbol(outline: *const explore.FileOutline, name: []const u8, kind: SymbolKind) !void {
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and sym.kind == kind) return;
    }
    return error.TestUnexpectedResult;
}


fn expectOutlineImport(outline: *const explore.FileOutline, import_path: []const u8) !void {
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, import_path)) return;
    }
    return error.TestUnexpectedResult;
}


test "issue-1: multi-line TS/JS import paths captured for dep graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/role-driver.ts",
        \\import {
        \\  existsSync,
        \\  readdirSync,
        \\} from "../bus/in-memory-event-bus.ts";
        \\
        \\import { join } from "node:path";
        \\
        \\export * from "./re-export.ts";
        \\
        \\// loads config from "config.json" at boot
        \\
        \\export class RoleDriver {}
    );

    var outline = (try explorer.getOutline("src/role-driver.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try testing.expectEqual(Language.typescript, outline.language);
    // Single-line import already worked (regression guard) ...
    try expectOutlineImport(&outline, "node:path");
    // ... the multi-line import is the bug: its `from "..."` sits on a line
    // that does not contain "import ", so it was dropped from the dep graph.
    try expectOutlineImport(&outline, "../bus/in-memory-event-bus.ts");
    // re-export deps (export ... from) are also dependencies.
    try expectOutlineImport(&outline, "./re-export.ts");
    // A comment (or string) that merely contains `from "..."` must NOT become a
    // dependency. The old over-broad match grabbed exactly this kind of thing.
    for (outline.imports.items) |imp| {
        try testing.expect(!std.mem.eql(u8, imp, "config.json"));
    }
}

test "issue-2: relative imports resolve to repo paths in the dep graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("daemon/src/role/role-driver.ts",
        \\import { foo } from "../bus/event-bus.ts";
        \\import { join } from "node:path";
    );

    const deps = explorer.dep_graph.getForwardDeps("daemon/src/role/role-driver.ts") orelse
        return error.TestUnexpectedResult;
    var found_resolved = false;
    var found_raw = false;
    var found_bare = false;
    for (deps) |d| {
        if (std.mem.eql(u8, d, "daemon/src/bus/event-bus.ts")) found_resolved = true;
        if (std.mem.eql(u8, d, "../bus/event-bus.ts")) found_raw = true;
        if (std.mem.eql(u8, d, "node:path")) found_bare = true;
    }
    // the relative import resolves to a repo-rooted path ...
    try testing.expect(found_resolved);
    // ... the raw "../" form no longer appears in the graph (was dropped before) ...
    try testing.expect(!found_raw);
    // ... and bare specifiers are unaffected.
    try testing.expect(found_bare);

    // imported_by must now resolve to the importer.
    const importers = try explorer.dep_graph.getImportedBy("daemon/src/bus/event-bus.ts", testing.allocator);
    defer {
        for (importers) |imp| testing.allocator.free(imp);
        testing.allocator.free(importers);
    }
    var found_importer = false;
    for (importers) |imp| {
        if (std.mem.eql(u8, imp, "daemon/src/role/role-driver.ts")) found_importer = true;
    }
    try testing.expect(found_importer);
}

test "issue-2: extensionless relative imports resolve using the importer's extension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // Common TS/JS form: the import omits the ".ts" extension.
    try explorer.indexFile("daemon/src/role/role-driver.ts",
        \\import { foo } from "../bus/event-bus";
    );

    const deps = explorer.dep_graph.getForwardDeps("daemon/src/role/role-driver.ts") orelse
        return error.TestUnexpectedResult;
    var found = false;
    for (deps) |d| {
        if (std.mem.eql(u8, d, "daemon/src/bus/event-bus.ts")) found = true;
    }
    // Resolved to the indexed file path, with the importer's .ts extension added.
    try testing.expect(found);

    const importers = try explorer.dep_graph.getImportedBy("daemon/src/bus/event-bus.ts", testing.allocator);
    defer {
        for (importers) |imp| testing.allocator.free(imp);
        testing.allocator.free(importers);
    }
    var found_importer = false;
    for (importers) |imp| {
        if (std.mem.eql(u8, imp, "daemon/src/role/role-driver.ts")) found_importer = true;
    }
    try testing.expect(found_importer);
}

test "issue-2: interned dependency keys are reused, not re-allocated per reindex" {
    var dg = DependencyGraph.init(testing.allocator);
    defer dg.deinit();

    const a = try dg.internString("daemon/src/bus/event-bus.ts");
    const b = try dg.internString("daemon/src/bus/event-bus.ts");
    // Same content -> same backing allocation, so re-indexing a file with the
    // same relative imports does not grow the arena on every rebuild.
    try testing.expect(a.ptr == b.ptr);

    const c = try dg.internString("daemon/src/other.ts");
    try testing.expect(a.ptr != c.ptr);
}

test "issue-548: a string containing 'import ' is not captured as a dependency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // A plain const whose string value merely contains "import " — it is NOT an
    // import statement, so it must not produce a dependency edge.
    try explorer.indexFile("src/msg.ts", "export const ERROR = 'failed to import the config module';");
    var outline = (try explorer.getOutline("src/msg.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    for (outline.imports.items) |imp| {
        try testing.expect(!std.mem.eql(u8, imp, "failed to import the config module"));
    }

    // Regression guard: a real single-line import is still captured.
    try explorer.indexFile("src/dep.ts", "import { real } from './real-dep.ts';");
    var outline2 = (try explorer.getOutline("src/dep.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline2.deinit();
    try expectOutlineImport(&outline2, "./real-dep.ts");
}

test "issue-301: Dart / Flutter parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("lib/home_screen.dart",
        \\import 'package:flutter/material.dart';
        \\export 'src/helpers.dart';
        \\part 'home_screen.g.dart';
        \\
        \\typedef ItemBuilder = Widget Function(BuildContext context);
        \\
        \\abstract class HomeScreen extends StatelessWidget {
        \\  @override
        \\  Widget build(BuildContext context) {
        \\    return const Placeholder();
        \\  }
        \\}
        \\
        \\mixin Loader on State<StatefulWidget> {
        \\  Future<void> loadData() async {}
        \\}
        \\
        \\extension ContextX on BuildContext {
        \\  ThemeData get theme => Theme.of(this);
        \\}
        \\
        \\enum LoadState { idle, loading }
        \\
        \\const String appTitle = 'codedb';
    );

    var outline = (try explorer.getOutline("lib/home_screen.dart", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try testing.expectEqual(Language.dart, outline.language);
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);

    var found_typedef = false;
    var found_class = false;
    var found_mixin = false;
    var found_extension = false;
    var found_enum = false;
    var found_build = false;
    var found_load = false;
    var found_const = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "ItemBuilder")) found_typedef = true;
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "HomeScreen")) found_class = true;
        if (sym.kind == .trait_def and std.mem.eql(u8, sym.name, "Loader")) found_mixin = true;
        if (sym.kind == .impl_block and std.mem.eql(u8, sym.name, "ContextX")) found_extension = true;
        if (sym.kind == .enum_def and std.mem.eql(u8, sym.name, "LoadState")) found_enum = true;
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "build")) found_build = true;
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "loadData")) found_load = true;
        if (sym.kind == .constant and std.mem.eql(u8, sym.name, "appTitle")) found_const = true;
    }
    try testing.expect(found_typedef);
    try testing.expect(found_class);
    try testing.expect(found_mixin);
    try testing.expect(found_extension);
    try testing.expect(found_enum);
    try testing.expect(found_build);
    try testing.expect(found_load);
    try testing.expect(found_const);

    const tree = try explorer.getTree(testing.allocator, false);
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "home_screen.dart  dart") != null);
}


test "issue-php-1: PHP class definition herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Models/Candidate.php",
        \\<?php
        \\
        \\namespace App\Models;
        \\
        \\class Candidate
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Models/Candidate.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Candidate")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}


test "issue-php-2: PHP methode binnen class herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Models/User.php",
        \\<?php
        \\
        \\class User
        \\{
        \\    public function boot()
        \\    {
        \\    }
        \\
        \\    protected function scopeActive($query)
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Models/User.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
}


test "issue-php-3: PHP top-level functie herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("helpers.php",
        \\<?php
        \\
        \\function myHelper($arg)
        \\{
        \\}
        \\
        \\function boot()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("helpers.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var fn_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) fn_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), fn_count);
}


test "issue-php-4: PHP interface herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Contracts/Payable.php",
        \\<?php
        \\
        \\interface Payable
        \\{
        \\    public function charge();
        \\}
    );

    var outline = (try explorer.getOutline("app/Contracts/Payable.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .interface_def and std.mem.eql(u8, sym.name, "Payable")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}


test "issue-php-5: PHP trait herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Traits/HasSlug.php",
        \\<?php
        \\
        \\trait HasSlug
        \\{
        \\    public function generateSlug()
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Traits/HasSlug.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .trait_def and std.mem.eql(u8, sym.name, "HasSlug")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}


test "issue-php-6: PHP use-import omgezet naar pad in dep_graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Http/Controllers/CandidateController.php",
        \\<?php
        \\
        \\use App\Models\Candidate;
        \\use Illuminate\Support\Facades\DB;
    );

    var outline = (try explorer.getOutline("app/Http/Controllers/CandidateController.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/Candidate.php", outline.imports.items[0]);
    try testing.expectEqualStrings("illuminate/Support/Facades/DB.php", outline.imports.items[1]);
}


test "issue-php-7: PHP commentaarregels worden overgeslagen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Commented.php",
        \\<?php
        \\
        \\// function fakeFunction()
        \\# function anotherFake()
        \\/* function blockComment() */
        \\
        \\class RealClass
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Commented.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.symbols.items.len);
    try testing.expect(outline.symbols.items[0].kind == .class_def);
}


test "issue-php-8: PHP function after class is top-level, not method" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/mixed.php",
        \\<?php
        \\
        \\class Foo
        \\{
        \\    public function bar()
        \\    {
        \\    }
        \\}
        \\
        \\function helper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/mixed.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}


test "issue-php-9: PHP 8.1 enum herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Enums/Status.php",
        \\<?php
        \\
        \\enum Status: string
        \\{
        \\    public function label(): string
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Enums/Status.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found_enum = false;
    var found_method = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .enum_def and std.mem.eql(u8, sym.name, "Status")) found_enum = true;
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "label")) found_method = true;
    }
    try testing.expect(found_enum);
    try testing.expect(found_method);
}


test "issue-php-10: PHP grouped use-statement parsed into individual imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Http/Controllers/TestController.php",
        \\<?php
        \\
        \\use App\Models\{User, Candidate, Role};
    );

    var outline = (try explorer.getOutline("app/Http/Controllers/TestController.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.symbols.items.len);
    try testing.expect(outline.symbols.items[0].kind == .import);
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
    try testing.expectEqualStrings("app/Models/Candidate.php", outline.imports.items[1]);
    try testing.expectEqualStrings("app/Models/Role.php", outline.imports.items[2]);
}


test "issue-php-11: PHP readonly class herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/ValueObjects/Money.php",
        \\<?php
        \\
        \\readonly class Money
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/ValueObjects/Money.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Money")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}


test "issue-php-12: PHP class and public constants herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Config.php",
        \\<?php
        \\
        \\class Config
        \\{
        \\    public const VERSION = '1.0';
        \\    const MAX_RETRIES = 3;
        \\    private const SECRET = 'abc';
        \\}
    );

    var outline = (try explorer.getOutline("app/Config.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var constant_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .constant) constant_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), constant_count);
}


test "issue-php-13: PHP nested braces in methods do not break class tracking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Services/Complex.php",
        \\<?php
        \\
        \\class Complex
        \\{
        \\    public function process()
        \\    {
        \\        if ($x) {
        \\            foreach ($items as $item) {
        \\                echo "}";
        \\            }
        \\        }
        \\    }
        \\
        \\    public function another()
        \\    {
        \\    }
        \\}
        \\
        \\function outsideHelper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Complex.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}


test "issue-php-14: PHP multi-line block comments do not produce symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Services/Commented.php",
        \\<?php
        \\
        \\class Real
        \\{
        \\}
        \\
        \\/*
        \\function fake() {
        \\}
        \\class Ghost {
        \\}
        \\*/
        \\
        \\function afterComment()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Commented.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var class_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def) class_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), class_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}


test "issue-php-15: PHP use-as alias stripped from import path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Controllers/Test.php",
        \\<?php
        \\
        \\use App\Models\User as UserModel;
    );

    var outline = (try explorer.getOutline("app/Controllers/Test.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
}


test "issue-php-16: PHP escaped quotes do not end string mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Services/Escaped.php",
        \\<?php
        \\
        \\class Formatter
        \\{
        \\    public function render()
        \\    {
        \\        echo "she said \"}\"";
        \\    }
        \\
        \\    public function other()
        \\    {
        \\    }
        \\}
        \\
        \\function freeHelper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Escaped.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}


test "issue-php-17: PHP code after block comment terminator is parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Services/Inline.php",
        \\<?php
        \\
        \\/*
        \\function fake() {
        \\}
        \\*/ function realFunc()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Inline.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), function_count);
}


test "issue-php-18: PHP use-as alias case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app/Controllers/CaseTest.php",
        \\<?php
        \\
        \\use App\Models\User AS UserModel;
        \\use App\Services\{Cache AS CacheAlias, Logger};
    );

    var outline = (try explorer.getOutline("app/Controllers/CaseTest.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
    try testing.expectEqualStrings("app/Services/Cache.php", outline.imports.items[1]);
    try testing.expectEqualStrings("app/Services/Logger.php", outline.imports.items[2]);
}


test "issue-111: Python triple-quote docstrings not parsed as code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("docstring.py",
        \\def real_func():
        \\    """
        \\    def fake_func():
        \\        pass
        \\    """
        \\    pass
    );

    var outline = (try explorer.getOutline("docstring.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    // Only real_func should be found, not fake_func inside docstring
    try testing.expect(func_count == 1);
}


test "issue-112: Python import-as alias stripped from dep path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("utils.py", "def helper(): pass\n");
    try explorer.indexFile("consumer.py", "import utils as u\n");

    const deps = try explorer.getImportedBy("utils.py", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expect(deps.len == 1);
}


test "issue-113: TypeScript block comments not parsed as code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("commented.ts",
        \\export function realFunc() {}
        \\/*
        \\export function fakeFunc() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1);
}


test "issue-114: TypeScript import-as alias does not affect dep path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("mod.ts", "export function hello() {}\n");
    try explorer.indexFile("consumer.ts", "import { hello as h } from './mod'\n");

    var outline = (try explorer.getOutline("consumer.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    // The import dep path should be "./mod", not include the alias
    try testing.expect(outline.imports.items.len == 1);
    try testing.expectEqualStrings("./mod", outline.imports.items[0]);
}


test "issue-151: Go func and type definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("main.go",
        \\package main
        \\
        \\import "fmt"
        \\
        \\type Config struct {
        \\    Port int
        \\}
        \\
        \\type Handler interface {
        \\    Handle()
        \\}
        \\
        \\func main() {
        \\    fmt.Println("hello")
        \\}
        \\
        \\func (c *Config) Validate() bool {
        \\    return c.Port > 0
        \\}
    );

    var outline = (try explorer.getOutline("main.go", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    var struct_count: usize = 0;
    var interface_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
        if (sym.kind == .struct_def) struct_count += 1;
        if (sym.kind == .interface_def) interface_count += 1;
    }
    try testing.expect(func_count == 2); // main + Validate
    try testing.expect(outline.imports.items.len == 1); // "fmt"
    try testing.expect(struct_count == 1); // Config
    try testing.expect(interface_count == 1); // Handler
}


test "issue-151: Ruby class, module, and def" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("app.rb",
        \\require "json"
        \\require_relative "./helpers"
        \\
        \\module Authentication
        \\  class User
        \\    def initialize(name)
        \\      @name = name
        \\    end
        \\
        \\    def greet
        \\      puts "hello"
        \\    end
        \\  end
        \\end
    );

    var outline = (try explorer.getOutline("app.rb", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    var struct_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
        if (sym.kind == .struct_def) struct_count += 1;
    }
    try testing.expect(func_count == 2); // initialize + greet
    try testing.expect(struct_count == 2); // Authentication + User
    try testing.expect(outline.imports.items.len == 2); // json + ./helpers
}


test "issue-151: Ruby =begin/=end comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("commented.rb",
        \\def real_method
        \\  true
        \\end
        \\=begin
        \\def fake_method
        \\  false
        \\end
        \\=end
    );

    var outline = (try explorer.getOutline("commented.rb", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1); // only real_method
}


test "issue-151: Go block comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("commented.go",
        \\package main
        \\
        \\func realFunc() {}
        \\/*
        \\func fakeFunc() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.go", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1); // only realFunc
}


test "issue-301: Dart block comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("commented.dart",
        \\class RealWidget {}
        \\/*
        \\class FakeWidget {}
        \\void fakeHelper() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.dart", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var class_count: usize = 0;
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def) class_count += 1;
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), class_count);
    try testing.expectEqual(@as(usize, 0), func_count);
}


test "issue-179: block comment does not produce phantom symbols" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("test.zig", "/* commented out\npub fn fake_func() void {}\n*/\npub fn real_func() void {}\n");

    const outline = (try explorer.getOutline("test.zig", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found_real = false;
    var found_fake = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "real_func") != null) found_real = true;
        if (std.mem.indexOf(u8, sym.name, "fake_func") != null) found_fake = true;
    }
    try testing.expect(found_real);
    try testing.expect(!found_fake);
}


test "issue-179: code after single-line /* */ comment is parsed" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("test.zig", "/* skip this */ pub fn visible() void {}\n");

    const outline = (try explorer.getOutline("test.zig", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "visible") != null) found = true;
    }
    try testing.expect(found);
}


test "issue-179: Python docstring with text does not leak symbols" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    try explorer.indexFile("test.py", "def real():\n    \"\"\"This is a docstring.\n    def fake():\n        pass\n    \"\"\"\n    pass\n");

    const outline = (try explorer.getOutline("test.py", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found_real = false;
    var found_fake = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "real") != null) found_real = true;
        if (std.mem.indexOf(u8, sym.name, "fake") != null) found_fake = true;
    }
    try testing.expect(found_real);
    try testing.expect(!found_fake);
}

test "issue-518: non-ASCII (Korean) function identifier is captured in the outline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    // "def 한():" — 한 (U+D55C) is a valid Python 3 identifier that ast parses;
    // the ASCII-only ident scanner used to drop it, returning 0 symbols.
    try explorer.indexFile("uni.py", "def \xed\x95\x9c():\n    return 1\n");

    var outline = (try explorer.getOutline("uni.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try expectOutlineSymbol(&outline, "\xed\x95\x9c", .function);
}

test "issue-518: Python class is labeled class_def, not struct_def" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("widget.py", "class Widget:\n    pass\n");

    var outline = (try explorer.getOutline("widget.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try expectOutlineSymbol(&outline, "Widget", .class_def);
}


test "issue-108: HCL resource block parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("main.tf",
        \\resource "aws_instance" "web" {
        \\  ami = "abc-123"
        \\}
    );
    const results = try explorer.findAllSymbols("web", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
    try testing.expectEqual(SymbolKind.struct_def, results[0].symbol.kind);
}


test "issue-108: HCL variable and output parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("vars.tf",
        \\variable "region" {
        \\  default = "us-east-1"
        \\}
        \\output "ip" {
        \\  value = aws_instance.web.public_ip
        \\}
    );
    const vars = try explorer.findAllSymbols("region", alloc);
    defer alloc.free(vars);
    try testing.expect(vars.len == 1);
    try testing.expectEqual(SymbolKind.variable, vars[0].symbol.kind);
    const outs = try explorer.findAllSymbols("ip", alloc);
    defer alloc.free(outs);
    try testing.expect(outs.len == 1);
    try testing.expectEqual(SymbolKind.constant, outs[0].symbol.kind);
}


test "issue-108: HCL module and provider parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("main.tf",
        \\provider "aws" {
        \\  region = "us-east-1"
        \\}
        \\module "vpc" {
        \\  source = "./modules/vpc"
        \\}
    );
    const providers = try explorer.findAllSymbols("aws", alloc);
    defer alloc.free(providers);
    try testing.expect(providers.len == 1);
    const mods = try explorer.findAllSymbols("vpc", alloc);
    defer alloc.free(mods);
    try testing.expect(mods.len == 1);
}


test "issue-108: HCL comment lines skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("main.tf",
        \\# This is a comment
        \\// Another comment
        \\variable "name" {}
    );
    const results = try explorer.findAllSymbols("name", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
}


test "issue-215: R function assignment parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("analysis.R",
        \\greet <- function(name) {
        \\  paste("Hello", name)
        \\}
    );
    const results = try explorer.findAllSymbols("greet", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
    try testing.expectEqual(SymbolKind.function, results[0].symbol.kind);
}


test "issue-215: R library import parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("script.r",
        \\library(dplyr)
        \\require(ggplot2)
    );
    const outline = try explorer.getOutline("script.r", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
}


test "issue-215: R setClass parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("classes.R",
        \\setClass("Person")
        \\setRefClass("Animal")
    );
    const p = try explorer.findAllSymbols("Person", alloc);
    defer alloc.free(p);
    try testing.expect(p.len == 1);
    try testing.expectEqual(SymbolKind.class_def, p[0].symbol.kind);
    const a2 = try explorer.findAllSymbols("Animal", alloc);
    defer alloc.free(a2);
    try testing.expect(a2.len == 1);
}


test "issue-319: C parser extracts includes macros types and functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/core.c",
        \\#include <stdio.h>
        \\#include "local.h"
        \\#define MAX_SIZE 64
        \\#define SQUARE(x) ((x) * (x))
        \\struct Worker {
        \\    int id;
        \\};
        \\enum Mode {
        \\    MODE_A,
        \\};
        \\union Value {
        \\    int i;
        \\};
        \\typedef unsigned long size_alias_t;
        \\static inline const char *worker_name(const struct Worker *worker) {
        \\    return "worker";
        \\}
        \\void *alloc_item(size_t size)
        \\{
        \\    return malloc(size);
        \\}
    );

    const outline = try explorer.getOutline("src/core.c", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.c, outline.language);
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
    try testing.expectEqualStrings("stdio.h", outline.imports.items[0]);
    try testing.expectEqualStrings("local.h", outline.imports.items[1]);

    const max_size = try explorer.findAllSymbols("MAX_SIZE", alloc);
    defer alloc.free(max_size);
    try testing.expectEqual(@as(usize, 1), max_size.len);
    try testing.expectEqual(SymbolKind.macro_def, max_size[0].symbol.kind);

    const square = try explorer.findAllSymbols("SQUARE", alloc);
    defer alloc.free(square);
    try testing.expectEqual(@as(usize, 1), square.len);
    try testing.expectEqual(SymbolKind.macro_def, square[0].symbol.kind);

    const worker = try explorer.findAllSymbols("Worker", alloc);
    defer alloc.free(worker);
    try testing.expectEqual(@as(usize, 1), worker.len);
    try testing.expectEqual(SymbolKind.struct_def, worker[0].symbol.kind);

    const mode = try explorer.findAllSymbols("Mode", alloc);
    defer alloc.free(mode);
    try testing.expectEqual(@as(usize, 1), mode.len);
    try testing.expectEqual(SymbolKind.enum_def, mode[0].symbol.kind);

    const value = try explorer.findAllSymbols("Value", alloc);
    defer alloc.free(value);
    try testing.expectEqual(@as(usize, 1), value.len);
    try testing.expectEqual(SymbolKind.union_def, value[0].symbol.kind);

    const alias = try explorer.findAllSymbols("size_alias_t", alloc);
    defer alloc.free(alias);
    try testing.expectEqual(@as(usize, 1), alias.len);
    try testing.expectEqual(SymbolKind.type_alias, alias[0].symbol.kind);

    const worker_name = try explorer.findAllSymbols("worker_name", alloc);
    defer alloc.free(worker_name);
    try testing.expectEqual(@as(usize, 1), worker_name.len);
    try testing.expectEqual(SymbolKind.function, worker_name[0].symbol.kind);

    const alloc_item = try explorer.findAllSymbols("alloc_item", alloc);
    defer alloc.free(alloc_item);
    try testing.expectEqual(@as(usize, 1), alloc_item.len);
    try testing.expectEqual(SymbolKind.function, alloc_item[0].symbol.kind);
}


test "issue-319: C parser avoids comments strings prototypes and macro calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/noise.c",
        \\// int fake_comment(void) {
        \\/* int fake_block(void) { */
        \\const char *s = "int fake_string(void) {";
        \\typedef int (*handler_fn)(int);
        \\int prototype_only(void);
        \\EXPORT_SYMBOL(real_function);
        \\if (real_function()) {
        \\}
        \\int real_function(void) {
        \\    return 1;
        \\}
    );

    const real = try explorer.findAllSymbols("real_function", alloc);
    defer alloc.free(real);
    try testing.expectEqual(@as(usize, 1), real.len);
    try testing.expectEqual(SymbolKind.function, real[0].symbol.kind);

    const fake_comment = try explorer.findAllSymbols("fake_comment", alloc);
    defer alloc.free(fake_comment);
    try testing.expectEqual(@as(usize, 0), fake_comment.len);

    const fake_block = try explorer.findAllSymbols("fake_block", alloc);
    defer alloc.free(fake_block);
    try testing.expectEqual(@as(usize, 0), fake_block.len);

    const fake_string = try explorer.findAllSymbols("fake_string", alloc);
    defer alloc.free(fake_string);
    try testing.expectEqual(@as(usize, 0), fake_string.len);

    const prototype = try explorer.findAllSymbols("prototype_only", alloc);
    defer alloc.free(prototype);
    try testing.expectEqual(@as(usize, 0), prototype.len);

    const handler = try explorer.findAllSymbols("handler_fn", alloc);
    defer alloc.free(handler);
    try testing.expectEqual(@as(usize, 0), handler.len);
}


test "issue-321: common detected extensions produce outlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/math.cc",
        \\#include <vector>
        \\class Calculator {
        \\public:
        \\    int add(int a, int b) {
        \\        return a + b;
        \\    }
        \\};
        \\int free_add(int a, int b) {
        \\    return a + b;
        \\}
    );
    try explorer.indexFile("src/Bridge.mm",
        \\#import "Bridge.h"
        \\@interface BrowserController
        \\- (void)loadPage:(NSString *)url;
        \\@end
        \\@implementation BrowserController
        \\- (void)loadPage:(NSString *)url { }
        \\@end
        \\class BrowserBridge {
        \\};
        \\int bridge_main(void) {
        \\    return 0;
        \\}
    );
    try explorer.indexFile("src/App.java",
        \\package demo;
        \\import java.util.List;
        \\public class Worker {
        \\    public void run() {}
        \\}
        \\interface RunnableThing {}
        \\enum Mode { A }
        \\record Pair(int left, int right) {}
    );
    try explorer.indexFile("src/App.kt",
        \\package demo
        \\import kotlinx.coroutines.runBlocking
        \\data class User(val name: String)
        \\interface Repo
        \\enum class KotlinMode { A }
        \\fun loadUser(): User = User("a")
        \\val answer = 42
    );
    try explorer.indexFile("src/Widget.svelte",
        \\<script>
        \\import Thing from './Thing.svelte';
        \\export let title;
        \\function renderTitle() {}
        \\</script>
        \\.card { color: red; }
    );
    try explorer.indexFile("src/View.vue",
        \\<script setup>
        \\import Child from './Child.vue'
        \\const count = 0
        \\function inc() {}
        \\</script>
    );
    try explorer.indexFile("src/Page.astro",
        \\---
        \\import Layout from '../layouts/Layout.astro';
        \\const title = 'Home';
        \\---
    );
    try explorer.indexFile("scripts/build.sh",
        \\source ./env.sh
        \\function build_app() {
        \\}
        \\deploy_app() {
        \\}
        \\BUILD_MODE=release
    );
    try explorer.indexFile("styles/app.css",
        \\:root {
        \\  --brand: red;
        \\}
        \\.button {
        \\  color: var(--brand);
        \\}
        \\@keyframes fade {}
    );
    try explorer.indexFile("styles/app.scss",
        \\$gap: 8px;
        \\@mixin center {}
        \\.panel {}
    );
    try explorer.indexFile("db/schema.sql",
        \\CREATE TABLE users (id integer);
        \\CREATE OR REPLACE FUNCTION do_thing() RETURNS void AS $$ SELECT 1; $$ LANGUAGE sql;
        \\CREATE INDEX idx_users_id ON users(id);
    );
    try explorer.indexFile("api/service.proto",
        \\syntax = "proto3";
        \\import "google/protobuf/timestamp.proto";
        \\message User {}
        \\enum Status { STATUS_OK = 0; }
        \\service UserService {
        \\  rpc GetUser (User) returns (User);
        \\}
    );
    try explorer.indexFile("math/solver.f90",
        \\module solver
        \\use mathlib
        \\type :: Particle
        \\end type
        \\subroutine step()
        \\end subroutine
        \\function energy()
        \\end function
    );
    try explorer.indexFile("ir/module.ll",
        \\%Pair = type { i32, i32 }
        \\@global_value = global i32 0
        \\define i32 @main() {
        \\  ret i32 0
        \\}
    );
    try explorer.indexFile("ir/dialect.mlir",
        \\module @kernel_mod {
        \\  func.func @kernel() {
        \\    return
        \\  }
        \\}
    );
    try explorer.indexFile("llvm/records.td",
        \\include "Base.td"
        \\class Register<string name>;
        \\multiclass Pat<string op>;
        \\def R0 : Register<"r0">;
        \\defm ADD : Pat<"add">;
        \\let Namespace = "Toy";
    );

    const cc_outline = try explorer.getOutline("src/math.cc", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.cpp, cc_outline.language);
    try expectOutlineImport(&cc_outline, "vector");
    try expectOutlineSymbol(&cc_outline, "Calculator", .class_def);
    try expectOutlineSymbol(&cc_outline, "add", .function);
    try expectOutlineSymbol(&cc_outline, "free_add", .function);

    const mm_outline = try explorer.getOutline("src/Bridge.mm", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.cpp, mm_outline.language);
    try expectOutlineImport(&mm_outline, "Bridge.h");
    try expectOutlineSymbol(&mm_outline, "BrowserController", .class_def);
    try expectOutlineSymbol(&mm_outline, "loadPage", .method);
    try expectOutlineSymbol(&mm_outline, "BrowserBridge", .class_def);
    try expectOutlineSymbol(&mm_outline, "bridge_main", .function);

    const java_outline = try explorer.getOutline("src/App.java", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.java, java_outline.language);
    try expectOutlineImport(&java_outline, "java.util.List");
    try expectOutlineSymbol(&java_outline, "Worker", .class_def);
    try expectOutlineSymbol(&java_outline, "run", .method);
    try expectOutlineSymbol(&java_outline, "RunnableThing", .interface_def);
    try expectOutlineSymbol(&java_outline, "Mode", .enum_def);
    try expectOutlineSymbol(&java_outline, "Pair", .class_def);

    const kt_outline = try explorer.getOutline("src/App.kt", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.kotlin, kt_outline.language);
    try expectOutlineImport(&kt_outline, "kotlinx.coroutines.runBlocking");
    try expectOutlineSymbol(&kt_outline, "User", .class_def);
    try expectOutlineSymbol(&kt_outline, "Repo", .interface_def);
    try expectOutlineSymbol(&kt_outline, "KotlinMode", .enum_def);
    try expectOutlineSymbol(&kt_outline, "loadUser", .function);
    try expectOutlineSymbol(&kt_outline, "answer", .constant);

    const svelte_outline = try explorer.getOutline("src/Widget.svelte", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.svelte, svelte_outline.language);
    try expectOutlineImport(&svelte_outline, "./Thing.svelte");
    try expectOutlineSymbol(&svelte_outline, "title", .constant);
    try expectOutlineSymbol(&svelte_outline, "renderTitle", .function);
    try expectOutlineSymbol(&svelte_outline, ".card", .class_def);

    const vue_outline = try explorer.getOutline("src/View.vue", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.vue, vue_outline.language);
    try expectOutlineImport(&vue_outline, "./Child.vue");
    try expectOutlineSymbol(&vue_outline, "count", .constant);
    try expectOutlineSymbol(&vue_outline, "inc", .function);

    const astro_outline = try explorer.getOutline("src/Page.astro", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.astro, astro_outline.language);
    try expectOutlineImport(&astro_outline, "../layouts/Layout.astro");
    try expectOutlineSymbol(&astro_outline, "title", .constant);

    const shell_outline = try explorer.getOutline("scripts/build.sh", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.shell, shell_outline.language);
    try expectOutlineImport(&shell_outline, "./env.sh");
    try expectOutlineSymbol(&shell_outline, "build_app", .function);
    try expectOutlineSymbol(&shell_outline, "deploy_app", .function);
    try expectOutlineSymbol(&shell_outline, "BUILD_MODE", .variable);

    const css_outline = try explorer.getOutline("styles/app.css", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.css, css_outline.language);
    try expectOutlineSymbol(&css_outline, "--brand", .constant);
    try expectOutlineSymbol(&css_outline, ".button", .class_def);
    try expectOutlineSymbol(&css_outline, "fade", .function);

    const scss_outline = try explorer.getOutline("styles/app.scss", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.scss, scss_outline.language);
    try expectOutlineSymbol(&scss_outline, "$gap", .constant);
    try expectOutlineSymbol(&scss_outline, "center", .function);
    try expectOutlineSymbol(&scss_outline, ".panel", .class_def);

    const sql_outline = try explorer.getOutline("db/schema.sql", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.sql, sql_outline.language);
    try expectOutlineSymbol(&sql_outline, "users", .struct_def);
    try expectOutlineSymbol(&sql_outline, "do_thing", .function);
    try expectOutlineSymbol(&sql_outline, "idx_users_id", .constant);

    const proto_outline = try explorer.getOutline("api/service.proto", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.protobuf, proto_outline.language);
    try expectOutlineImport(&proto_outline, "google/protobuf/timestamp.proto");
    try expectOutlineSymbol(&proto_outline, "User", .struct_def);
    try expectOutlineSymbol(&proto_outline, "Status", .enum_def);
    try expectOutlineSymbol(&proto_outline, "UserService", .interface_def);
    try expectOutlineSymbol(&proto_outline, "GetUser", .method);

    const fortran_outline = try explorer.getOutline("math/solver.f90", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.fortran, fortran_outline.language);
    try expectOutlineImport(&fortran_outline, "mathlib");
    try expectOutlineSymbol(&fortran_outline, "solver", .class_def);
    try expectOutlineSymbol(&fortran_outline, "Particle", .struct_def);
    try expectOutlineSymbol(&fortran_outline, "step", .function);
    try expectOutlineSymbol(&fortran_outline, "energy", .function);

    const llvm_outline = try explorer.getOutline("ir/module.ll", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.llvm_ir, llvm_outline.language);
    try expectOutlineSymbol(&llvm_outline, "Pair", .type_alias);
    try expectOutlineSymbol(&llvm_outline, "global_value", .variable);
    try expectOutlineSymbol(&llvm_outline, "main", .function);

    const mlir_outline = try explorer.getOutline("ir/dialect.mlir", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.mlir, mlir_outline.language);
    try expectOutlineSymbol(&mlir_outline, "kernel_mod", .class_def);
    try expectOutlineSymbol(&mlir_outline, "kernel", .function);

    const td_outline = try explorer.getOutline("llvm/records.td", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.tablegen, td_outline.language);
    try expectOutlineImport(&td_outline, "Base.td");
    try expectOutlineSymbol(&td_outline, "Register", .class_def);
    try expectOutlineSymbol(&td_outline, "Pat", .class_def);
    try expectOutlineSymbol(&td_outline, "R0", .constant);
    try expectOutlineSymbol(&td_outline, "ADD", .constant);
    try expectOutlineSymbol(&td_outline, "Namespace", .variable);

    const worker = try explorer.findAllSymbols("Worker", alloc);
    defer alloc.free(worker);
    try testing.expectEqual(@as(usize, 1), worker.len);
    try testing.expectEqual(SymbolKind.class_def, worker[0].symbol.kind);

    const run = try explorer.findAllSymbols("run", alloc);
    defer alloc.free(run);
    try testing.expectEqual(@as(usize, 1), run.len);
    try testing.expectEqual(SymbolKind.method, run[0].symbol.kind);

    const user = try explorer.findAllSymbols("User", alloc);
    defer alloc.free(user);
    try testing.expect(user.len >= 2);

    const load_user = try explorer.findAllSymbols("loadUser", alloc);
    defer alloc.free(load_user);
    try testing.expectEqual(@as(usize, 1), load_user.len);
    try testing.expectEqual(SymbolKind.function, load_user[0].symbol.kind);

    const title = try explorer.findAllSymbols("title", alloc);
    defer alloc.free(title);
    try testing.expect(title.len >= 2);

    const build_app = try explorer.findAllSymbols("build_app", alloc);
    defer alloc.free(build_app);
    try testing.expectEqual(@as(usize, 1), build_app.len);
    try testing.expectEqual(SymbolKind.function, build_app[0].symbol.kind);

    const button = try explorer.findAllSymbols(".button", alloc);
    defer alloc.free(button);
    try testing.expectEqual(@as(usize, 1), button.len);

    const users = try explorer.findAllSymbols("users", alloc);
    defer alloc.free(users);
    try testing.expectEqual(@as(usize, 1), users.len);
    try testing.expectEqual(SymbolKind.struct_def, users[0].symbol.kind);

    const user_service = try explorer.findAllSymbols("UserService", alloc);
    defer alloc.free(user_service);
    try testing.expectEqual(@as(usize, 1), user_service.len);
    try testing.expectEqual(SymbolKind.interface_def, user_service[0].symbol.kind);

    const particle = try explorer.findAllSymbols("Particle", alloc);
    defer alloc.free(particle);
    try testing.expectEqual(@as(usize, 1), particle.len);
    try testing.expectEqual(SymbolKind.struct_def, particle[0].symbol.kind);

    const main_sym = try explorer.findAllSymbols("main", alloc);
    defer alloc.free(main_sym);
    try testing.expectEqual(@as(usize, 1), main_sym.len);
    try testing.expectEqual(SymbolKind.function, main_sym[0].symbol.kind);

    const kernel = try explorer.findAllSymbols("kernel", alloc);
    defer alloc.free(kernel);
    try testing.expectEqual(@as(usize, 1), kernel.len);
    try testing.expectEqual(SymbolKind.function, kernel[0].symbol.kind);

    const r0 = try explorer.findAllSymbols("R0", alloc);
    defer alloc.free(r0);
    try testing.expectEqual(@as(usize, 1), r0.len);
}


test "issue-179: Python inline docstring does not leak symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("mod.py",
        \\def real_func():
        \\    """This docstring contains def fake(): pass"""
        \\    return 1
    );

    const real = try explorer.findAllSymbols("real_func", alloc);
    defer alloc.free(real);
    try testing.expect(real.len == 1);

    const fake = try explorer.findAllSymbols("fake", alloc);
    defer alloc.free(fake);
    try testing.expectEqual(@as(usize, 0), fake.len);
}


test "issue-179: Python multi-line docstring with def inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("doc.py",
        \\def outer():
        \\    """
        \\    Example:
        \\        def inner_example():
        \\            pass
        \\    """
        \\    return True
    );

    const outer = try explorer.findAllSymbols("outer", alloc);
    defer alloc.free(outer);
    try testing.expect(outer.len == 1);

    const inner = try explorer.findAllSymbols("inner_example", alloc);
    defer alloc.free(inner);
    try testing.expectEqual(@as(usize, 0), inner.len);
}


test "issue-331: C parser does not index indented call sites as functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var explorer = Explorer.init(a, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("test.c",
        \\void real_func(int x) {
        \\    fprintf(stderr, "curl_easy_perform() failed: %s\n",
        \\            curl_easy_strerror(res));
        \\    curl_easy_perform(curl);
        \\    if (SSL_get_options(ctx))
        \\        return;
        \\}
    );

    const syms = explorer.outlines.get("test.c").?.symbols.items;
    var found_false = false;
    for (syms) |sym| {
        if (sym.kind == .function) {
            if (std.mem.eql(u8, sym.name, "fprintf") or
                std.mem.eql(u8, sym.name, "curl_easy_perform") or
                std.mem.eql(u8, sym.name, "curl_easy_strerror") or
                std.mem.eql(u8, sym.name, "SSL_get_options"))
            {
                found_false = true;
            }
        }
    }
    try testing.expect(!found_false);
    var found_real = false;
    for (syms) |sym| {
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "real_func"))
            found_real = true;
    }
    try testing.expect(found_real);
}


test "issue-331: C parser finds nginx-style split-line definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var explorer = Explorer.init(a, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("ngx_http_request.c",
        \\ngx_int_t
        \\ngx_http_init_connection(ngx_connection_t *c)
        \\{
        \\    ngx_http_connection_t  *hc;
        \\}
        \\
        \\static ngx_int_t
        \\ngx_http_create_request(ngx_http_request_t *r)
        \\{
        \\    return NGX_OK;
        \\}
    );

    const syms = explorer.outlines.get("ngx_http_request.c").?.symbols.items;
    var found_init = false;
    var found_create = false;
    for (syms) |sym| {
        if (sym.kind == .function) {
            if (std.mem.eql(u8, sym.name, "ngx_http_init_connection")) found_init = true;
            if (std.mem.eql(u8, sym.name, "ngx_http_create_request")) found_create = true;
        }
    }
    try testing.expect(found_init);
    try testing.expect(found_create);
}


test "issue-392: Swift parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("Sources/App/Greeter.swift",
        \\import Foundation
        \\import UIKit
        \\
        \\public struct Greeter {
        \\    let name: String
        \\
        \\    public func greet() -> String {
        \\        return "Hello, \(name)"
        \\    }
        \\}
        \\
        \\public class HomeViewController: UIViewController {
        \\    public override func viewDidLoad() {
        \\        super.viewDidLoad()
        \\    }
        \\}
        \\
        \\public protocol Reloadable {
        \\    func reload()
        \\}
        \\
        \\public enum LoadState {
        \\    case idle
        \\    case loading
        \\}
        \\
        \\public func topLevel() -> Int { return 42 }
    );

    var outline = (try explorer.getOutline("Sources/App/Greeter.swift", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    // Detected language must surface as "swift" — main has no Language.swift,
    // so the file falls into .unknown and no parser runs.
    try testing.expectEqualStrings("swift", @tagName(outline.language));

    var found_struct = false;
    var found_class = false;
    var found_protocol = false;
    var found_enum = false;
    var found_top_fn = false;
    var found_method = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Greeter")) found_struct = true;
        if (std.mem.eql(u8, sym.name, "HomeViewController")) found_class = true;
        if (std.mem.eql(u8, sym.name, "Reloadable")) found_protocol = true;
        if (std.mem.eql(u8, sym.name, "LoadState")) found_enum = true;
        if (std.mem.eql(u8, sym.name, "topLevel")) found_top_fn = true;
        if (std.mem.eql(u8, sym.name, "greet")) found_method = true;
    }
    try testing.expect(found_struct);
    try testing.expect(found_class);
    try testing.expect(found_protocol);
    try testing.expect(found_enum);
    try testing.expect(found_top_fn);
    try testing.expect(found_method);
}

test "issue-532: ReScript parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("src/User.res",
        \\open Belt
        \\
        \\module User = {
        \\    type t = {
        \\        name: string,
        \\        age: int,
        \\    }
        \\
        \\    let make = (name, age) => {name, age}
        \\
        \\    let greet = user => "Hi " ++ user.name
        \\}
        \\
        \\type status = Active | Inactive
        \\
        \\let defaultName = "anon"
        \\
        \\let rec fib = n => if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
        \\
        \\external getEnv: string => string = "%identity"
    );

    var outline = (try explorer.getOutline("src/User.res", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    // .res must detect as rescript; without it the file is .unknown and no parser runs.
    try testing.expectEqualStrings("rescript", @tagName(outline.language));

    // Module → struct_def, type → type_alias, arrow-let → function, value-let → constant,
    // external → function. `open` is recorded as an import.
    try expectOutlineSymbol(&outline, "User", .struct_def);
    try expectOutlineSymbol(&outline, "t", .type_alias);
    try expectOutlineSymbol(&outline, "status", .type_alias);
    try expectOutlineSymbol(&outline, "make", .function);
    try expectOutlineSymbol(&outline, "greet", .function);
    try expectOutlineSymbol(&outline, "fib", .function);
    try expectOutlineSymbol(&outline, "getEnv", .function);
    try expectOutlineSymbol(&outline, "defaultName", .constant);
    try expectOutlineImport(&outline, "Belt");
}


// ─── audit (2026-06-09): latent-issue sweep — parser/deps fixes ───

// src/explore.zig parseDelimitedImport — Kotlin/Swift `import X as Y` stored "X as Y" as
// the dep key because the alias-trim was skipped for the empty-delimiter callers.
test "audit: Kotlin import alias stripped from dep path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer.indexFile("Main.kt", "import com.example.Foo as Bar\n");
    var outline = (try explorer.getOutline("Main.kt", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var saw_clean = false;
    var saw_aliased = false;
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, "com.example.Foo")) saw_clean = true;
        if (std.mem.eql(u8, imp, "com.example.Foo as Bar")) saw_aliased = true;
    }
    try testing.expect(saw_clean);
    try testing.expect(!saw_aliased);
}

// src/explore.zig getImportedBy — basename fallback over-attached an ambiguous bare
// import to every same-basename file; now skipped when the basename is ambiguous.
test "audit: ambiguous bare import must not cross same-basename dirs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("a/conf.py", "x = 1\n");
    try explorer.indexFile("b/conf.py", "y = 2\n");
    try explorer.indexFile("importer.py", "import conf\n");

    const a_imp = try explorer.getImportedBy("a/conf.py", testing.allocator);
    defer {
        for (a_imp) |i| testing.allocator.free(i);
        testing.allocator.free(a_imp);
    }
    const b_imp = try explorer.getImportedBy("b/conf.py", testing.allocator);
    defer {
        for (b_imp) |i| testing.allocator.free(i);
        testing.allocator.free(b_imp);
    }

    var a_attached = false;
    for (a_imp) |i| {
        if (std.mem.eql(u8, i, "importer.py")) a_attached = true;
    }
    var b_attached = false;
    for (b_imp) |i| {
        if (std.mem.eql(u8, i, "importer.py")) b_attached = true;
    }

    // the same ambiguous bare import must not be attributed to two same-basename files
    try testing.expect(!(a_attached and b_attached));
}

// src/explore.zig extractPythonModulePath/parsePythonLine — `import a, b` recorded only
// the first module; now one dep is recorded per comma-separated module.
test "audit: Python comma import records all modules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("m.py", "import alpha, beta\n");

    var outline = (try explorer.getOutline("m.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineImport(&outline, "alpha.py");
    try expectOutlineImport(&outline, "beta.py");
}


// renderImportedBy (the MCP codedb_deps reverse path) kept the unconditional
// basename fallback when getImportedBy gained the ambiguity guard — the same
// bare import is still attributed to every same-basename file through the
// main deps tool.
test "issue-588: renderImportedBy suppresses the ambiguous basename fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);

    try explorer.indexFile("a/conf.py", "x = 1\n");
    try explorer.indexFile("b/conf.py", "y = 2\n");
    try explorer.indexFile("importer.py", "import conf\n");

    var a_out: std.ArrayList(u8) = .empty;
    defer a_out.deinit(testing.allocator);
    _ = try explorer.renderImportedBy("a/conf.py", testing.allocator, &a_out);
    var b_out: std.ArrayList(u8) = .empty;
    defer b_out.deinit(testing.allocator);
    _ = try explorer.renderImportedBy("b/conf.py", testing.allocator, &b_out);

    const a_attached = std.mem.indexOf(u8, a_out.items, "importer.py") != null;
    const b_attached = std.mem.indexOf(u8, b_out.items, "importer.py") != null;
    // The ambiguous bare import must not be attributed to both files.
    try testing.expect(!(a_attached and b_attached));

    // Single-basename case keeps the fallback: with exactly one conf.py the
    // importer is still listed.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var explorer2 = Explorer.init(arena2.allocator(), Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try explorer2.indexFile("a/conf.py", "x = 1\n");
    try explorer2.indexFile("importer.py", "import conf\n");

    var solo_out: std.ArrayList(u8) = .empty;
    defer solo_out.deinit(testing.allocator);
    _ = try explorer2.renderImportedBy("a/conf.py", testing.allocator, &solo_out);
    try testing.expect(std.mem.indexOf(u8, solo_out.items, "importer.py") != null);
}
