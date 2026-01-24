//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const log = std.log.scoped(.srf);

pub const ParseLineError = struct {
    message: []const u8,
    level: std.log.Level,
    line: usize,
    column: usize,

    pub fn deinit(self: ParseLineError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};
pub const Diagnostics = struct {
    errors: *std.ArrayList(ParseLineError),
    stop_after: usize = 10,
    arena: std.heap.ArenaAllocator,

    pub fn addError(self: Diagnostics, allocator: std.mem.Allocator, err: ParseLineError) ParseError!void {
        if (self.errors.items.len >= self.stop_after) {
            err.deinit(allocator);
            return ParseError.ParseFailed;
        }
        try self.errors.append(allocator, err);
    }
    pub fn deinit(self: RecordList) void {
        // From parse, three things can happen:
        // 1. Happy path - record comes back, deallocation happens on that deinit
        // 2. Errors is returned, no diagnostics provided. Deallocation happens in parse on errdefer
        // 3. Errors are returned, diagnostics provided. Deallocation happens here
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        child_allocator.destroy(self.arena);
    }
};

pub const ParseError = error{
    ParseFailed,
    ReadFailed,
    StreamTooLong,
    OutOfMemory,
    EndOfStream,
};

const ItemValueWithMetaData = struct {
    item_value: ?ItemValue,
    error_parsing: bool = false,
    reader_advanced: bool = false,
};
pub const ItemValue = union(enum) {
    number: f64,

    /// Bytes are converted to/from base64, string is not
    bytes: []const u8,

    /// String is not touched in any way
    string: []const u8,

    boolean: bool,

    pub fn format(self: ItemValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .number => try writer.print("num: {d}", .{self.number}),
            .bytes => try writer.print("bytes: {x}", .{self.bytes}),
            .string => try writer.print("string: {s}", .{self.string}),
            .boolean => try writer.print("boolean: {}", .{self.boolean}),
        }
    }
    pub fn parse(allocator: std.mem.Allocator, str: []const u8, state: *ParseState, delimiter: u8, options: ParseOptions) ParseError!ItemValueWithMetaData {
        const type_val_sep_raw = std.mem.indexOfScalar(u8, str, ':');
        if (type_val_sep_raw == null) {
            try parseError(allocator, options, "no type data or value after key", state.*);
            return ParseError.ParseFailed;
        }

        const type_val_sep = type_val_sep_raw.?;
        const metadata = str[0..type_val_sep];
        const trimmed_meta = std.mem.trim(u8, metadata, &std.ascii.whitespace);
        if (trimmed_meta.len == 0 or std.mem.eql(u8, "string", trimmed_meta)) {
            // delimiter ended string
            var it = std.mem.splitScalar(u8, str[type_val_sep + 1 ..], delimiter);
            const val = it.first();
            // we need to advance the column/partial_line_column of our parsing state
            const total_chars = metadata.len + 1 + val.len;
            state.column += total_chars;
            state.partial_line_column += total_chars;
            return .{
                .item_value = .{ .string = try dupe(allocator, options, val) },
            };
        }
        if (std.mem.eql(u8, "binary", trimmed_meta)) {
            // binary is base64 encoded, so we need to decode it, but we don't
            // risk delimiter collision, so we don't need a length for this
            var it = std.mem.splitScalar(u8, str[type_val_sep + 1 ..], delimiter);
            const val = it.first();
            // we need to advance the column/partial_line_column of our parsing state
            const total_chars = metadata.len + 1 + val.len;
            state.column += total_chars;
            state.partial_line_column += total_chars;
            const Decoder = std.base64.standard.Decoder;
            const size = Decoder.calcSizeForSlice(val) catch {
                try parseError(allocator, options, "error parsing base64 value", state.*);
                return .{
                    .item_value = null,
                    .error_parsing = true,
                };
            };
            const data = try allocator.alloc(u8, size);
            errdefer allocator.free(data);
            Decoder.decode(data, val) catch {
                try parseError(allocator, options, "error parsing base64 value", state.*);
                allocator.free(data);
                return .{
                    .item_value = null,
                    .error_parsing = true,
                };
            };
            return .{
                .item_value = .{ .bytes = data },
            };
        }
        if (std.mem.eql(u8, "num", trimmed_meta)) {
            var it = std.mem.splitScalar(u8, str[type_val_sep + 1 ..], delimiter);
            const val = it.first();
            // we need to advance the column/partial_line_column of our parsing state
            const total_chars = metadata.len + 1 + val.len;
            log.debug("num total_chars: {d}", .{total_chars});
            state.column += total_chars;
            state.partial_line_column += total_chars;
            const val_trimmed = std.mem.trim(u8, val, &std.ascii.whitespace);
            const number = std.fmt.parseFloat(@FieldType(ItemValue, "number"), val_trimmed) catch {
                try parseError(allocator, options, "error parsing numeric value", state.*);
                return .{
                    .item_value = null,
                    .error_parsing = true,
                };
            };
            return .{
                .item_value = .{ .number = number },
            };
        }
        if (std.mem.eql(u8, "bool", trimmed_meta)) {
            var it = std.mem.splitScalar(u8, str[type_val_sep + 1 ..], delimiter);
            const val = it.first();
            // we need to advance the column/partial_line_column of our parsing state
            const total_chars = metadata.len + 1 + val.len;
            state.column += total_chars;
            state.partial_line_column += total_chars;
            const val_trimmed = std.mem.trim(u8, val, &std.ascii.whitespace);
            const boolean = blk: {
                if (std.mem.eql(u8, "false", val_trimmed)) break :blk false;
                if (std.mem.eql(u8, "true", val_trimmed)) break :blk true;

                try parseError(allocator, options, "error parsing boolean value", state.*);
                return .{
                    .item_value = null,
                    .error_parsing = true,
                };
            };
            return .{
                .item_value = .{ .boolean = boolean },
            };
        }
        if (std.mem.eql(u8, "null", trimmed_meta)) {
            // we need to advance the column/partial_line_column of our parsing state
            const total_chars = metadata.len + 1;
            state.column += total_chars;
            state.partial_line_column += total_chars;
            return .{
                .item_value = null,
            };
        }
        // Last chance...the thing between these colons is a usize indicating
        // the number of bytes to grab for a string. In case parseInt fails,
        // we need to advance the position of our column counters
        const total_metadata_chars = metadata.len + 1;
        state.column += total_metadata_chars;
        state.partial_line_column += total_metadata_chars;
        const size = std.fmt.parseInt(usize, trimmed_meta, 0) catch {
            log.debug("parseInt fail, trimmed_data: '{s}'", .{trimmed_meta});
            try parseError(allocator, options, "unrecognized metadata for key", state.*);
            return .{
                .item_value = null,
                .error_parsing = true,
            };
        };
        // Update again for number of bytes. All failures beyond this point are
        // fatal, so this is safe.
        state.column += size;
        state.partial_line_column += size;

        // If we are being asked specifically for bytes, we no longer care about
        // delimiters. We just want raw bytes. This might adjust our line/column
        // in the parse state
        const rest_of_data = str[type_val_sep + 1 ..];
        if (rest_of_data.len > size) {
            // We fit on this line, everything is "normal"
            const val = rest_of_data[0..size];
            return .{
                .item_value = .{ .string = val },
            };
        }
        // This is not enough, we need more data from the reader
        log.debug("item value includes newlines {f}", .{state});
        // We need to advance the reader, so we need a copy of what we have so fa
        const start = try dupe(allocator, options, rest_of_data);
        defer allocator.free(start);
        // We won't do a parseError here. If we have an allocation error, read
        // error, or end of stream, all of these are fatal. Our reader is currently
        // past the newline, so we have to remove a character from size to account.
        const end = try state.reader.readAlloc(allocator, size - rest_of_data.len - 1);
        // However, we want to be past the end of the *next* newline too (in long
        // format mode)
        if (delimiter == '\n') state.reader.toss(1);
        defer allocator.free(end);
        // This \n is because the reader state will have advanced beyond the next newline, so end
        // really should start with the newline. This only applies to long mode, because otherwise the
        // entire record is a single line
        const final = try std.mem.concat(allocator, u8, &.{ start, "\n", end });
        // const final = if (delimiter == '\n')
        //     try std.mem.concat(allocator, u8, &.{ start, "\n", end })
        // else
        //     try std.mem.concat(allocator, u8, &.{ start, end });
        errdefer allocator.free(final);
        // log.debug("full val: {s}", .{final});
        std.debug.assert(final.len == size);
        // Because we've now advanced the line, we need to reset everything
        state.line += std.mem.count(u8, final, "\n");
        state.column = final.len - std.mem.lastIndexOf(u8, final, "\n").?;
        state.partial_line_column = state.column;
        return .{
            .item_value = .{ .string = final },
            .reader_advanced = true,
        };
    }
};

