//! Runs hyperfine over the srf CLI, one command per test data file.
//!
//! Usage: benchmark <hyperfine> <srf-exe> <format> <file> [<format> <file>...]
//!
//! This exists because a build `Run` step can only put one path in each
//! argument, but every hyperfine command needs two (the srf executable and the
//! file redirected to its stdin).
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 5 or (args.len - 3) % 2 != 0) {
        std.debug.print("Usage: {s} <hyperfine> <srf-exe> <format> <file> [<format> <file>...]\n", .{args[0]});
        std.process.exit(1);
    }

    const hyperfine = args[1];
    const srf_exe = args[2];

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ hyperfine, "-w", "2" });

    var i: usize = 3;
    while (i < args.len) : (i += 2) {
        // hyperfine runs each command through a shell
        try argv.append(arena, try arena.print("{f} {s} <{f}", .{
            shellQuote(srf_exe),
            args[i],
            shellQuote(args[i + 1]),
        }));
    }

    var child = try std.process.spawn(init.io, .{ .argv = argv.items });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => {
            std.debug.print("hyperfine terminated abnormally: {any}\n", .{term});
            std.process.exit(1);
        },
    }
}

fn shellQuote(s: []const u8) std.fmt.Alt([]const u8, formatShellQuoted) {
    return .{ .data = s };
}

/// Single-quotes `s` for a POSIX shell, escaping embedded single quotes.
fn formatShellQuoted(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}
