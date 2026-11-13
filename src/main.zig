const std = @import("std");
const kiln = @import("kiln");
fn write(text: []const u8) !void {
    var remaining = text;
    while (remaining.len != 0) {
        const n = try std.posix.write(std.posix.STDOUT_FILENO, remaining);
        remaining = remaining[n..];
    }
}
fn run() !void {
    const allocator = std.heap.raw_c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2 or args.len > 3) {
        try write("Usage: kiln FILE.json [ROOT_OBJECT_KEY]\n");
        return;
    }
    const input = try std.fs.cwd().readFileAlloc(allocator, args[1], std.math.maxInt(u32));
    defer allocator.free(input);
    var diagnostic = kiln.Diagnostic{};
    var doc = kiln.Document.parse(allocator, input, .{}, &diagnostic) catch |err| {
        std.debug.print("{s} at byte {d}\n", .{ @errorName(err), diagnostic.offset });
        std.process.exit(1);
    };
    defer doc.deinit();
    var buffer: [512]u8 = undefined;
    try write(try std.fmt.bufPrint(&buffer, "Parsed {d} bytes: {d} nodes, {d} decoded string bytes, {d} bytes reserved\nChecksum: {x:0>16}\n", .{ input.len, doc.nodes.items.len, doc.strings.items.len, doc.capacityBytes(), doc.checksum() }));
    if (args.len == 3) {
        if (doc.get(0, args[2])) |index| {
            const node = doc.nodes.items[index];
            switch (node.tag) {
                .string => {
                    try write(doc.string(node));
                    try write("\n");
                },
                .number => try write(try std.fmt.bufPrint(&buffer, "{d}\n", .{node.number()})),
                .null_value => try write("null\n"),
                .false_value => try write("false\n"),
                .true_value => try write("true\n"),
                .array, .object => try write(try std.fmt.bufPrint(&buffer, "{s} with {d} entries\n", .{ @tagName(node.tag), node.len() })),
            }
        } else {
            try write("Key not found (or root is not an object)\n");
            std.process.exit(2);
        }
    }
}
pub fn main() void {
    run() catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
