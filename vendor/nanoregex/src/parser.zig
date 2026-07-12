//! Recursive-descent regex parser. Pattern bytes → AST.
//!
//! Grammar (v1, mirrors the Python re subset we ship as feature parity):
//!
//!   regex      ::= alt
//!   alt        ::= concat ('|' concat)*
//!   concat     ::= atom*
//!   atom       ::= primary quantifier?
//!   primary    ::= literal | dot | class | anchor | group
//!   group      ::= '(' ('?:')? regex ')'
//!   class      ::= '[' '^'? class_item+ ']'
//!   class_item ::= char | char '-' char | escape
//!   quantifier ::= ( '?' | '*' | '+' | '{' n (',' m?)? '}' ) '?'?
//!
//! Deferred to v2: backreferences, lookarounds, named groups, inline flags.
//!
//! All AST nodes are allocated in the caller-provided allocator (expected to
//! be a Regex-owned arena). Parse errors return a typed error; the partial
//! AST is freed when the arena drops.

const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedEnd,
    UnbalancedParen,
    UnbalancedBracket,
    InvalidEscape,
    InvalidQuantifier,
    NothingToRepeat,
    InvalidCharRange,
    OutOfMemory,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    /// Count of capturing groups seen so far. Incremented on `(` (but not
    /// on `(?:`). Used to assign group indices in declaration order.
    n_groups: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, pattern: []const u8) Parser {
        return .{ .alloc = alloc, .src = pattern };
    }

    pub fn parseRoot(self: *Parser) ParseError!*const ast.Node {
        const root = try self.parseAlt();
        if (self.pos < self.src.len) {
            // A stray closing `)` would land here.
            return ParseError.UnbalancedParen;
        }
        return root;
    }

    // ── alt = concat ('|' concat)* ──

    fn parseAlt(self: *Parser) ParseError!*const ast.Node {
        var branches: std.ArrayList(*const ast.Node) = .empty;
        defer branches.deinit(self.alloc);

        try branches.append(self.alloc, try self.parseConcat());
        while (self.peek() == '|') {
            self.pos += 1;
            try branches.append(self.alloc, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        const slice = try self.alloc.dupe(*const ast.Node, branches.items);
        return try self.node(.{ .alt = slice });
    }

    // ── concat = atom* ──

    fn parseConcat(self: *Parser) ParseError!*const ast.Node {
        var pieces: std.ArrayList(*const ast.Node) = .empty;
        defer pieces.deinit(self.alloc);

        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '|' or c == ')') break;
            try pieces.append(self.alloc, try self.parseAtom());
        }
        if (pieces.items.len == 0) {
            // Empty concat matches the empty string. Represent as an empty
            // concat node — the matcher treats it as zero-width success.
            const slice = try self.alloc.dupe(*const ast.Node, &.{});
            return try self.node(.{ .concat = slice });
        }
        if (pieces.items.len == 1) return pieces.items[0];
        const slice = try self.alloc.dupe(*const ast.Node, pieces.items);
        return try self.node(.{ .concat = slice });
    }

    // ── atom = primary quantifier? ──

    fn parseAtom(self: *Parser) ParseError!*const ast.Node {
        const primary = try self.parsePrimary();
        return try self.maybeQuantify(primary);
    }

    fn parsePrimary(self: *Parser) ParseError!*const ast.Node {
        if (self.pos >= self.src.len) return ParseError.UnexpectedEnd;
        const c = self.src[self.pos];
        switch (c) {
            '.' => {
                self.pos += 1;
                return try self.node(.dot);
            },
            '^' => {
                self.pos += 1;
                return try self.node(.{ .anchor = .line_start });
            },
            '$' => {
                self.pos += 1;
                return try self.node(.{ .anchor = .line_end });
            },
            '(' => return try self.parseGroup(),
            '[' => return try self.parseClass(),
            '\\' => return try self.parseEscape(),
            '*', '+', '?', '{' => return ParseError.NothingToRepeat,
            ')', '|' => return ParseError.UnexpectedEnd,
            else => {
                self.pos += 1;
                return try self.node(.{ .literal = c });
            },
        }
    }

    // ── group = '(' ('?:')? regex ')' ──

    fn parseGroup(self: *Parser) ParseError!*const ast.Node {
        std.debug.assert(self.src[self.pos] == '(');
        self.pos += 1;

        var capturing = true;
        if (self.pos + 1 < self.src.len and self.src[self.pos] == '?' and self.src[self.pos + 1] == ':') {
            capturing = false;
            self.pos += 2;
        }

        // Reserve the capture index BEFORE recursing so nested groups get
        // higher indices, matching Python re's left-paren declaration order.
        var index: u32 = 0;
        if (capturing) {
            self.n_groups += 1;
            index = self.n_groups;
        }

        const sub = try self.parseAlt();

        if (self.peek() != ')') return ParseError.UnbalancedParen;
        self.pos += 1;

        const g = try self.alloc.create(ast.Group);
        g.* = .{ .sub = sub, .index = index, .capturing = capturing };
        return try self.node(.{ .group = g });
    }

    // ── class = '[' '^'? items ']' ──

    fn parseClass(self: *Parser) ParseError!*const ast.Node {
        std.debug.assert(self.src[self.pos] == '[');
        self.pos += 1;

        const cls = try self.alloc.create(ast.Class);
        cls.* = ast.Class.empty();

        var negate = false;
        if (self.peek() == '^') {
            negate = true;
            self.pos += 1;
        }

        // A `]` as the very first char inside the class is treated as a
        // literal `]`, matching Python re's behaviour. Otherwise `]` ends.
        var first = true;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ']' and !first) break;
            first = false;

            const lo = try self.parseClassChar();
            // Range `a-z` only if the `-` is followed by a non-`]` char.
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] != ']') {
                self.pos += 1; // consume '-'
                const hi = try self.parseClassChar();
                if (hi < lo) return ParseError.InvalidCharRange;
                cls.setRange(lo, hi);
            } else {
                cls.set(lo);
            }
        }
        if (self.peek() != ']') return ParseError.UnbalancedBracket;
        self.pos += 1;

        if (negate) cls.negate();
        return try self.node(.{ .class = cls });
    }

    fn parseClassChar(self: *Parser) ParseError!u8 {
        if (self.pos >= self.src.len) return ParseError.UnbalancedBracket;
        const c = self.src[self.pos];
        if (c == '\\') {
            self.pos += 1;
            if (self.pos >= self.src.len) return ParseError.InvalidEscape;
            const e = self.src[self.pos];
            self.pos += 1;
            return switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                else => e,
            };
        }
        self.pos += 1;
        return c;
    }

    // ── escape = '\' (shorthand | metaliteral) ──

    fn parseEscape(self: *Parser) ParseError!*const ast.Node {
        std.debug.assert(self.src[self.pos] == '\\');
        self.pos += 1;
        if (self.pos >= self.src.len) return ParseError.InvalidEscape;
        const e = self.src[self.pos];
        self.pos += 1;
        return switch (e) {
            'd' => try self.shorthandClass(digitClass()),
            'D' => try self.shorthandClass(negated(digitClass())),
            'w' => try self.shorthandClass(wordClass()),
            'W' => try self.shorthandClass(negated(wordClass())),
            's' => try self.shorthandClass(spaceClass()),
            'S' => try self.shorthandClass(negated(spaceClass())),
            'b' => try self.node(.{ .anchor = .word_boundary }),
            'B' => try self.node(.{ .anchor = .non_word_boundary }),
            'A' => try self.node(.{ .anchor = .string_start }),
            'z' => try self.node(.{ .anchor = .string_end }),
            'n' => try self.node(.{ .literal = '\n' }),
            't' => try self.node(.{ .literal = '\t' }),
            'r' => try self.node(.{ .literal = '\r' }),
            '0' => try self.node(.{ .literal = 0 }),
            else => try self.node(.{ .literal = e }),
        };
    }

    fn shorthandClass(self: *Parser, cls_value: ast.Class) ParseError!*const ast.Node {
        const cls = try self.alloc.create(ast.Class);
        cls.* = cls_value;
        return try self.node(.{ .class = cls });
    }

    fn digitClass() ast.Class {
        var c = ast.Class.empty();
        c.setRange('0', '9');
        return c;
    }

    fn wordClass() ast.Class {
        var c = ast.Class.empty();
        c.setRange('a', 'z');
        c.setRange('A', 'Z');
        c.setRange('0', '9');
        c.set('_');
        return c;
    }

    fn spaceClass() ast.Class {
        var c = ast.Class.empty();
        c.set(' ');
        c.set('\t');
        c.set('\n');
        c.set('\r');
        c.set(0x0b); // \v
        c.set(0x0c); // \f
        return c;
    }

    fn negated(cls_in: ast.Class) ast.Class {
        var c = cls_in;
        c.negate();
        return c;
    }

    // ── quantifier ──

    fn maybeQuantify(self: *Parser, primary: *const ast.Node) ParseError!*const ast.Node {
        if (self.pos >= self.src.len) return primary;
        const c = self.src[self.pos];
        var min: u32 = 0;
        var max: u32 = 0;
        switch (c) {
            '?' => {
                self.pos += 1;
                min = 0;
                max = 1;
            },
            '*' => {
                self.pos += 1;
                min = 0;
                max = std.math.maxInt(u32);
            },
            '+' => {
                self.pos += 1;
                min = 1;
                max = std.math.maxInt(u32);
            },
            '{' => {
                const parsed = try self.parseCountedQuantifier();
                min = parsed.min;
                max = parsed.max;
            },
            else => return primary,
        }
        var greedy = true;
        if (self.peek() == '?') {
            greedy = false;
            self.pos += 1;
        }
        const r = try self.alloc.create(ast.Repeat);
        r.* = .{ .sub = primary, .min = min, .max = max, .greedy = greedy };
        return try self.node(.{ .repeat = r });
    }

    fn parseCountedQuantifier(self: *Parser) ParseError!struct { min: u32, max: u32 } {
        std.debug.assert(self.src[self.pos] == '{');
        self.pos += 1;
        const lo = try self.readNumber();
        var hi = lo;
        if (self.peek() == ',') {
            self.pos += 1;
            if (self.peek() == '}') {
                hi = std.math.maxInt(u32);
            } else {
                hi = try self.readNumber();
            }
        }
        if (self.peek() != '}') return ParseError.InvalidQuantifier;
        self.pos += 1;
        if (hi < lo) return ParseError.InvalidQuantifier;
        return .{ .min = lo, .max = hi };
    }

    fn readNumber(self: *Parser) ParseError!u32 {
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
            self.pos += 1;
        }
        if (self.pos == start) return ParseError.InvalidQuantifier;
        return std.fmt.parseInt(u32, self.src[start..self.pos], 10) catch ParseError.InvalidQuantifier;
    }

    // ── Helpers ──

    fn peek(self: *const Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn node(self: *Parser, value: ast.Node) ParseError!*const ast.Node {
        const n = try self.alloc.create(ast.Node);
        n.* = value;
        return n;
    }
};