// An item has a key and a value, but the value may be null
pub const Item = struct {
    key: []const u8,
    value: ?ItemValue,
};

// A record has a list of items, with no assumptions regarding duplication,
// etc. This is for parsing speed, but also for more flexibility in terms of
// use cases. One can make a defacto array out of this structure by having
// something like:
//
// arr:string:foo
// arr:string:bar
//
// and when you coerce to zig struct have an array .arr that gets populated
// with strings "foo" and "bar".
pub const Record = struct {
    items: []Item,
};

/// The RecordList is equivalent to Parsed(T) in std.json. Since most are
/// familiar with std.json, it differs in the following ways:
///
/// There is a list field instead of a value field. In json, one type of
/// value is an array. SRF does not have an array data type, but the set of
/// records is an array. json as a format is structred as a single object at
/// the outermost
///
/// This is not generic. In SRF, it is a separate function to bind the list
/// of records to a specific data type. This will add some (hopefully minimal)
/// overhead, but also avoid conflating parsing from the coercion from general
/// type to specifics, and avoids answering questions like "what if I have
/// 15 values for the same key" until you're actually dealing with that problem
/// (see std.json.ParseOptions duplicate_field_behavior and ignore_unknown_fields)
///
/// When implemented, there will include a pub fn bind(self: RecordList, comptime T: type, options, BindOptions) BindError![]T
/// function. The options will include things related to duplicate handling and
/// missing fields
pub const RecordList = struct {
    list: std.ArrayList(Record),
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: RecordList) void {
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        child_allocator.destroy(self.arena);
    }
    pub fn format(self: RecordList, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        _ = writer;
    }
};

