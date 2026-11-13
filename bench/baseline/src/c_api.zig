const std = @import("std");
const kiln = @import("root.zig");

export fn kiln_parse(data: [*]const u8, len: usize, error_offset: ?*usize) ?*kiln.Document {
    const allocator = std.heap.raw_c_allocator;
    var diagnostic = kiln.Diagnostic{};
    const doc = allocator.create(kiln.Document) catch return null;
    doc.* = kiln.Document.parse(allocator, data[0..len], .{}, &diagnostic) catch {
        allocator.destroy(doc);
        if (error_offset) |p| p.* = diagnostic.offset;
        return null;
    };
    return doc;
}
export fn kiln_free(doc: ?*kiln.Document) void {
    if (doc) |d| {
        d.deinit();
        std.heap.raw_c_allocator.destroy(d);
    }
}
export fn kiln_checksum(doc: *const kiln.Document) u64 {
    return doc.checksum();
}
export fn kiln_capacity(doc: *const kiln.Document) usize {
    return doc.capacityBytes() + @sizeOf(kiln.Document);
}
export fn kiln_nodes(doc: *const kiln.Document, len: *usize) [*]const kiln.Node {
    len.* = doc.nodes.items.len;
    return doc.nodes.items.ptr;
}
export fn kiln_strings(doc: *const kiln.Document, len: *usize) [*]const u8 {
    len.* = doc.strings.items.len;
    return doc.strings.items.ptr;
}

const MemoryStats = extern struct { live_bytes: usize, peak_bytes: usize, allocation_calls: usize };
const Counter = struct {
    live: usize = @sizeOf(kiln.Document),
    peak: usize = @sizeOf(kiln.Document),
    calls: usize = 1,
    fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn update(self: *Counter, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const p = std.heap.raw_c_allocator.rawAlloc(n, alignment, ra) orelse return null;
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.update(0, n);
        return p;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        if (!std.heap.raw_c_allocator.rawResize(memory, alignment, n, ra)) return false;
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.update(memory.len, n);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const p = std.heap.raw_c_allocator.rawRemap(memory, alignment, n, ra) orelse return null;
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.update(memory.len, n);
        return p;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        std.heap.raw_c_allocator.rawFree(memory, alignment, ra);
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.update(memory.len, 0);
    }
};
/// Instrumentation runs separately from timing. Counts requested bytes, not RSS.
export fn kiln_measure(data: [*]const u8, len: usize, result: *MemoryStats) bool {
    var counter = Counter{};
    var doc = kiln.Document.parse(counter.allocator(), data[0..len], .{}, null) catch return false;
    result.* = .{ .live_bytes = counter.live, .peak_bytes = counter.peak, .allocation_calls = counter.calls };
    doc.deinit();
    std.debug.assert(counter.live == @sizeOf(kiln.Document));
    return true;
}
