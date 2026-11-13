//! Kiln: a small owned JSON DOM. Nodes are preorder; `next` skips a subtree.
//! All strings are decoded into one owned byte buffer. Input may be freed after parse.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tag = enum(u32) { null_value, false_value, true_value, number, string, array, object };
pub const Node = extern struct {
    payload: u64 = 0,
    next: u32 = 0,
    tag: Tag,

    pub fn len(self: Node) u32 {
        return @intCast(if (self.tag == .string) self.payload >> 32 else self.payload);
    }

    pub fn number(self: Node) f64 {
        std.debug.assert(self.tag == .number);
        return @bitCast(self.payload);
    }
};
pub const Options = struct { max_depth: usize = 256 };
pub const ParseError = error{ InvalidJson, DepthLimit, DocumentTooLarge, OutOfMemory };
pub const Diagnostic = struct { offset: usize = 0 };

pub const Document = struct {
    allocator: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    strings: std.ArrayList(u8) = .empty,

    pub fn parse(allocator: Allocator, input: []const u8, options: Options, diagnostic: ?*Diagnostic) ParseError!Document {
        if (input.len > std.math.maxInt(u32)) return error.DocumentTooLarge;
        var parser = Parser{ .input = input, .doc = .{ .allocator = allocator }, .options = options };
        errdefer parser.doc.deinit();
        errdefer if (diagnostic) |d| {
            d.offset = parser.pos;
        };
        // A hint, not a bound: dense inputs grow normally and are never truncated.
        try parser.doc.nodes.ensureTotalCapacity(allocator, @max(8, input.len / 32));
        parser.whitespace();
        _ = try parser.value(0);
        parser.whitespace();
        if (parser.pos != input.len) return error.InvalidJson;
        // The DOM is immutable: return spare growth capacity to the allocator.
        parser.doc.nodes = .fromOwnedSlice(try parser.doc.nodes.toOwnedSlice(allocator));
        parser.doc.strings = .fromOwnedSlice(try parser.doc.strings.toOwnedSlice(allocator));
        return parser.doc;
    }

    pub fn deinit(self: *Document) void {
        self.nodes.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn string(self: *const Document, node: Node) []const u8 {
        std.debug.assert(node.tag == .string);
        const start: usize = @as(u32, @truncate(node.payload));
        return self.strings.items[start..][0..node.len()];
    }

    /// Returns the first matching member; duplicate keys and input order are preserved.
    pub fn get(self: *const Document, object: u32, key: []const u8) ?u32 {
        const node = self.nodes.items[object];
        if (node.tag != .object) return null;
        var i = object + 1;
        while (i < node.next) {
            const value_index = i + 1;
            if (std.mem.eql(u8, self.string(self.nodes.items[i]), key)) return value_index;
            i = self.nodes.items[value_index].next;
        }
        return null;
    }

    /// Allocator-requested capacity; excludes allocator metadata and Document itself.
    pub fn capacityBytes(self: *const Document) usize {
        return self.nodes.capacity * @sizeOf(Node) + self.strings.capacity;
    }

    /// Traverses every node and decoded string byte, for cross-library benchmark checks.
    pub fn checksum(self: *const Document) u64 {
        var hash: u64 = 14695981039346656037;
        for (self.nodes.items) |node| {
            hash = mix(hash, @intFromEnum(node.tag));
            switch (node.tag) {
                .number => hash = mix(hash, node.payload),
                .string => for (self.string(node)) |c| {
                    hash = mix(hash, c);
                },
                else => {},
            }
        }
        return hash;
    }
};

fn mix(hash: u64, value_: u64) u64 {
    return (hash ^ value_) *% 1099511628211;
}

const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    doc: Document,
    options: Options,

    fn whitespace(self: *Parser) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => break,
            }
        }
    }

    fn append(self: *Parser, node: Node) ParseError!u32 {
        if (self.doc.nodes.items.len == std.math.maxInt(u32)) return error.DocumentTooLarge;
        const index: u32 = @intCast(self.doc.nodes.items.len);
        try self.doc.nodes.append(self.doc.allocator, node);
        return index;
    }

    fn value(self: *Parser, depth: usize) ParseError!u32 {
        if (self.pos == self.input.len) return error.InvalidJson;
        const index: u32 = switch (self.input[self.pos]) {
            '{' => return self.container(depth, .object),
            '[' => return self.container(depth, .array),
            '"' => try self.parseString(),
            'n' => try self.literal("null", .null_value),
            't' => try self.literal("true", .true_value),
            'f' => try self.literal("false", .false_value),
            '-', '0'...'9' => try self.parseNumber(),
            else => return error.InvalidJson,
        };
        self.doc.nodes.items[index].next = index + 1;
        return index;
    }

    fn literal(self: *Parser, text: []const u8, tag: Tag) ParseError!u32 {
        if (!std.mem.startsWith(u8, self.input[self.pos..], text)) return error.InvalidJson;
        self.pos += text.len;
        return self.append(.{ .tag = tag });
    }

    fn container(self: *Parser, depth: usize, tag: Tag) ParseError!u32 {
        if (depth >= self.options.max_depth) return error.DepthLimit;
        const index = try self.append(.{ .tag = tag });
        const close: u8 = if (tag == .array) ']' else '}';
        self.pos += 1;
        self.whitespace();
        var count: u32 = 0;
        if (self.pos < self.input.len and self.input[self.pos] == close) {
            self.pos += 1;
        } else while (true) {
            if (tag == .object) {
                if (self.pos == self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
                const key = try self.parseString();
                self.doc.nodes.items[key].next = key + 1;
                self.whitespace();
                if (self.pos == self.input.len or self.input[self.pos] != ':') return error.InvalidJson;
                self.pos += 1;
                self.whitespace();
            }
            _ = try self.value(depth + 1);
            count += 1;
            self.whitespace();
            if (self.pos == self.input.len) return error.InvalidJson;
            const c = self.input[self.pos];
            self.pos += 1;
            if (c == close) break;
            if (c != ',') return error.InvalidJson;
            self.whitespace();
        }
        self.doc.nodes.items[index].next = @intCast(self.doc.nodes.items.len);
        self.doc.nodes.items[index].payload = count;
        return index;
    }

    fn parseNumber(self: *Parser) ParseError!u32 {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos == self.input.len) return error.InvalidJson;
        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else {
            if (self.input[self.pos] < '1' or self.input[self.pos] > '9') return error.InvalidJson;
            self.digits();
        }
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            const before = self.pos;
            self.digits();
            if (self.pos == before) return error.InvalidJson;
        }
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) self.pos += 1;
            const before = self.pos;
            self.digits();
            if (self.pos == before) return error.InvalidJson;
        }
        const raw = self.input[start..self.pos];
        const negative = raw[0] == '-';
        const unsigned = raw[@intFromBool(negative)..];
        // Exact integer accumulation then one correctly rounded conversion to f64.
        // Decimal/exponent and long integer cases use the standard float parser.
        if (unsigned.len <= 18) {
            var integer: u64 = 0;
            var all_digits = true;
            for (unsigned) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
                integer = integer * 10 + (c - '0');
            }
            if (all_digits) {
                const magnitude: f64 = @floatFromInt(integer);
                const number_ = if (negative) -magnitude else magnitude;
                return self.append(.{ .tag = .number, .payload = @bitCast(number_) });
            }
        }
        const number_ = std.fmt.parseFloat(f64, raw) catch return error.InvalidJson;
        if (!std.math.isFinite(number_)) return error.InvalidJson;
        return self.append(.{ .tag = .number, .payload = @bitCast(number_) });
    }

    fn digits(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') self.pos += 1;
    }

    fn parseString(self: *Parser) ParseError!u32 {
        self.pos += 1;
        const output_start = self.doc.strings.items.len;
        var run = self.pos;
        while (true) {
            // Bounds checked vector loads; catch quotes, escapes, controls, and UTF-8.
            const V = @Vector(16, u8);
            while (self.input.len - self.pos >= 16) {
                const bytes: V = self.input[self.pos..][0..16].*;
                const special = (bytes == @as(V, @splat('"'))) | (bytes == @as(V, @splat('\\'))) | (bytes < @as(V, @splat(0x20))) | (bytes >= @as(V, @splat(0x80)));
                if (std.simd.firstTrue(special)) |offset| {
                    self.pos += offset;
                    break;
                }
                self.pos += 16;
            }
            if (self.pos == self.input.len) return error.InvalidJson;
            const c = self.input[self.pos];
            if (c == '"') {
                try self.doc.strings.appendSlice(self.doc.allocator, self.input[run..self.pos]);
                self.pos += 1;
                return self.append(.{ .tag = .string, .payload = @as(u64, @intCast(output_start)) | (@as(u64, @intCast(self.doc.strings.items.len - output_start)) << 32) });
            }
            if (c < 0x20) return error.InvalidJson;
            if (c == '\\') {
                try self.doc.strings.appendSlice(self.doc.allocator, self.input[run..self.pos]);
                self.pos += 1;
                if (self.pos == self.input.len) return error.InvalidJson;
                const escaped = self.input[self.pos];
                self.pos += 1;
                switch (escaped) {
                    '"', '\\', '/' => try self.doc.strings.append(self.doc.allocator, escaped),
                    'b' => try self.doc.strings.append(self.doc.allocator, 8),
                    'f' => try self.doc.strings.append(self.doc.allocator, 12),
                    'n' => try self.doc.strings.append(self.doc.allocator, 10),
                    'r' => try self.doc.strings.append(self.doc.allocator, 13),
                    't' => try self.doc.strings.append(self.doc.allocator, 9),
                    'u' => {
                        var cp: u21 = try self.hex4();
                        if (cp >= 0xd800 and cp <= 0xdbff) {
                            if (!std.mem.startsWith(u8, self.input[self.pos..], "\\u")) return error.InvalidJson;
                            self.pos += 2;
                            const low = try self.hex4();
                            if (low < 0xdc00 or low > 0xdfff) return error.InvalidJson;
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                        } else if (cp >= 0xdc00 and cp <= 0xdfff) return error.InvalidJson;
                        var encoded: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidJson;
                        try self.doc.strings.appendSlice(self.doc.allocator, encoded[0..n]);
                    },
                    else => return error.InvalidJson,
                }
                run = self.pos;
            } else if (c >= 0x80) {
                const n = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidJson;
                if (n > self.input.len - self.pos) return error.InvalidJson;
                _ = std.unicode.utf8Decode(self.input[self.pos..][0..n]) catch return error.InvalidJson;
                self.pos += n;
            } else {
                self.pos += 1;
            }
        }
    }

    fn hex4(self: *Parser) ParseError!u21 {
        if (self.input.len - self.pos < 4) return error.InvalidJson;
        var result: u21 = 0;
        for (self.input[self.pos..][0..4]) |c| {
            const digit: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidJson,
            };
            result = (result << 4) | digit;
        }
        self.pos += 4;
        return result;
    }
};

