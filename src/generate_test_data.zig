const std = @import("std");

const record_count = 100_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <srf-compact|srf-long|jsonl|json> [record_count]\n", .{args[0]});
        std.process.exit(1);
    }

    const format = args[1];
    const count = if (args.len >= 3)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        record_count;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, format, "srf-compact")) {
        try stdout.writeAll("#!srfv1\n");
        for (0..count) |i| {
            try stdout.print("id:num:{d},name::User {d},email::user{d}@example.com,active:bool:true,score:num:{d}.5,bio:49:A \"complex\" string with\nnewlines and \\backslashes,status::active\n", .{ i, i, i, i });
        }
    } else if (std.mem.eql(u8, format, "srf-long")) {
        try stdout.writeAll("#!srfv1\n#!long\n");
        for (0..count) |i| {
            try stdout.print("id:num:{d}\n", .{i});
            try stdout.print("name::User {d}\n", .{i});
            try stdout.print("email::user{d}@example.com\n", .{i});
            try stdout.writeAll("active:bool:true\n");
            try stdout.print("score:num:{d}.5\n", .{i});
            try stdout.writeAll("bio:49:A \"complex\" string with\nnewlines and \\backslashes\n");
            try stdout.writeAll("status::active\n\n");
        }
    } else if (std.mem.eql(u8, format, "jsonl")) {
        for (0..count) |i| {
            try stdout.print("{{\"id\":{d},\"name\":\"User {d}\",\"email\":\"user{d}@example.com\",\"active\":true,\"score\":{d}.5,\"bio\":\"A \\\"complex\\\" string with\\nnewlines and \\\\backslashes\",\"status\":\"active\"}}\n", .{ i, i, i, i });
        }
    } else if (std.mem.eql(u8, format, "json")) {
        try stdout.writeAll("[\n");
        for (0..count) |i| {
            if (i > 0) try stdout.writeAll(",\n");
            try stdout.print("{{\"id\":{d},\"name\":\"User {d}\",\"email\":\"user{d}@example.com\",\"active\":true,\"score\":{d}.5,\"bio\":\"A \\\"complex\\\" string with\\nnewlines and \\\\backslashes\",\"status\":\"active\"}}", .{ i, i, i, i });
        }
        try stdout.writeAll("\n]\n");
    } else {
        std.debug.print("Unknown format: {s}\n", .{format});
        std.process.exit(1);
    }

    try stdout.flush();
}