pub const ParseOptions = struct {
    diagnostics: ?*Diagnostics = null,

    /// By default, the parser will copy data so it is safe to free the original
    /// This will impose about 8% overhead, but be safer. If you do not require
    /// this safety, set alloc_strings to false. Setting this to false is the
    /// equivalent of the "Leaky" parsing functions of std.json
    alloc_strings: bool = true,
};

const Directive = union(enum) {
    magic,
    long_format,
    compact_format,
    require_eof,
    eof,

    pub fn parse(allocator: std.mem.Allocator, str: []const u8, state: ParseState, options: ParseOptions) ParseError!?Directive {
        if (!std.mem.startsWith(u8, str, "#!")) return null;
        // strip any comments off
        var it = std.mem.splitScalar(u8, str[2..], '#');
        const line = std.mem.trimEnd(u8, it.first(), &std.ascii.whitespace);
        if (std.mem.eql(u8, "srfv1", line)) return .magic;
        if (std.mem.eql(u8, "requireeof", line)) return .require_eof;
        if (std.mem.eql(u8, "requireof", line)) {
            try parseError(allocator, options, "#!requireof found. Did you mean #!requireeof?", state);
            return null;
        }
        if (std.mem.eql(u8, "eof", line)) return .eof;
        if (std.mem.eql(u8, "compact", line)) return .compact_format;
        if (std.mem.eql(u8, "long", line)) return .long_format;
        return null;
    }
};
pub const ParseState = struct {
    reader: *std.Io.Reader,
    line: usize,
    column: usize,
    partial_line_column: usize,

    pub fn format(self: ParseState, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("line: {}, col: {}", .{ self.line, self.column });
    }
};
pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator, options: ParseOptions) ParseError!RecordList {
    // create an arena allocator for everytyhing related to parsing
    const arena: *std.heap.ArenaAllocator = try allocator.create(std.heap.ArenaAllocator);
    errdefer if (options.diagnostics == null) allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer if (options.diagnostics == null) arena.deinit();
    const aa = arena.allocator();
    var long_format = false; // Default to compact format
    var require_eof = false; // Default to no eof required
    var eof_found: bool = false;
    var state = ParseState{ .line = 0, .column = 0, .partial_line_column = 0, .reader = reader };
    const first_line = nextLine(reader, &state) orelse return ParseError.ParseFailed;

    if (try Directive.parse(aa, first_line, state, options)) |d| {
        if (d != .magic) try parseError(aa, options, "Magic header not found on first line", state);
    } else try parseError(aa, options, "Magic header not found on first line", state);

    // Loop through the header material and configure our main parsing
    var parsed: RecordList = .{
        .list = .empty,
        .arena = arena,
    };
    const first_data = blk: {
        while (nextLine(reader, &state)) |line| {
            if (try Directive.parse(aa, line, state, options)) |d| {
                switch (d) {
                    .magic => try parseError(aa, options, "Found a duplicate magic header", state),
                    .long_format => long_format = true,
                    .compact_format => long_format = false, // what if we have both?
                    .require_eof => require_eof = true,
                    .eof => {
                        // there needs to be an eof then
                        if (nextLine(reader, &state)) |_| {
                            try parseError(aa, options, "Data found after #!eof", state);
                            return ParseError.ParseFailed; // this is terminal
                        } else return parsed;
                    },
                }
            } else break :blk line;
        }
        return parsed;
    };

    // Main parsing. We already have the first line of data, which could
    // be a record (compact format) or a key/value pair (long format)
    var line: ?[]const u8 = first_data;
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |i| i.deinit(aa);
        items.deinit(aa);
    }

    // Because in long format we don't have newline delimiter, that should really be a noop
    // but we need this for compact format
    const delimiter: u8 = if (long_format) '\n' else ',';
    // log.debug("", .{});
    // log.debug("first line:{?s}", .{line});
    while (line) |l| {
        if (std.mem.trim(u8, l, &std.ascii.whitespace).len == 0) {
            // empty lines can be signficant (to indicate a new record, but only once
            // a record is processed, which requires data first. That record processing
            // is at the bottom of the loop, so if an empty line is detected here, we can
            // safely ignore it
            line = nextLine(reader, &state);
            continue;
        }
        if (try Directive.parse(aa, l, state, options)) |d| {
            switch (d) {
                .eof => {
                    // there needs to be an eof then
                    if (nextLine(reader, &state)) |_| {
                        try parseError(aa, options, "Data found after #!eof", state);
                        return ParseError.ParseFailed; // this is terminal
                    } else {
                        eof_found = true;
                        break;
                    }
                },
                else => try parseError(aa, options, "Directive found after data started", state),
            }
            continue;
        }

        // Real data: lfg
        // Whatever the format, the beginning will always be the key data
        // key:stuff:value
        var it = std.mem.splitScalar(u8, l, ':');
        const key = it.next().?; // first one we get for free
        if (key.len > 0) std.debug.assert(key[0] != delimiter);
        state.column += key.len + 1;
        state.partial_line_column += key.len + 1;
        const value = try ItemValue.parse(
            aa,
            it.rest(),
            &state,
            delimiter,
            options,
        );

        if (!value.error_parsing) {
            // std.debug.print("alloc on key: {s}, val: {?f}\n", .{ key, value.item_value });
            try items.append(aa, .{ .key = try aa.dupe(u8, key), .value = value.item_value });
        }

        if (value.reader_advanced and !long_format) {
            // In compact format we'll stay on the same line
            const real_column = state.column;
            line = nextLine(reader, &state);
            // Reset line and column position, because we're actually staying on the same line now
            state.line -= 1;
            state.column = real_column + 1;
            state.partial_line_column = 0;
        }

        // The difference between compact and line here is that compact we will instead of
        // line = try nextLine, we will do something like line = line[42..]
        if (long_format) {
            const maybe_line = nextLine(reader, &state);
            if (maybe_line == null) {
                // close out record, return
                try parsed.list.append(aa, .{
                    .items = try items.toOwnedSlice(aa),
                });
                break;
            }
            line = maybe_line.?;
            if (line.?.len == 0) {
                // End of record
                try parsed.list.append(aa, .{
                    .items = try items.toOwnedSlice(aa),
                });
                line = nextLine(reader, &state);
            }
        } else {
            // We should be on a delimiter, otherwise, we should be at the end
            line = line.?[state.partial_line_column..]; // can't use l here because line may have been reassigned
            state.partial_line_column = 0;
            if (line.?.len == 0) {
                // close out record
                try parsed.list.append(aa, .{
                    .items = try items.toOwnedSlice(aa),
                });
                line = nextLine(reader, &state);
                state.partial_line_column = 0;
            } else {
                if (line.?[0] != delimiter) {
                    log.err("reset line for next item, first char not '{c}':{?s}", .{ delimiter, line });
                    return error.ParseFailed;
                }
                line = line.?[1..];
            }
        }
    }
    // Parsing complete. Add final record to list. Then, if there are any parse errors, throw
    if (items.items.len > 0)
        try parsed.list.append(aa, .{
            .items = try items.toOwnedSlice(aa),
        });
    if (options.diagnostics) |d|
        if (d.errors.items.len > 0) return ParseError.ParseFailed;
    if (require_eof and !eof_found) return ParseError.ParseFailed;
    return parsed;
}