test "owned strings, preorder traversal, lookup, numbers" {
    var input = [_]u8{ '[', '"', 'x', '"', ',', '1', ']' };
    var doc = try Document.parse(std.testing.allocator, &input, .{}, null);
    defer doc.deinit();
    @memset(&input, ' ');
    try std.testing.expectEqualStrings("x", doc.string(doc.nodes.items[1]));
    try std.testing.expectEqual(@as(f64, 1), doc.nodes.items[2].number());
    try std.testing.expectEqual(@as(u32, 3), doc.nodes.items[0].next);
    var object = try Document.parse(std.testing.allocator, "{\"a\":[1,{\"x\":true}],\"b\":-0.25e2,\"a\":2}", .{}, null);
    defer object.deinit();
    try std.testing.expectEqual(Tag.array, object.nodes.items[object.get(0, "a").?].tag);
    try std.testing.expectEqual(@as(f64, -25), object.nodes.items[object.get(0, "b").?].number());
    try std.testing.expect(object.get(0, "missing") == null);
}

test "escapes, surrogate pairs, raw UTF-8, embedded zero" {
    var doc = try Document.parse(std.testing.allocator, "[\"\\uD83D\\uDE80\",\"\\u0000a\",\"हाय\",\"a\\n\\t\\b\\f\\r\\/\\\\\\\"\"]", .{}, null);
    defer doc.deinit();
    try std.testing.expectEqualStrings("🚀", doc.string(doc.nodes.items[1]));
    try std.testing.expectEqualStrings("\x00a", doc.string(doc.nodes.items[2]));
    try std.testing.expectEqualStrings("हाय", doc.string(doc.nodes.items[3]));
    try std.testing.expectEqualStrings("a\n\t\x08\x0c\r/\\\"", doc.string(doc.nodes.items[4]));
}

