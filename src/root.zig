//! Kiln: a small owned JSON DOM. Nodes are preorder; `next` skips a subtree.
//! All strings are decoded into one owned byte buffer. Input may be freed after parse.
const std = @import("std");
const Allocator = std.mem.Allocator;
const convertEiselLemire = @import("float/convert_eisel_lemire.zig").convertEiselLemire;

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
    storage: []align(@alignOf(Node)) u8 = &.{},

    pub fn parse(allocator: Allocator, input: []const u8, options: Options, diagnostic: ?*Diagnostic) ParseError!Document {
        if (input.len > std.math.maxInt(u32)) return error.DocumentTooLarge;
        var parser = Parser{ .input = input, .doc = .{ .allocator = allocator }, .options = options };
        errdefer parser.doc.deinit();
        errdefer if (diagnostic) |d| {
            d.offset = parser.pos;
        };
        // Each value after the root is introduced by '[', '{', ',', or ':'.
        // Counting these even inside strings gives a conservative node bound.
        const node_capacity = nodeCapacityBound(input);
        const node_bytes = std.math.mul(usize, node_capacity, @sizeOf(Node)) catch return error.DocumentTooLarge;
        const total_bytes = std.math.add(usize, node_bytes, input.len) catch return error.DocumentTooLarge;
        parser.doc.storage = try allocator.alignedAlloc(u8, .of(Node), total_bytes);
        const node_ptr: [*]Node = @ptrCast(parser.doc.storage.ptr);
        parser.doc.nodes = .{ .items = node_ptr[0..0], .capacity = node_capacity };
        const string_ptr = parser.doc.storage.ptr + node_bytes;
        parser.doc.strings = .{ .items = string_ptr[0..0], .capacity = input.len };
        parser.whitespace();
        _ = try parser.value(0);
        parser.whitespace();
        if (parser.pos != input.len) return error.InvalidJson;
        return parser.doc;
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.storage);
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

inline fn eightDigits(word: u64) bool {
    return ((word +% 0x4646464646464646) | (word -% 0x3030303030303030)) & 0x8080808080808080 == 0;
}

inline fn parseEightDigits(word: u64) u64 {
    var digits = word -% 0x3030303030303030;
    digits = (digits *% 10 +% (digits >> 8)) & 0x00ff00ff00ff00ff;
    digits = (digits *% 100 +% (digits >> 16)) & 0x0000ffff0000ffff;
    return (digits *% 10000 +% (digits >> 32)) & 0xffffffff;
}

fn nodeCapacityBound(input: []const u8) usize {
    var count: usize = 1;
    var pos: usize = 0;
    const V = @Vector(32, u8);
    while (input.len - pos >= 32) : (pos += 32) {
        const bytes: V = input[pos..][0..32].*;
        const markers = (bytes == @as(V, @splat('['))) | (bytes == @as(V, @splat('{'))) | (bytes == @as(V, @splat(','))) | (bytes == @as(V, @splat(':')));
        count += @popCount(@as(u32, @bitCast(markers)));
    }
    for (input[pos..]) |c| {
        count += @intFromBool(c == '[' or c == '{' or c == ',' or c == ':');
    }
    return count;
}

fn mix(hash: u64, value_: u64) u64 {
    return (hash ^ value_) *% 1099511628211;
}