/// Takes the next line, trimming leading whitespace and ignoring comments
/// Directives (comments starting with #!) are preserved
fn nextLine(reader: *std.Io.Reader, state: *ParseState) ?[]const u8 {
    while (true) {
        state.line += 1;
        state.column = 1; // column is human indexed (one-based)
        state.partial_line_column = 0; // partial_line_column is zero indexed for computers
        const raw_line = (reader.takeDelimiter('\n') catch return null) orelse return null;
        // we don't want to trim the end, as there might be a key/value field
        // with a string including important trailing whitespace
        const trimmed_line = std.mem.trimStart(u8, raw_line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed_line, "#") and !std.mem.startsWith(u8, trimmed_line, "#!")) continue;
        return trimmed_line;
    }
}

inline fn dupe(allocator: std.mem.Allocator, options: ParseOptions, data: []const u8) ParseError![]const u8 {
    if (options.alloc_strings)
        return try allocator.dupe(u8, data);
    return data;
}
inline fn parseError(allocator: std.mem.Allocator, options: ParseOptions, message: []const u8, state: ParseState) ParseError!void {
    log.debug("Parse error. Parse state {f}, message: {s}", .{ state, message });
    if (options.diagnostics) |d| {
        try d.addError(allocator, .{
            .message = try dupe(allocator, options, message),
            .level = .err,
            .line = state.line,
            .column = state.column,
        });
    } else {
        return ParseError.ParseFailed;
    }
}