test "reject malformed inputs" {
    const cases = [_][]const u8{ "", " ", "01", "-01", "+1", "1.", "1e", "1e+", "NaN", "Infinity", "[1,]", "{\"a\":1,}", "[1 2]", "{a:1}", "true false", "null\x00", "\"\\x00\"", "\"\\uD800\"", "\"\\uDC00\"", "\"\xc0\x80\"", "\"\xed\xa0\x80\"", "\"\xf4\x90\x80\x80\"", "\"a\nb\"", "\"unterminated", "1e400" };
    for (cases) |input| try std.testing.expectError(error.InvalidJson, Document.parse(std.testing.allocator, input, .{}, null));
}

test "depth limit and diagnostics" {
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.DepthLimit, Document.parse(std.testing.allocator, "[[[]]]", .{ .max_depth = 2 }, &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), diagnostic.offset);
}

test "allocation failures release everything" {
    const Helper = struct {
        fn run(allocator: Allocator) !void {
            var doc = try Document.parse(allocator, "{\"hello\": [1, 2, 3, \"long enough to allocate\\u263a\"], \"nested\": {\"ok\": true}}", .{}, null);
            defer doc.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Helper.run, .{});
}

test "numeric rounding and signed zero" {
    const samples = [_][]const u8{ "-0", "-0.0", "9007199254740993", "999999999999999999", "1e-324", "2.2250738585072014e-308", "1.7976931348623157e308" };
    for (samples) |sample| {
        var doc = try Document.parse(std.testing.allocator, sample, .{}, null);
        defer doc.deinit();
        const expected = try std.fmt.parseFloat(f64, sample);
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), doc.nodes.items[0].payload);
    }
}