// ── Tests ──

fn parseToString(alloc: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), pattern);
    const root = try p.parseRoot();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try ast.debugWrite(root, &buf, alloc, 0);
    return alloc.dupe(u8, buf.items);
}

test "parse single literal" {
    const out = try parseToString(std.testing.allocator, "a");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("literal 'a'\n", out);
}

test "parse concat of literals" {
    const out = try parseToString(std.testing.allocator, "abc");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\concat
        \\  literal 'a'
        \\  literal 'b'
        \\  literal 'c'
        \\
    , out);
}

test "parse alternation" {
    const out = try parseToString(std.testing.allocator, "a|b");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\alt
        \\  literal 'a'
        \\  literal 'b'
        \\
    , out);
}

test "parse star quantifier" {
    const out = try parseToString(std.testing.allocator, "a*");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\repeat min=0 max=4294967295 greedy=true
        \\  literal 'a'
        \\
    , out);
}

test "parse lazy quantifier" {
    const out = try parseToString(std.testing.allocator, "a+?");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\repeat min=1 max=4294967295 greedy=false
        \\  literal 'a'
        \\
    , out);
}

test "parse counted quantifier" {
    const out = try parseToString(std.testing.allocator, "a{2,5}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\repeat min=2 max=5 greedy=true
        \\  literal 'a'
        \\
    , out);
}

test "parse char class with range" {
    const out = try parseToString(std.testing.allocator, "[a-z]");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("class [26 bytes]\n", out);
}

test "parse capturing group" {
    const out = try parseToString(std.testing.allocator, "(abc)");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\group #1 cap=true
        \\  concat
        \\    literal 'a'
        \\    literal 'b'
        \\    literal 'c'
        \\
    , out);
}

test "parse non-capturing group" {
    const out = try parseToString(std.testing.allocator, "(?:abc)");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\group #0 cap=false
        \\  concat
        \\    literal 'a'
        \\    literal 'b'
        \\    literal 'c'
        \\
    , out);
}

test "parse shorthand class \\d" {
    const out = try parseToString(std.testing.allocator, "\\d");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("class [10 bytes]\n", out);
}

test "parse anchor word_boundary" {
    const out = try parseToString(std.testing.allocator, "\\b");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("anchor word_boundary\n", out);
}

test "parse unbalanced paren errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "(abc");
    try std.testing.expectError(ParseError.UnbalancedParen, p.parseRoot());
}

test "parse nothing-to-repeat errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "*abc");
    try std.testing.expectError(ParseError.NothingToRepeat, p.parseRoot());
}