test "long format single record, no eof" {
    const data =
        \\#!srfv1 # mandatory comment with format and version. Parser instructions start with #!
        \\#!long # Mandatory to use multiline records, compact format is optional #!compact
        \\# A comment
        \\# empty lines ignored
        \\
        \\key::string value, with any data except a \n. an optional string length between the colons
    ;

    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    const records = try parse(&reader, allocator, .{});
    defer records.deinit();
    try std.testing.expectEqual(@as(usize, 1), records.list.items.len);
    try std.testing.expectEqual(@as(usize, 1), records.list.items[0].items.len);
    const kvps = records.list.items[0].items;
    try std.testing.expectEqualStrings("key", kvps[0].key);
    try std.testing.expectEqualStrings("string value, with any data except a \\n. an optional string length between the colons", kvps[0].value.?.string);
}
test "long format from README - generic data structures, first record only" {
    const data =
        \\#!srfv1 # mandatory comment with format and version. Parser instructions start with #!
        \\#!requireeof # Set this if you want parsing to fail when #!eof not present on last line
        \\#!long # Mandatory to use multiline records, compact format is optional #!compact
        \\# A comment
        \\# empty lines ignored
        \\
        \\this is a number:num: 5 
        \\#!eof
    ;

    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    const records = try parse(&reader, allocator, .{});
    defer records.deinit();
    try std.testing.expectEqual(@as(usize, 1), records.list.items.len);
}