const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    doc: Document,
    options: Options,

    inline fn whitespace(self: *Parser) void {
        const input = self.input;
        var pos = self.pos;
        while (pos < input.len) {
            const c = input[pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            if (input.len - pos >= 32) {
                const V = @Vector(32, u8);
                const bytes: V = input[pos..][0..32].*;
                const white = (bytes == @as(V, @splat(' '))) | (bytes == @as(V, @splat('\t'))) | (bytes == @as(V, @splat('\n'))) | (bytes == @as(V, @splat('\r')));
                const other: u32 = ~@as(u32, @bitCast(white));
                if (other != 0) {
                    pos += @ctz(other);
                    break;
                }
                pos += 32;
            } else pos += 1;
        }
        self.pos = pos;
    }

    inline fn append(self: *Parser, node: Node) u32 {
        const count = self.doc.nodes.items.len;
        std.debug.assert(count < self.doc.nodes.capacity);
        const index: u32 = @intCast(count);
        self.doc.nodes.items.len = count + 1;
        self.doc.nodes.items.ptr[count] = .{ .payload = node.payload, .next = index + 1, .tag = node.tag };
        return index;
    }

    inline fn value(self: *Parser, depth: usize) ParseError!u32 {
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
        return index;
    }

    fn literal(self: *Parser, text: []const u8, tag: Tag) ParseError!u32 {
        if (!std.mem.startsWith(u8, self.input[self.pos..], text)) return error.InvalidJson;
        self.pos += text.len;
        return self.append(.{ .tag = tag });
    }

    fn container(self: *Parser, depth: usize, comptime tag: Tag) ParseError!u32 {
        if (depth >= self.options.max_depth) return error.DepthLimit;
        const index = self.append(.{ .tag = tag });
        const close: u8 = if (tag == .array) ']' else '}';
        self.pos += 1;
        self.whitespace();
        var count: u32 = 0;
        if (self.pos < self.input.len and self.input[self.pos] == close) {
            self.pos += 1;
        } else while (true) {
            if (tag == .object) {
                if (self.pos == self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
                _ = try self.parseString();
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

    inline fn parseNumber(self: *Parser) ParseError!u32 {
        const input = self.input;
        const start = self.pos;
        var pos = start;
        errdefer self.pos = pos;
        const negative = input[pos] == '-';
        pos += @intFromBool(negative);
        if (pos == input.len) return error.InvalidJson;
        var mantissa: u64 = 0;
        const integer_start = pos;
        if (input[pos] == '0') {
            pos += 1;
        } else {
            if (input[pos] < '1' or input[pos] > '9') return error.InvalidJson;
            while (pos < input.len) : (pos += 1) {
                const digit = input[pos] -% '0';
                if (digit > 9) break;
                mantissa = mantissa *% 10 +% digit;
            }
        }
        var digits_count = pos - integer_start;
        var exponent: i64 = 0;
        if (pos < input.len and input[pos] == '.') {
            pos += 1;
            const fraction_start = pos;
            while (input.len - pos >= 8) {
                const word = std.mem.readInt(u64, input[pos..][0..8], .little);
                if (!eightDigits(word)) break;
                mantissa = mantissa *% 100_000_000 +% parseEightDigits(word);
                pos += 8;
            }
            while (pos < input.len) : (pos += 1) {
                const digit = input[pos] -% '0';
                if (digit > 9) break;
                mantissa = mantissa *% 10 +% digit;
            }
            const count = pos - fraction_start;
            if (count == 0) return error.InvalidJson;
            digits_count += count;
            exponent = -@as(i64, @intCast(count));
        }
        if (pos < input.len and (input[pos] == 'e' or input[pos] == 'E')) {
            pos += 1;
            var exponent_negative = false;
            if (pos < input.len and (input[pos] == '+' or input[pos] == '-')) {
                exponent_negative = input[pos] == '-';
                pos += 1;
            }
            const exponent_start = pos;
            var explicit_exponent: i64 = 0;
            while (pos < input.len) : (pos += 1) {
                const digit = input[pos] -% '0';
                if (digit > 9) break;
                explicit_exponent = @min(1_000_000, explicit_exponent * 10 + digit);
            }
            if (pos == exponent_start) return error.InvalidJson;
            exponent += if (exponent_negative) -explicit_exponent else explicit_exponent;
        }
        self.pos = pos;
        if (digits_count <= 19) {
            if (exponent == 0) {
                const magnitude: f64 = if (mantissa <= std.math.maxInt(i64))
                    @floatFromInt(@as(i64, @intCast(mantissa)))
                else
                    @floatFromInt(mantissa);
                return self.append(.{ .tag = .number, .payload = @bitCast(if (negative) -magnitude else magnitude) });
            }
            // Clinger fast path: both operands are exact, so one IEEE-754 operation
            // supplies the only rounding. Never multiply by a rounded reciprocal.
            if (mantissa <= (1 << 53) and exponent >= -22 and exponent <= 22) {
                const powers = comptime blk: {
                    var table: [23]f64 = undefined;
                    var power: u128 = 1;
                    for (0..23) |i| {
                        table[i] = @floatFromInt(power);
                        power *= 10;
                    }
                    break :blk table;
                };
                const magnitude: f64 = @floatFromInt(mantissa);
                const number_ = if (exponent < 0) magnitude / powers[@intCast(-exponent)] else magnitude * powers[@intCast(exponent)];
                return self.append(.{ .tag = .number, .payload = @bitCast(if (negative) -number_ else number_) });
            }
            // Reuse Zig's exact Eisel-Lemire converter with the digits already read.
            // Ambiguous rounding falls back to the standard parser below.
            if (convertEiselLemire(f64, exponent, mantissa)) |biased| {
                const number_ = biased.toFloat(f64, negative);
                if (!std.math.isFinite(number_)) return error.InvalidJson;
                return self.append(.{ .tag = .number, .payload = @bitCast(number_) });
            }
        }
        return self.slowNumber(input[start..pos]);
    }

    noinline fn slowNumber(self: *Parser, raw: []const u8) ParseError!u32 {
        const number_ = std.fmt.parseFloat(f64, raw) catch return error.InvalidJson;
        if (!std.math.isFinite(number_)) return error.InvalidJson;
        return self.append(.{ .tag = .number, .payload = @bitCast(number_) });
    }

    inline fn parseString(self: *Parser) ParseError!u32 {
        const output_start = self.doc.strings.items.len;
        var pos = self.pos + 1;
        var out = output_start;
        scanAscii(self.input, self.doc.strings.items.ptr, &pos, &out);
        self.pos = pos;
        if (pos == self.input.len) return error.InvalidJson;
        if (self.input[pos] == '"') return self.finishString(pos, out, output_start);
        return self.slowString(pos, out, output_start);
    }

    inline fn finishString(self: *Parser, pos: usize, out: usize, output_start: usize) u32 {
        self.pos = pos + 1;
        self.doc.strings.items.len = out;
        return self.append(.{ .tag = .string, .payload = @as(u64, @intCast(output_start)) | (@as(u64, @intCast(out - output_start)) << 32) });
    }

    inline fn scanAscii(input: []const u8, output: [*]u8, pos: *usize, out: *usize) void {
        const V = @Vector(32, u8);
        while (input.len - pos.* >= 32) {
            const bytes: V = input[pos.*..][0..32].*;
            const special = (bytes == @as(V, @splat('"'))) | (bytes == @as(V, @splat('\\'))) | (bytes < @as(V, @splat(0x20))) | (bytes >= @as(V, @splat(0x80)));
            const mask: u32 = @bitCast(special);
            if (mask == 0) {
                output[out.*..][0..32].* = @as([32]u8, bytes);
                pos.* += 32;
                out.* += 32;
            } else {
                const n = @ctz(mask);
                copyShort(output[out.*..][0..n], input[pos.*..][0..n]);
                pos.* += n;
                out.* += n;
                return;
            }
        }
        while (pos.* < input.len) {
            const c = input[pos.*];
            if (c == '"' or c == '\\' or c < 0x20 or c >= 0x80) return;
            output[out.*] = c;
            pos.* += 1;
            out.* += 1;
        }
    }

    noinline fn slowString(self: *Parser, initial_pos: usize, initial_out: usize, output_start: usize) ParseError!u32 {
        const input = self.input;
        const output = self.doc.strings.items.ptr;
        var pos = initial_pos;
        var out = initial_out;
        errdefer self.pos = pos;
        while (pos < input.len) {
            const c = input[pos];
            if (c == '"') return self.finishString(pos, out, output_start);
            if (c < 0x20) return error.InvalidJson;
            if (c == '\\') {
                pos += 1;
                if (pos == input.len) return error.InvalidJson;
                const escaped = input[pos];
                pos += 1;
                if (escaped != 'u') {
                    const decoded = escape_table[escaped];
                    if (decoded == 0xff) return error.InvalidJson;
                    output[out] = decoded;
                    out += 1;
                } else {
                    var cp: u21 = try hex4(input, &pos);
                    if (cp >= 0xd800 and cp <= 0xdbff) {
                        if (!std.mem.startsWith(u8, input[pos..], "\\u")) return error.InvalidJson;
                        pos += 2;
                        const low = try hex4(input, &pos);
                        if (low < 0xdc00 or low > 0xdfff) return error.InvalidJson;
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                    } else if (cp >= 0xdc00 and cp <= 0xdfff) return error.InvalidJson;
                    // A Unicode escape consumes >=6 bytes and emits <=4. The
                    // four-byte store stays inside the source-sized allocation.
                    var encoded: u32 = undefined;
                    var n: usize = undefined;
                    if (cp < 0x80) {
                        encoded = cp;
                        n = 1;
                    } else if (cp < 0x800) {
                        encoded = (cp >> 6 | 0xc0) | ((cp & 0x3f | 0x80) << 8);
                        n = 2;
                    } else if (cp < 0x10000) {
                        encoded = (cp >> 12 | 0xe0) | ((cp >> 6 & 0x3f | 0x80) << 8) | ((@as(u32, cp) & 0x3f | 0x80) << 16);
                        n = 3;
                    } else {
                        encoded = (cp >> 18 | 0xf0) | ((cp >> 12 & 0x3f | 0x80) << 8) | ((@as(u32, cp) >> 6 & 0x3f | 0x80) << 16) | ((@as(u32, cp) & 0x3f | 0x80) << 24);
                        n = 4;
                    }
                    std.debug.assert(out + 4 <= input.len);
                    std.mem.writeInt(u32, output[out..][0..4], encoded, .little);
                    out += n;
                }
            } else if (c >= 0x80) {
                const n = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidJson;
                if (n > input.len - pos) return error.InvalidJson;
                _ = std.unicode.utf8Decode(input[pos..][0..n]) catch return error.InvalidJson;
                inline for (0..4) |i| {
                    if (i < n) output[out + i] = input[pos + i];
                }
                pos += n;
                out += n;
            }
            scanAscii(input, output, &pos, &out);
        }
        return error.InvalidJson;
    }

    const escape_table = blk: {
        var table = [_]u8{0xff} ** 256;
        table['"'] = '"';
        table['\\'] = '\\';
        table['/'] = '/';
        table['b'] = 8;
        table['f'] = 12;
        table['n'] = 10;
        table['r'] = 13;
        table['t'] = 9;
        break :blk table;
    };

    const hex_table = blk: {
        var table = [_]u8{0xff} ** 256;
        for (0..10) |i| table['0' + i] = @intCast(i);
        for (0..6) |i| {
            table['a' + i] = @intCast(i + 10);
            table['A' + i] = @intCast(i + 10);
        }
        break :blk table;
    };

    inline fn copyShort(dest: []u8, bytes: []const u8) void {
        const len = bytes.len;
        std.debug.assert(len == dest.len and len < 32);
        // Overlapping first/last loads stay entirely within the actual string.
        if (len >= 16) {
            dest[0..16].* = bytes[0..16].*;
            dest[len - 16 ..][0..16].* = bytes[len - 16 ..][0..16].*;
        } else if (len >= 8) {
            dest[0..8].* = bytes[0..8].*;
            dest[len - 8 ..][0..8].* = bytes[len - 8 ..][0..8].*;
        } else if (len >= 4) {
            dest[0..4].* = bytes[0..4].*;
            dest[len - 4 ..][0..4].* = bytes[len - 4 ..][0..4].*;
        } else if (len >= 2) {
            dest[0..2].* = bytes[0..2].*;
            dest[len - 2 ..][0..2].* = bytes[len - 2 ..][0..2].*;
        } else if (len == 1) dest[0] = bytes[0];
    }

    inline fn hex4(input: []const u8, pos: *usize) ParseError!u21 {
        if (input.len - pos.* < 4) return error.InvalidJson;
        const a = hex_table[input[pos.*]];
        const b = hex_table[input[pos.* + 1]];
        const c = hex_table[input[pos.* + 2]];
        const d = hex_table[input[pos.* + 3]];
        if ((a | b | c | d) == 0xff) return error.InvalidJson;
        const result = (@as(u21, a) << 12) | (@as(u21, b) << 8) | (@as(u21, c) << 4) | d;
        pos.* += 4;
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

test "number conversion matches reference at fast-path boundaries" {
    var prng = std.Random.DefaultPrng.init(0x4b494c4e);
    const random = prng.random();
    var buffer: [128]u8 = undefined;
    for (0..20000) |i| {
        const mantissa = if (i % 2 == 0) random.int(u64) % 9007199254740993 else random.int(u64);
        const exponent = if (i % 3 == 0) random.intRangeAtMost(i16, -22, 22) else random.intRangeAtMost(i16, -350, 350);
        const raw = try std.fmt.bufPrint(&buffer, "{s}{d}e{d}", .{ if (random.boolean()) "-" else "", mantissa, exponent });
        const expected = try std.fmt.parseFloat(f64, raw);
        if (!std.math.isFinite(expected)) {
            try std.testing.expectError(error.InvalidJson, Document.parse(std.testing.allocator, raw, .{}, null));
        } else {
            var doc = try Document.parse(std.testing.allocator, raw, .{}, null);
            defer doc.deinit();
            try std.testing.expectEqual(@as(u64, @bitCast(expected)), doc.nodes.items[0].payload);
        }
    }
}

test "eight-digit scanner validates every byte and conversion" {
    var bytes = "12345678".*;
    try std.testing.expectEqual(@as(u64, 12345678), parseEightDigits(std.mem.readInt(u64, &bytes, .little)));
    for (0..8) |i| {
        const old = bytes[i];
        for (0..256) |c| {
            bytes[i] = @intCast(c);
            try std.testing.expectEqual(c >= '0' and c <= '9', eightDigits(std.mem.readInt(u64, &bytes, .little)));
        }
        bytes[i] = old;
    }
    var prng = std.Random.DefaultPrng.init(12345678);
    var buf: [8]u8 = undefined;
    for (0..10000) |_| {
        const n = prng.random().intRangeAtMost(u32, 0, 99999999);
        _ = try std.fmt.bufPrint(&buf, "{d:0>8}", .{n});
        const word = std.mem.readInt(u64, &buf, .little);
        try std.testing.expect(eightDigits(word));
        try std.testing.expectEqual(@as(u64, n), parseEightDigits(word));
    }
}

test "Unicode encoding boundaries and randomized scalar values" {
    var prng = std.Random.DefaultPrng.init(0x554e49434f4445);
    const boundaries = [_]u21{ 0, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff };
    for (0..10010) |i| {
        const cp = if (i < boundaries.len) boundaries[i] else prng.random().intRangeAtMost(u21, 0, 0x10ffff);
        if (cp >= 0xd800 and cp <= 0xdfff) continue;
        var raw_buffer: [32]u8 = undefined;
        const raw = if (cp < 0x10000)
            try std.fmt.bufPrint(&raw_buffer, "\"\\u{x:0>4}\"", .{cp})
        else
            try std.fmt.bufPrint(&raw_buffer, "\"\\u{x:0>4}\\u{x:0>4}\"", .{ 0xd800 + ((cp - 0x10000) >> 10), 0xdc00 + ((cp - 0x10000) & 0x3ff) });
        var doc = try Document.parse(std.testing.allocator, raw, .{}, null);
        defer doc.deinit();
        var expected: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &expected);
        try std.testing.expectEqualStrings(expected[0..len], doc.string(doc.nodes.items[0]));
    }
}

test "conservative reservation and number diagnostics" {
    for ([_][]const u8{ "[0,0,0,0,0]", "[{},[],[[]],{\"\":{}}]", "{\"[,:{\":\"[,:{\",\"x\":1}", "\"[,]{}:\"" }) |raw| {
        var doc = try Document.parse(std.testing.allocator, raw, .{}, null);
        defer doc.deinit();
        try std.testing.expect(doc.nodes.items.len <= nodeCapacityBound(raw));
        try std.testing.expectEqual(doc.storage.len, doc.capacityBytes());
    }
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.InvalidJson, Document.parse(std.testing.allocator, "1e+", .{}, &diagnostic));
    try std.testing.expectEqual(@as(usize, 3), diagnostic.offset);
}
