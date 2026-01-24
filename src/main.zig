const std = @import("std");
const srf = @import("srf.zig");

const CountingAllocator = struct {
    child_allocator: std.mem.Allocator,
    alloc_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count += 1;
        self.bytes_allocated += len;
        if (self.alloc_count <= 25) {
            std.debug.print("Alloc #{}: {} bytes\n", .{ self.alloc_count, len });
        }
        return self.child_allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        return self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const base_allocator = gpa.allocator();

    const args = try std.process.argsAlloc(base_allocator);
    defer std.process.argsFree(base_allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <srf|json|jsonl>\n", .{args[0]});
        std.process.exit(1);
    }

    const format = args[1];

    const debug_allocs = std.process.hasEnvVarConstant("DEBUG_ALLOCATIONS");

    var counting = CountingAllocator{ .child_allocator = base_allocator };
    const allocator = if (debug_allocs) counting.allocator() else base_allocator;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    // Load all data into memory first for fair comparison
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(base_allocator);
    try stdin.appendRemaining(base_allocator, &data, @enumFromInt(100 * 1024 * 1024));

    if (std.mem.eql(u8, format, "srf")) {
        var reader = std.Io.Reader.fixed(data.items);
        const records = try srf.parse(&reader, allocator, .{ .alloc_strings = false });
        defer records.deinit();
    } else if (std.mem.eql(u8, format, "jsonl")) {
        var lines = std.mem.splitScalar(u8, data.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
        }
    } else if (std.mem.eql(u8, format, "json")) {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data.items, .{});
        defer parsed.deinit();
        var count: usize = 0;
        for (parsed.value.array.items) |item| {
            _ = item.object.get("id");
            _ = item.object.get("name");
            _ = item.object.get("email");
            _ = item.object.get("active");
            _ = item.object.get("score");
            _ = item.object.get("bio");
            _ = item.object.get("status");
            count += 1;
        }
        std.mem.doNotOptimizeAway(&count);
    } else {
        std.debug.print("Unknown format: {s}\n", .{format});
        std.process.exit(1);
    }

    if (debug_allocs) {
        std.debug.print("Allocations: {}\n", .{counting.alloc_count});
        std.debug.print("Frees: {}\n", .{counting.free_count});
        std.debug.print("Bytes allocated: {}\n", .{counting.bytes_allocated});
    }
}