test "long format from README - generic data structures" {
    const data =
        \\#!srfv1 # mandatory comment with format and version. Parser instructions start with #!
        \\#!requireeof # Set this if you want parsing to fail when #!eof not present on last line
        \\#!long # Mandatory to use multiline records, compact format is optional #!compact
        \\# A comment
        \\# empty lines ignored
        \\
        \\key::string value, with any data except a \n. an optional string length between the colons
        \\this is a number:num: 5 
        \\null value:null:
        \\array::array's don't exist. Use json or toml or something
        \\data with newlines must have a length:7:foo
        \\bar
        \\boolean value:bool:false
        \\  # Empty line separates records
        \\
        \\key::this is the second record
        \\this is a number:num:42 
        \\null value:null:
        \\array::array's still don't exist
        \\data with newlines must have a length::single line
        \\#!eof # eof marker, useful to make sure your file wasn't cut in half. Only considered if requireeof set at top
    ;

    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    const records = try parse(&reader, allocator, .{});
    defer records.deinit();
    try std.testing.expectEqual(@as(usize, 2), records.list.items.len);
    const first = records.list.items[0];
    try std.testing.expectEqual(@as(usize, 6), first.items.len);
    try std.testing.expectEqualStrings("key", first.items[0].key);
    try std.testing.expectEqualStrings("string value, with any data except a \\n. an optional string length between the colons", first.items[0].value.?.string);
    try std.testing.expectEqualStrings("this is a number", first.items[1].key);
    try std.testing.expectEqual(@as(f64, 5), first.items[1].value.?.number);
    try std.testing.expectEqualStrings("null value", first.items[2].key);
    try std.testing.expect(first.items[2].value == null);
    try std.testing.expectEqualStrings("array", first.items[3].key);
    try std.testing.expectEqualStrings("array's don't exist. Use json or toml or something", first.items[3].value.?.string);
    try std.testing.expectEqualStrings("data with newlines must have a length", first.items[4].key);
    try std.testing.expectEqualStrings("foo\nbar", first.items[4].value.?.string);
    try std.testing.expectEqualStrings("boolean value", first.items[5].key);
    try std.testing.expect(!first.items[5].value.?.boolean);

    const second = records.list.items[1];
    try std.testing.expectEqual(@as(usize, 5), second.items.len);
    try std.testing.expectEqualStrings("key", second.items[0].key);
    try std.testing.expectEqualStrings("this is the second record", second.items[0].value.?.string);
    try std.testing.expectEqualStrings("this is a number", second.items[1].key);
    try std.testing.expectEqual(@as(f64, 42), second.items[1].value.?.number);
    try std.testing.expectEqualStrings("null value", second.items[2].key);
    try std.testing.expect(second.items[2].value == null);
    try std.testing.expectEqualStrings("array", second.items[3].key);
    try std.testing.expectEqualStrings("array's still don't exist", second.items[3].value.?.string);
    try std.testing.expectEqualStrings("data with newlines must have a length", second.items[4].key);
    try std.testing.expectEqualStrings("single line", second.items[4].value.?.string);
}

test "compact format from README - generic data structures" {
    const data =
        \\#!srfv1 # mandatory comment with format and version. Parser instructions start with #!
        \\key::string value must have a length between colons or end with a comma,this is a number:num:5 ,null value:null:,array::array's don't exist. Use json or toml or something,data with newlines must have a length:7:foo
        \\bar,boolean value:bool:false
        \\key::this is the second record
    ;

    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    // We want "parse" and "parseLeaky" probably. Second parameter is a diagnostics
    const records = try parse(&reader, allocator, .{});
    defer records.deinit();
    try std.testing.expectEqual(@as(usize, 2), records.list.items.len);
    const first = records.list.items[0];
    try std.testing.expectEqual(@as(usize, 6), first.items.len);
    try std.testing.expectEqualStrings("key", first.items[0].key);
    try std.testing.expectEqualStrings("string value must have a length between colons or end with a comma", first.items[0].value.?.string);
    try std.testing.expectEqualStrings("this is a number", first.items[1].key);
    try std.testing.expectEqual(@as(f64, 5), first.items[1].value.?.number);
    try std.testing.expectEqualStrings("null value", first.items[2].key);
    try std.testing.expect(first.items[2].value == null);
    try std.testing.expectEqualStrings("array", first.items[3].key);
    try std.testing.expectEqualStrings("array's don't exist. Use json or toml or something", first.items[3].value.?.string);
    try std.testing.expectEqualStrings("data with newlines must have a length", first.items[4].key);
    try std.testing.expectEqualStrings("foo\nbar", first.items[4].value.?.string);
    try std.testing.expectEqualStrings("boolean value", first.items[5].key);
    try std.testing.expect(!first.items[5].value.?.boolean);

    const second = records.list.items[1];
    try std.testing.expectEqual(@as(usize, 1), second.items.len);
    try std.testing.expectEqualStrings("key", second.items[0].key);
    try std.testing.expectEqualStrings("this is the second record", second.items[0].value.?.string);
}
