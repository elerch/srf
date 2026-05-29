//!SRF is a minimal data format designed for L2 caches and simple structured storage suitable for simple configuration as well. It provides human-readable key-value records with basic type hints, while avoiding the parsing complexity and escaping requirements of JSON. Current benchmarking with hyperfine demonstrate approximately twice the performance of JSON parsing, though for L2 caches, JSON may be a poor choice. Compared to jsonl, it is approximately 40x faster. Performance also improves by 8% if you instruct the library not to copy strings around (ParseOptions alloc_strings = false).
//!
//!**Features:**
//!- No escaping required - use length-prefixed strings for complex data
//!- Single-pass parsing with minimal memory allocation
//!- Basic type system (string, num, bool, null, binary) with explicit type hints
//!- Compact format for machine generation, long format for human editing
//!- Built-in corruption detection with optional EOF markers
//!
//!**When to use SRF:**
//!- L2 caches that need occasional human inspection
//!- Simple configuration files with mixed data types
//!- Data exchange where JSON escaping is problematic
//!- Applications requiring fast, predictable parsing
//!
//!**When not to use SRF:**
//!- Complex nested data structures (use JSON/TOML instead)
//!- Schema validation requirements
//!- Arrays or object hierarchies (arrays can be managed in the data itself, however)
const std = @import("std");

const log = std.log.scoped(.srf);

pub const ParseLineError = struct {
    message: []const u8,
    level: std.log.Level,
    line: usize,
    column: usize,
};
pub const Diagnostics = struct {
    ptr: *anyopaque,
    addErrorFn: *const fn (*anyopaque, ParseLineError) ParseError!void,
    has_errors: bool = false,

    pub fn addError(self: *Diagnostics, err: ParseLineError) ParseError!void {
        try self.addErrorFn(self.ptr, err);
        self.has_errors = true;
    }
};
pub fn BoundedDiagnostics(comptime max_errors: usize) type {
    return struct {
        buffer: [max_errors]ParseLineError,
        /// backing buffer for message data. We provide 256 bytes for each message,
        /// which should be fine, and if it's not, we need to fix the code
        msg_buffer: [max_errors * 256]u8,
        fba: std.heap.FixedBufferAllocator,
        allocator: std.mem.Allocator,
        capacity: usize = max_errors,
        error_count: usize = 0,

        const Self = @This();

        pub const empty: Self = .{
            // SAFETY: buffer is managed through addError below
            .buffer = undefined,
            // SAFETY: msg_buffer is managed through the FixedBufferAllocator
            .msg_buffer = undefined,
            // SAFETY: fba is established on first use of addError
            .fba = undefined,
            // SAFETY: allocator is established on first use of addError
            .allocator = undefined,
        };

        pub fn diagnostics(self: *Self) Diagnostics {
            return .{
                .ptr = self,
                .addErrorFn = addDiagnosticsError,
            };
        }
        fn addDiagnosticsError(ptr: *anyopaque, err: ParseLineError) ParseError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.addError(err);
        }
        pub fn addError(self: *Self, err: ParseLineError) ParseError!void {
            if (self.error_count == 0) {
                self.fba = std.heap.FixedBufferAllocator.init(&self.msg_buffer);
                self.allocator = self.fba.allocator();
            }

            if (self.error_count >= self.capacity) {
                return ParseError.ParseFailed;
            }
            self.buffer[self.error_count] = err;
            self.buffer[self.error_count].message = try self.allocator.dupe(u8, err.message);
            self.error_count += 1;
        }
        pub fn errors(self: Self) []const ParseLineError {
            return self.buffer[0..self.error_count];
        }
    };
}

pub const ParseError = error{
    ParseFailed,
    ReadFailed,
    StreamTooLong,
    OutOfMemory,
    AllocationRequired,
    EndOfStream,
};

const ValueWithMetaData = struct {
    item_value: ?Value,
    error_parsing: bool = false,
    reader_advanced: bool = false,
};
/// A parsed SRF value. Each field in a record has a key and an optional `Value`.
pub const Value = union(enum) {
    /// A numeric value, parsed from the `num` type hint.
    number: f64,

    /// Raw bytes decoded from base64, parsed from the `binary` type hint.
    bytes: []const u8,

    /// A string value, either delimiter-terminated or length-prefixed.
    /// Not transformed during parsing (no escaping/unescaping), but will be
    /// allocated if .alloc_strings = true is passed during parsing, or if
    /// a multi-line string is found in the data
    string: []const u8,

    /// A boolean value, parsed from the `bool` type hint (`true` or `false`).
    boolean: bool,

    /// parses a single srf value, without the key. The the whole field is:
    ///
    /// SRF Field: 'foo:3:bar'
    ///
    /// The value we expect to be sent to this function is:
    ///
    /// SRF Value: '3:bar'
    ///
    /// The value is allowed to have extra data...for instance, in compact format
    /// the value above can be represented by:
    ///
    /// SRF Value: '3:bar,next_field::foobar'
    ///
    /// and the next field will be ignored
    ///
    /// This function may need to advance the reader in the case of multi-line
    /// strings. It may also allocate data in the case of base64 (binary) values
    /// as well as multi-line strings. Metadata is returned to assist in tracking
    ///
    /// This function is intended to be used by the SRF parser
    pub fn parse(str: []const u8, state: *RecordIterator.State, delimiter: u8) ParseError!ValueWithMetaData {
        const type_val_sep_raw = std.mem.indexOfScalar(u8, str, ':');
        if (type_val_sep_raw == null) {
            try parseError("no type data or value after key", state);
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
                .item_value = .{ .string = try dupe(
                    state.*,
                    val,
                    .value,
                ) },
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
                try parseError("error parsing base64 value", state);
                return .{
                    .item_value = null,
                    .error_parsing = true,
                };
            };
            const alloc = findAllocator(state.*, .value) orelse
                try fallbackAllocatorFor(state);
            const data = try alloc.alloc(u8, size);
            errdefer alloc.free(data);
            Decoder.decode(data, val) catch {
                try parseError("error parsing base64 value", state);
                alloc.free(data);
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
            // log.debug("num total_chars: {d}", .{total_chars});
            state.column += total_chars;
            state.partial_line_column += total_chars;
            const val_trimmed = std.mem.trim(u8, val, &std.ascii.whitespace);
            const number = (if (state.options.strict_number_parsing)
                std.fmt.parseFloat(@FieldType(Value, "number"), val_trimmed)
            else
                parseFloat(@FieldType(Value, "number"), val_trimmed)) catch {
                try parseError("error parsing numeric value", state);
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

                try parseError("error parsing boolean value", state);
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
            try parseError("unrecognized metadata for key", state);
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
        if (rest_of_data.len >= size) {
            // We fit on this line, everything is "normal"
            const val = rest_of_data[0..size];
            return .{
                .item_value = .{ .string = try dupe(
                    state.*,
                    val,
                    .value,
                ) },
            };
        }
        // This is not enough, we need more data from the reader
        const alloc = findAllocator(state.*, .value) orelse
            try fallbackAllocatorFor(state);
        const buf = try alloc.alloc(u8, size);
        errdefer alloc.free(buf);
        @memcpy(buf[0..rest_of_data.len], rest_of_data);
        // add back the newline we are skipping
        buf[rest_of_data.len] = '\n';
        // We won't do a parseError here. If we have an allocation error, read
        // error, or end of stream, all of these are fatal. Our reader is currently
        // past the newline, so we have to remove a character from size to account.
        try state.reader.readSliceAll(buf[rest_of_data.len + 1 ..]);
        // However, we want to be past the end of the *next* newline too (in long
        // format mode)
        if (delimiter == '\n') state.reader.toss(1);
        // Because we've now advanced the line, we need to reset everything
        state.line += std.mem.count(u8, buf, "\n");
        state.column = buf.len - std.mem.lastIndexOf(u8, buf, "\n").?;
        state.partial_line_column = state.column;
        return .{
            .item_value = .{ .string = buf },
            .reader_advanced = true,
        };
    }
    inline fn fallbackAllocatorFor(state: *RecordIterator.State) !std.mem.Allocator {
        if (state.fallback_arena) |f| return f.allocator();
        if (state.options.parse_allocator == .none) return error.AllocationRequired;
        state.fallback_arena = try state.allocator.create(std.heap.ArenaAllocator);
        state.fallback_arena.?.* = .init(state.allocator);
        return state.fallback_arena.?.allocator();
    }
};

fn parseFloat(comptime T: type, value: []const u8) !T {
    if (std.fmt.parseFloat(T, value)) |f| {
        // clean parse
        return f;
    } else |_| {} // error

    if (@typeInfo(T) != .float) {
        @compileError("Cannot parse a float into a non-floating point type.");
    }
    // Need a temporary buffer. The maximum number of characters in our float
    // can be calculated. This is apparently out of all the text from
    // https://dl.acm.org/doi/epdf/10.1145/93542.93557
    // and
    // https://dl.acm.org/doi/epdf/10.1145/93548.93559
    // and boils down to:
    // 1 + ceil(p * log10(2))
    //
    // This is a little relevant here because we don't know the exact type,
    // even though it's almost certainly f64 (look at the Value struct)
    const buf_len: usize = 1 + @trunc(std.math.ceil(@as(f64, @typeInfo(T).float.bits) * @log10(@as(f64, 2))));
    var buffer: [buf_len]u8 = undefined;
    var val_inx: usize = 0;
    var buf_inx: usize = 0;
    var state: enum { start, middle, end } = .start;

    // We need to "clean up" the input here
    while (val_inx < value.len) {
        const c = value[val_inx];
        switch (state) {
            .start => {
                if (isNumberIsh(c, false)) {
                    state = .middle;
                    // we don't increment val_inx here because we need to add to the buffer...
                    continue;
                }
                // We need to have at least one more character in the string
                if (val_inx + 1 >= value.len) return error.InvalidCharacter;

                if (leadingCurrency(value[val_inx..])) |curr| {
                    val_inx += curr.len;
                    while (val_inx < value.len and value[val_inx] == ' ') val_inx += 1;
                    state = .middle;
                    continue;
                }
                return error.InvalidCharacter;
            },
            .middle => {
                if (!isNumberIsh(c, true)) {
                    val_inx += 1;
                    state = .end;
                    continue;
                }
                // add to our buffer if it's not a comma. We aren't dealing
                // with comma/period locale semantics
                if (c == ',') {
                    val_inx += 1;
                    continue;
                }
                buffer[buf_inx] = c;
                buf_inx += 1;
                val_inx += 1;
            },
            .end => {
                if (value[val_inx] == ' ' and val_inx < value.len + 1) {
                    // we don't allow trailing spaces
                    val_inx += 1;
                    continue;
                }
                if (leadingCurrency(value[val_inx..])) |curr| {
                    // we are ok to end with a currency, but nothing else
                    if (val_inx + curr.len == value.len) break;
                }
                return error.InvalidCharacter;
            },
        }
    }
    return std.fmt.parseFloat(T, buffer[0..buf_inx]);
}
fn isNumberIsh(ch: u8, in_middle: bool) bool {
    if (ch >= '0' and ch <= '9')
        return true;
    if (ch == '-' or ch == '+')
        return true;
    if (in_middle and (ch == '.' or ch == ','))
        return true; // we will allow . and , and allow ordering to the caller
    return false;
}
fn leadingCurrency(s: []const u8) ?[]const u8 {
    // Check known single character currency symbols
    const single_byte_currencies = "$KLPQR";
    for (single_byte_currencies) |curr|
        if (s[0] == curr)
            return s[0..1];
    const two_byte_currencies = "£¤¥֏";
    var i: usize = 0;
    while (i < two_byte_currencies.len - 1) : (i += 2) {
        if (two_byte_currencies[i] == s[0] and
            two_byte_currencies[i + 1] == s[1])
            return s[0..2];
    }
    const three_byte_currencies = "৳฿៛₡₦₧₩₪₫€₭₮₱₲₴₸₹₺₼₽₾⃀";
    i = 0;
    while (i < three_byte_currencies.len - 2) : (i += 3) {
        if (three_byte_currencies[i] == s[0] and
            three_byte_currencies[i + 1] == s[1] and
            three_byte_currencies[i + 2] == s[2])
            return s[0..3];
    }
    return null;
}

/// A single key-value pair within a record. The key is always a string.
/// The value may be `null` (from the `null` type hint) or one of the
/// `Value` variants. Yielded by `RecordIterator.FieldIterator.next`.
pub const Field = struct {
    key: []const u8,
    value: ?Value,
};

/// Options for type coercion
pub const CoercionOptions = struct {
    /// Coerce strings to numbers. This is false for the same reason
    /// that lienient number conversion ParseOptions is off by default.
    /// This library is intended for performant access for cache use cases.
    /// It happens to be a relatively simple format for humans to grok,
    /// so if you want to use this for human-edited files, turn this on
    strings_to_numbers: bool = false,
};

pub fn CoercionResult(T: type) type {
    return struct {
        value: T,

        /// Set this to true if the original value has been consumed and
        /// is no longer needed. For example the string "89" coerced to int
        /// should be freed by the caller
        require_free_original: bool = false,

        const Self = @This();
        /// Returns a normal struct - no free required
        pub fn init(value: T) Self {
            return .{ .value = value };
        }
        /// Returns a struct requiring the caller to free original memory
        pub fn initFree(value: T) Self {
            return .{ .value = value, .require_free_original = true };
        }
    };
}

fn coerce(name: []const u8, comptime T: type, val: ?Value, options: CoercionOptions) !CoercionResult(T) {
    const ti = @typeInfo(T);
    if (val == null and ti != .optional)
        return error.NullValueCannotBeAssignedToNonNullField;

    // []const u8 is classified as a pointer
    switch (ti) {
        .optional => |o| if (val) |_| {
            const child = try coerce(name, o.child, val, options);
            return .{ .value = child.value, .require_free_original = child.require_free_original };
        } else return .{ .value = null },
        .pointer => |p| {
            // We don't have an allocator, so the only thing we can do
            // here is manage []const u8 or []u8
            if (p.size != .slice or p.child != u8)
                return error.CoercionNotPossible;
            if (val.? != .string and val.? != .bytes)
                return error.CoercionNotPossible;
            if (val.? == .string)
                return .init(val.?.string);
            return .init(val.?.bytes);
        },
        .type, .void, .noreturn => return error.CoercionNotPossible,
        .comptime_float, .comptime_int, .undefined, .null, .error_union => return error.CoercionNotPossible,
        .error_set, .@"fn", .@"opaque", .frame => return error.CoercionNotPossible,
        .@"anyframe", .vector, .enum_literal => return error.CoercionNotPossible,
        .int => {
            if (options.strings_to_numbers and val.? == .string) {
                // At this point, we're in lienent mode, so we'll do our lienient
                // parse, then truncate it to the int the user wants
                const float = try parseFloat(f64, val.?.string);
                return .initFree(@as(T, @trunc(float)));
            }
            return .init(@as(T, @intFromFloat(val.?.number)));
        },
        .float => {
            if (options.strings_to_numbers and val.? == .string) {
                return .initFree(try parseFloat(T, val.?.string));
            }
            return .init(@as(T, @floatCast(val.?.number)));
        },
        .bool => return switch (val.?) {
            .boolean => |b| .init(b),
            .string => |s| if (std.mem.eql(u8, "true", s))
                .initFree(true)
            else if (std.mem.eql(u8, "false", s))
                .initFree(false)
            else
                return error.StringValueOfBooleanMustBetrueOrfalse,
            else => return error.BooleanNotBooleanOrString,
        },
        .@"enum" => return .initFree(std.meta.stringToEnum(T, val.?.string).?),
        .array => return error.NotImplemented,
        .@"struct", .@"union" => {
            if (std.meta.hasMethod(T, "srfParse")) {
                if (val.? == .string)
                    return T.srfParse(val.?.string) catch |e| {
                        log.err(
                            "custom parse of value {s} failed : {}",
                            .{ val.?.string, e },
                        );
                        return error.CustomParseFailed;
                    };
            }
            return error.CoercionNotPossible;
        },
    }
    return null;
}

/// A streaming record iterator for parsing SRF data. This is the preferred
/// parsing API because it avoids collecting all records and fields into memory
/// at once. Created by calling `iterator`.
///
/// Each call to `next` yields a `FieldIterator` for one record. Fields within
/// that record are consumed lazily via `FieldIterator.next` or coerced directly
/// into a Zig type via `FieldIterator.to`. All allocations go through an
/// internal arena; call `deinit` to release everything when done.
///
/// If `RecordIterator.next` is called before the previous `FieldIterator` has
/// been fully consumed, the remaining fields are automatically drained to keep
/// the parser state consistent.
pub const RecordIterator = struct {
    arena: *std.heap.ArenaAllocator,
    /// optional expiry time for the data. Useful for caching
    /// Note that on a parse, data will always be returned and it will be up
    /// to the caller to check is_fresh and determine the right thing to do
    expires: ?i64,

    /// optional created time for the data. This library does nothing with
    /// this data, but will be tracked and available immediately after calling
    /// `iterator` if needed/provided
    created: ?i64,

    /// optional modified time for the data. This library does nothing with
    /// this data, but will be tracked and available immediately after calling
    /// `iterator` if needed/provided
    modified: ?i64,

    state: *State,

    pub const State = struct {
        line: usize = 0,
        column: usize = 0,
        partial_line_column: usize = 0,
        reader: *std.Io.Reader,
        options: ParseOptions,

        require_eof: bool = false,
        eof_found: bool = false,
        current_line: ?[]const u8,

        field_delimiter: u8 = ',',
        end_of_record_reached: bool = false,
        field_iterator: ?FieldIterator = null,

        aa: std.mem.Allocator,
        allocator: std.mem.Allocator,
        fallback_arena: ?*std.heap.ArenaAllocator = null,

        /// Takes the next line, trimming leading whitespace and ignoring comments
        /// Directives (comments starting with #!) are preserved
        pub fn nextLine(state: *State) ?[]const u8 {
            while (true) {
                state.line += 1;
                state.column = 1; // column is human indexed (one-based)
                state.partial_line_column = 0; // partial_line_column is zero indexed for computers
                const raw_line = (state.reader.takeDelimiter('\n') catch return null) orelse return null;
                // we don't want to trim the end, as there might be a key/value field
                // with a string including important trailing whitespace
                const trimmed_line = std.mem.trimStart(u8, raw_line, &std.ascii.whitespace);
                if (std.mem.startsWith(u8, trimmed_line, "#") and !std.mem.startsWith(u8, trimmed_line, "#!")) continue;
                return trimmed_line;
            }
        }
        pub fn format(self: State, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("line: {}, col: {}", .{ self.line, self.column });
        }
    };

    /// Advances to the next record in the stream, returning a `FieldIterator`
    /// for accessing its fields. Returns `null` when all records have been
    /// consumed.
    ///
    /// If the previous `FieldIterator` was not fully drained, its remaining
    /// fields are consumed automatically to keep the reader positioned
    /// correctly. It is safe (but unnecessary) to fully consume the
    /// `FieldIterator` before calling `next` again.
    ///
    /// Note that all state is stored in a shared area accessible to both
    /// the `RecordIterator` and the `FieldIterator`, so there is no need to
    /// store the return value as a variable
    pub fn next(self: RecordIterator) !?FieldIterator {
        const state = self.state;
        if (state.field_iterator) |f| {
            // We need to finish the fields on the previous record
            while (try f.next()) |_| {}
            state.field_iterator = null;
        }
        if (state.current_line == null) {
            if (state.options.diagnostics) |d|
                if (d.has_errors) return ParseError.ParseFailed;
            if (state.require_eof and !state.eof_found) return ParseError.ParseFailed;
            return null;
        }
        while (std.mem.trim(u8, state.current_line.?, &std.ascii.whitespace).len == 0) {
            // empty lines can be signficant (to indicate a new record, but only once
            // a record is processed, which requires data first. That record processing
            // is at the bottom of the loop, so if an empty line is detected here, we can
            // safely ignore it
            state.current_line = state.nextLine();
            // by calling recursively we get the error handling above
            if (state.current_line == null) return self.next();
        }
        // non-blank line, but we could have an eof marker
        if (try Directive.parse(state.current_line.?, state)) |d| {
            switch (d) {
                .eof => {
                    // there needs to be an eof then
                    if (state.nextLine()) |_| {
                        try parseError("Data found after #!eof", state);
                        return ParseError.ParseFailed; // this is terminal
                    } else {
                        state.eof_found = true;
                        state.current_line = null;
                        return null; // all is good, we're done
                    }
                },
                else => {
                    try parseError("Directive found after data started", state);
                    state.current_line = state.nextLine();
                    // TODO: This runs the risk of a malicious file creating
                    // a stackoverflow by using many non-eof directives
                    return self.next();
                },
            }
        }
        state.end_of_record_reached = false;
        state.field_iterator = .{
            .state = self.state,
            .arena = self.arena,
        };
        return state.field_iterator.?;
    }

    /// Iterates over the fields within a single record. Yielded by
    /// `RecordIterator.next`. Each call to `next` returns the next `Field`
    /// in the record, or `null` when the record boundary is reached.
    ///
    /// For direct type coercion without manually iterating fields, use `to`.
    pub const FieldIterator = struct {
        state: *State,
        arena: *std.heap.ArenaAllocator,

        /// Returns the next `Field` in the current record, or `null` when
        /// the record boundary has been reached. After `null` is returned,
        /// subsequent calls continue to return `null`.
        pub fn next(self: FieldIterator) !?Field {
            const state = self.state;
            // Main parsing. We already have the first line of data, which could
            // be a record (compact format) or a key/value pair (long format)

            if (state.current_line == null) return null;
            if (state.end_of_record_reached) return null;
            // non-blank line, but we could have an eof marker
            // TODO: deduplicate this code
            if (try Directive.parse(state.current_line.?, state)) |d| {
                switch (d) {
                    .eof => {
                        // there needs to be an eof then
                        if (state.nextLine()) |_| {
                            try parseError("Data found after #!eof", state);
                            return ParseError.ParseFailed; // this is terminal
                        } else {
                            state.eof_found = true;
                            state.current_line = null;
                            return null; // all is good, we're done
                        }
                    },
                    else => {
                        try parseError("Directive found after data started", state);
                        state.current_line = state.nextLine();
                        // TODO: This runs the risk of a malicious file creating
                        // a stackoverflow by using many non-eof directives
                        return self.next();
                    },
                }
            }

            // Whatever the format, the beginning will always be the key data
            // key:stuff:value
            var it = std.mem.splitScalar(u8, state.current_line.?, ':');
            const key = it.next().?; // first one we get for free
            if (key.len > 0) std.debug.assert(key[0] != state.field_delimiter);
            state.column += key.len + 1;
            state.partial_line_column += key.len + 1;
            const value = try Value.parse(
                it.rest(),
                state,
                state.field_delimiter,
            );

            var field: ?Field = null;
            if (!value.error_parsing) {
                field = .{
                    .key = try dupe(state.*, key, .key),
                    .value = value.item_value,
                };
            }

            if (value.reader_advanced and state.field_delimiter == ',') {
                log.debug("advanced", .{});
                // In compact format we'll stay on the same line
                const real_column = state.column;
                state.current_line = state.nextLine();
                // Reset line and column position, because we're actually staying on the same line now
                state.line -= 1;
                state.column = real_column + 1;
                state.partial_line_column = 0;
            }

            // The difference between compact and line here is that compact we will instead of
            // line = try nextLine, we will do something like line = line[42..]
            if (state.field_delimiter == '\n') {
                state.current_line = state.nextLine();
                if (state.current_line == null) {
                    state.end_of_record_reached = true;
                    return field;
                }
                // close out record, return
                if (state.current_line.?.len == 0) {
                    // End of record
                    state.end_of_record_reached = true;
                    state.current_line = state.nextLine();
                    return field;
                }
            } else {
                // We should be on a delimiter, otherwise, we should be at the end
                state.current_line = state.current_line.?[state.partial_line_column..]; // can't use l here because line may have been reassigned
                state.partial_line_column = 0;
                if (state.current_line.?.len == 0) {
                    // close out record
                    state.current_line = state.nextLine();
                    state.partial_line_column = 0;
                    state.end_of_record_reached = true;
                    return field;
                } else {
                    if (state.current_line.?[0] != state.field_delimiter) {
                        log.err("reset line for next item, first char not '{c}':{?s}", .{ state.field_delimiter, state.current_line });
                        return error.ParseFailed;
                    }
                    state.current_line = state.current_line.?[1..];
                }
            }
            return field;
        }

        /// Consumes remaining fields in this record and coerces them into a
        /// Zig struct or tagged union `T`.
        ///
        /// For structs, fields are matched by name. Only the first occurrence
        /// of each field name is used; duplicates are ignored. Fields in `T`
        /// that have default values and are not present in the data use those
        /// defaults. Missing fields without defaults return an error.
        ///
        /// For tagged unions, the active tag field must appear first in the
        /// stream. The tag field name defaults to `"type"` or `T.srf_tag_field` if
        /// declared.
        pub fn to(self: FieldIterator, comptime T: type, options: CoercionOptions) !T {
            const ti = @typeInfo(T);

            switch (ti) {
                .@"struct" => {
                    // What is this magic? The FieldEnum creates a type (an enum)
                    // where each enum member has the name of a field in the struct
                    //
                    // So... struct { a: u8, b: u8 } will yield enum { a, b }
                    const FieldEnum = std.meta.FieldEnum(T);
                    // Then...EnumFieldStruct will create a struct from this, where
                    // each enum value becomes a field. We will specify the field
                    // type, and the default value. Combining these two calls gets
                    // us a struct with all the same field names, but we get a chance
                    // to make all the fields boolean, so we can use it to track
                    // which fields have been set
                    var found: std.enums.EnumFieldStruct(FieldEnum, bool, false) = .{};
                    // SAFETY: all fields updated below or error is returned
                    var obj: T = undefined;

                    while (try self.next()) |f| {
                        inline for (std.meta.fields(T)) |type_field| {
                            // To replicate the behavior of the record version of to,
                            // we need to only take the first version of the field,
                            // so if it's specified twice in the data, we will ignore
                            // all but the first instance
                            if (std.mem.eql(u8, f.key, type_field.name) and
                                !@field(found, type_field.name))
                            {
                                const result = try coerce(type_field.name, type_field.type, f.value, options);
                                @field(obj, type_field.name) = result.value;
                                // Now account for this in our magic found struct...
                                @field(found, type_field.name) = true;
                                if (result.require_free_original) {
                                    if (findAllocator(self.state.*, .value)) |alloc|
                                        switch (f.value.?) {
                                            .string => |s| alloc.free(s),
                                            .bytes => |b| alloc.free(b),
                                            else => unreachable,
                                        };
                                    // This is not actually true. Without specific
                                    // allocator, the fallback arena will be used, so we
                                    // don't really need to free anything in this
                                    // circumstance
                                    // else return error.AllocatorRequired;
                                }
                            }
                        }
                    }
                    // Fill in the defaults for remaining fields. Throw if anything
                    // is missing both value (from above) and default (from here)
                    inline for (std.meta.fields(T)) |type_field| {
                        if (!@field(found, type_field.name)) {
                            // We did not find this field above...revert to default value
                            if (type_field.default_value_ptr) |ptr| {
                                @field(obj, type_field.name) = @as(*const type_field.type, @ptrCast(@alignCast(ptr))).*;
                            } else {
                                log.debug("Record could not be coerced. Field {s} not found on srf data, and no default value exists on the type", .{type_field.name});
                                return error.FieldNotFoundOnFieldWithoutDefaultValue;
                            }
                        }
                    }
                    return obj;
                },
                .@"union" => {
                    const active_tag_name = if (@hasDecl(T, "srf_tag_field"))
                        T.srf_tag_field
                    else
                        "type";
                    const first_try = try self.next();
                    if (first_try == null) return error.ActiveTagFieldNotFound;
                    const f = first_try.?;
                    if (!std.mem.eql(u8, f.key, active_tag_name))
                        return error.ActiveTagNotFirstField; // required here, but not on the Record version of to
                    if (f.value == null or f.value.? != .string)
                        return error.ActiveTagValueMustBeAString;
                    const active_tag = f.value.?.string;
                    // We're done with the tag. Need to free it in case a custom
                    // allocator is in use
                    defer if (findAllocator(self.state.*, .value)) |a| a.free(active_tag);
                    inline for (std.meta.fields(T)) |field_type| {
                        if (std.mem.eql(u8, active_tag, field_type.name)) {
                            return @unionInit(T, field_type.name, try self.to(field_type.type, options));
                        }
                    }
                    return error.ActiveTagDoesNotExist;
                },
                else => @compileError("Deserialization not supported on " ++ @tagName(ti) ++ " types"),
            }
            return error.CoercionNotPossible;
        }
        test to {
            // Example: coerce fields directly into a Zig struct from the iterator
            const Data = struct {
                name: []const u8,
                score: u8,
                active: bool = true,
            };
            const data =
                \\#!srfv1
                \\name::alice,score:num:99
            ;
            const allocator = std.testing.allocator;
            var reader = std.Io.Reader.fixed(data);
            var ri = try iterator(&reader, allocator, .{});
            defer ri.deinit();

            const result = try (try ri.next()).?.to(Data, .{});
            try std.testing.expectEqualStrings("alice", result.name);
            try std.testing.expectEqual(@as(u8, 99), result.score);
            // `active` was not in the data, so the default value is used
            try std.testing.expect(result.active);
        }
    };
    /// Releases all memory owned by this iterator. This frees the internal
    /// arena (and all parsed data allocated from it), then frees the arena
    /// struct itself. After calling `deinit`, any slices or string pointers
    /// obtained from `FieldIterator.next` or `FieldIterator.to` are invalid.
    pub fn deinit(self: RecordIterator) void {
        self.toOwnedFallback().deinit();
    }

    pub fn toOwnedFallback(self: RecordIterator) FallbackArena {
        const ca = self.arena.child_allocator;
        const fb = self.state.fallback_arena;
        self.arena.deinit();
        ca.destroy(self.arena);
        return .{ .fallback_arena = fb };
    }

    pub const FallbackArena = struct {
        fallback_arena: ?*std.heap.ArenaAllocator,

        pub fn deinit(self: FallbackArena) void {
            if (self.fallback_arena) |f| {
                f.deinit();
                f.child_allocator.destroy(f);
            }
        }
    };

    /// Returns `true` if the data has not expired based on the `#!expires`
    /// directive. If no expiry was specified, the data is always considered
    /// fresh. Callers should check this after parsing to decide whether to
    /// use or refresh cached data. Note that data will be returned by parse/
    /// iterator regardless of freshness. This enables callers to use cached
    /// data temporarily while refreshing it
    pub fn isFresh(self: RecordIterator, io: std.Io) bool {
        if (self.expires) |exp|
            return std.Io.Timestamp.now(io, .real).toSeconds() < exp;

        // no expiry: always fresh, never frozen
        return true;
    }
    test isFresh {
        // Example: check expiry on parsed data. Data without an #!expires
        // directive is always considered fresh.
        const data =
            \\#!srfv1
            \\key::value
        ;
        const allocator = std.testing.allocator;
        var reader = std.Io.Reader.fixed(data);
        var ri = try iterator(&reader, allocator, .{});
        defer ri.deinit();

        // No expiry set, so always fresh
        try std.testing.expect(ri.isFresh(std.testing.io));
    }
};

/// Options controlling SRF parsing behavior. Passed to both `iterator` and
/// `parse`.
pub const ParseOptions = struct {
    /// diagnostics should be a struct provided by Diagnostics function
    diagnostics: ?*Diagnostics = null,

    /// By default, the parser will copy data so it is safe to free the original
    /// buffer or use with streaming readers. This will impose about 8% overhead,
    /// and ties the lifetime of any strings to the deinit() method. For
    /// fixed buffer parsing, consider using .none, which will not allocate
    /// strings. More complex use cases can use their own allocator for control
    /// over string lifetime
    parse_allocator: ParseAllocator = .parse_arena,

    /// Strict number parsing. In strict number parsing, numbers will fail
    /// to parse if `std.fmt.parseFloat` fails. Turn this off to be more lenient.
    ///
    /// Turning it off will have a slight performance impact, but helps support
    /// scenarios where srf data is more user facing (think config, not cache).
    /// For example, commas will be tolerated as will leading currency symbols
    strict_number_parsing: bool = true,
};

/// Allocator to use for parsing data
pub const ParseAllocator = union(enum) {
    /// Absolutely no allocation allowed. This will fail with AllocationRequired under the following circumstances:
    ///
    /// * binary data is encountered (needs decoding)
    /// * multi-line string literals are encountered (allocation needed to accomodate streaming readers)
    none,
    /// No allocator. Lifetime of any data parsed is tied to the underlying
    /// data passed to the reader. This is most appropriate when the caller
    /// uses a fixed buffer, and is equivalent of the "Leaky" parsing
    /// functions of std.json. IMPORTANT: This will NOT avoid all allocations.
    /// Specifically binary data is base64 encoded per the spec and we need
    /// to allocate space for the decode. Also, multi-line data can not be
    /// assumed to be available post-reader advance, and therefore allocation
    /// is performed in that case.
    ///
    /// For ABSOLUTELY NO ALLOCATION, use none. Otherwise, the Parsed
    /// struct has a deinit function that frees everything, and toOwnedFallback
    /// which will deinit the arena for parsing and return the fallback arena
    /// that can be released at a later time
    none_with_fallback,
    /// Use the arena allocator created by the parser to copy any strings.
    /// This ties the lifetime of any data parsed to the parser deinit()
    /// function. Imposes about 8% overhead compared to "none".
    parse_arena,
    /// Parser will use the caller-supplied allocator, providing the most
    /// flexibility over lifetime. Overhead will be contingent on the allocator
    /// used. If the allocator is an arena allocator, assume 8% overhead over
    /// "none". It is likely a fixed buffer allocator would be somewhat less.
    custom: CustomParseAllocator,
};

/// Allocator to use for a specific scope (either keys or values). Different
/// from parseAllocator because the custom variant here has to be a std.mem.Allocator
pub const ScopeAllocator = union(enum) {
    /// Absolutely no allocation allowed. This will fail with AllocationRequired under the following circumstances:
    ///
    /// * binary data is encountered (needs decoding)
    /// * multi-line string literals are encountered (allocation needed to accomodate streaming readers)
    none,
    /// No allocator. Lifetime of any data parsed is tied to the underlying
    /// data passed to the reader. This is most appropriate when the caller
    /// uses a fixed buffer, and is equivalent of the "Leaky" parsing
    /// functions of std.json. IMPORTANT: This will NOT avoid all allocations.
    /// Specifically binary data is base64 encoded per the spec and we need
    /// to allocate space for the decode. Also, multi-line data can not be
    /// assumed to be available post-reader advance, and therefore allocation
    /// is performed in that case.
    ///
    /// For ABSOLUTELY NO ALLOCATION, use none. Otherwise, the Parsed
    /// struct has a deinit function that frees everything, and toOwnedFallback
    /// which will deinit the arena for parsing and return the fallback arena
    /// that can be released at a later time
    none_with_fallback,
    /// Use the arena allocator created by the parser to copy any strings.
    /// This ties the lifetime of any data parsed to the parser deinit()
    /// function. Imposes about 8% overhead compared to "none".
    parse_arena,
    /// Parser will use the caller-supplied allocator, providing the most
    /// flexibility over lifetime. Overhead will be contingent on the allocator
    /// used. If the allocator is an arena allocator, assume 8% overhead over
    /// "none". It is likely a fixed buffer allocator would be somewhat less.
    allocator: std.mem.Allocator,
};
pub const CustomParseAllocator = struct {
    key_allocator: ScopeAllocator,
    value_allocator: ScopeAllocator,

    /// Initializes a custom parse allocator suitable for use in common workflows
    /// where you iterate each record, then iterate through fields with full control
    pub fn initIterator(allocator: std.mem.Allocator) CustomParseAllocator {
        return .{
            .key_allocator = .{ .allocator = allocator },
            .value_allocator = .{ .allocator = allocator },
        };
    }

    /// Initializes a custom parse allocator suitable for use in common workflows
    /// where you iterate each record and call RecordIterator.to() on the result
    pub fn initTo(allocator: std.mem.Allocator) CustomParseAllocator {
        return .{
            .key_allocator = .{ .none = {} },
            .value_allocator = .{ .allocator = allocator },
        };
    }
};

const Directive = union(enum) {
    magic,
    long_format,
    compact_format,
    require_eof,
    eof,
    expires: i64,
    created: i64,
    modified: i64,

    /// Parses a Directive. The only reason the allocator is used here is because
    /// a parse error may be logged, so this function should *NOT* be called
    /// with an arena allocator
    pub fn parse(str: []const u8, state: *RecordIterator.State) ParseError!?Directive {
        if (!std.mem.startsWith(u8, str, "#!")) return null;
        // strip any comments off
        var it = std.mem.splitScalar(u8, str[2..], '#');
        const line = std.mem.trimEnd(u8, it.first(), &std.ascii.whitespace);
        if (std.mem.eql(u8, "srfv1", line)) return .magic;
        if (std.mem.eql(u8, "requireeof", line)) return .require_eof;
        if (std.mem.eql(u8, "requireof", line)) {
            try parseError("#!requireof found. Did you mean #!requireeof?", state);
            return null;
        }
        if (std.mem.eql(u8, "eof", line)) return .eof;
        if (std.mem.eql(u8, "compact", line)) return .compact_format;
        if (std.mem.eql(u8, "long", line)) return .long_format;
        if (std.mem.startsWith(u8, line, "expires=")) {
            return .{ .expires = std.fmt.parseInt(i64, line["expires=".len..], 10) catch return ParseError.ParseFailed };
        }
        if (std.mem.startsWith(u8, line, "created=")) {
            return .{ .created = std.fmt.parseInt(i64, line["created=".len..], 10) catch return ParseError.ParseFailed };
        }
        if (std.mem.startsWith(u8, line, "modified=")) {
            return .{ .modified = std.fmt.parseInt(i64, line["modified=".len..], 10) catch return ParseError.ParseFailed };
        }
        return null;
    }
};
/// Options controlling SRF output formatting. Used by `fmt`
pub const FormatOptions = struct {
    /// When `true`, fields are separated by newlines and records by blank
    /// lines (`#!long` format). When `false` (default), fields are
    /// comma-separated and records are newline-separated (compact format).
    long_format: bool = false,

    /// Will emit the eof directive as well as requireeof
    emit_eof: bool = false,

    /// Specify an expiration time for the data being written
    expires: ?i64 = null,

    /// Specify a created time for the data being written
    created: ?i64 = null,

    /// Specify a modified time for the data being written
    modified: ?i64 = null,

    /// By setting this to false, you can avoid writing any header/footer data
    /// and just format the record. This is useful for appending to an existing
    /// srf file rather than overwriting all the data
    emit_directives: bool = true,

    /// When set to true, this will output all values, even if they are the default values
    emit_default_values: bool = false,
};

/// Returns a formatter for writing typed Zig values directly to SRF format.
/// Custom serialization is supported via the `srfFormat` method convention
/// on struct/union fields.
pub fn fmt(comptime T: type, items: []const T, options: FormatOptions) FromFormatter(T) {
    return .{ .items = items, .options = options };
}
pub fn FromFormatter(comptime T: type) type {
    return struct {
        items: []const T,
        options: FormatOptions,

        const Self = @This();

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try frontMatter(writer, self.options);
            var first = true;
            for (self.items) |item| {
                if (!first and self.options.long_format) try writer.writeByte('\n');
                first = false;
                try self.formatItem(T, item, writer);
            }
            try epilogue(writer, self.options);
        }

        /// Formats a single item from the overall array. Analagous to a record
        /// We take a type value here specifically for unions, because we need
        /// to serialize the payload value of unions as well. Normally the
        /// type value is simply "T".
        fn formatItem(self: Self, comptime I: type, value: I, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const ti = @typeInfo(I);
            const delimiter: u8 = if (self.options.long_format) '\n' else ',';
            switch (ti) {
                .@"struct" => |info| {
                    var first = true;
                    inline for (info.fields) |f| {
                        const field_val = @field(value, f.name);
                        const is_default_val = if (f.defaultValue()) |d|
                            std.meta.eql(field_val, d)
                        else
                            false;
                        if (self.options.emit_default_values or !is_default_val) {
                            if (!first) {
                                try writer.writeByte(delimiter);
                            }
                            try self.formatField(f.type, f.name, field_val, writer);
                            first = false;
                        }
                    }
                    try writer.writeByte('\n');
                },
                .@"union" => {
                    const active_tag_name = @tagName(value);
                    const key = if (@hasDecl(T, "srf_tag_field"))
                        T.srf_tag_field
                    else
                        "type";
                    // We need to serialize the active tag name first, then the payload
                    try self.formatField([]const u8, key, active_tag_name, writer);
                    try writer.writeByte(delimiter);
                    // Now to serialize the payload itself
                    switch (value) {
                        inline else => |payload| {
                            if (@typeInfo(@TypeOf(payload)) == .@"union")
                                @compileError("Nested unions not supported for srf serialization");
                            return self.formatItem(@TypeOf(payload), payload, writer);
                        },
                    }
                },
                .@"enum" => |info| {
                    _ = info;
                    @compileError("Enum not implemented");
                    // TODO: I do not believe this is correct
                    // inline for (info.fields) |f|
                    //     inx = try self.setField(inx, f.name, self.SourceType, null, val);
                },
                .error_set => return error.ErrorSetNotSupported,
                else => @compileError("Expected struct, union, error set or enum type, found '" ++ @typeName(T) ++ "'"),
            }
        }

        /// Formats a field from the item (struct/union). Analagous to a field in a record
        fn formatField(self: Self, comptime F: type, comptime field_name: []const u8, val: F, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const ti = @typeInfo(F);
            switch (ti) {
                .optional => |o| {
                    if (val) |v|
                        return self.formatField(o.child, field_name, v, writer);
                    try self.formatValue(field_name, null, writer);
                },
                .pointer => |p| {
                    // We don't have an allocator, so the only thing we can do
                    // here is manage []const u8 or []u8
                    if (p.size != .slice or p.child != u8)
                        return error.WriteFailed;
                    try self.formatValue(field_name, .{ .string = val }, writer);
                },
                .type, .void, .noreturn => return error.WriteFailed,
                .comptime_float, .comptime_int, .undefined, .null, .error_union => return error.WriteFailed,
                .error_set, .@"fn", .@"opaque", .frame => return error.WriteFailed,
                .@"anyframe", .vector, .enum_literal => return error.WriteFailed,
                .int => try self.formatValue(field_name, .{ .number = @floatFromInt(val) }, writer),
                .float => try self.formatValue(field_name, .{ .number = @floatCast(val) }, writer),
                .bool => try self.formatValue(field_name, .{ .boolean = val }, writer),
                .@"enum" => try self.formatValue(field_name, .{ .string = @tagName(val) }, writer),
                .array => return error.WriteFailed,
                .@"struct", .@"union" => {
                    if (std.meta.hasMethod(F, "srfFormat"))
                        return val.srfFormat(field_name, writer);
                    @compileError("struct/union formatting requires pub fn srfFormat(self: Self, comptime key, writer: *std.Io.Writer) std.Io.Writer.Error!void. No function found on type: " ++ F);
                },
            }
        }

        /// Formats a single key/value pair
        fn formatValue(self: Self, key: []const u8, value: ?Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(key);
            try writer.writeByte(':');
            if (value) |v|
                switch (v) {
                    .string => |s| {
                        const newlines = std.mem.containsAtLeastScalar(u8, s, 1, '\n');
                        const commas = !self.options.long_format and std.mem.containsAtLeastScalar(u8, s, 1, ',');
                        // Output the count if newlines exist
                        const count = if (newlines or commas) s.len else null;
                        if (count) |c| try writer.print("{d}", .{c});
                        try writer.writeByte(':');
                        try writer.writeAll(s);
                    },
                    .number => |n| try writer.print("num:{d}", .{@as(f64, @floatCast(n))}),
                    .boolean => |b| try writer.print("bool:{}", .{b}),
                    .bytes => |b| try writer.print("binary:{b64}", .{b}),
                }
            else
                try writer.writeAll(":null:");
        }
    };
}
fn frontMatter(writer: *std.Io.Writer, options: FormatOptions) !void {
    if (!options.emit_directives) return;
    try writer.writeAll("#!srfv1\n");
    if (options.long_format)
        try writer.writeAll("#!long\n");
    if (options.emit_eof)
        try writer.writeAll("#!requireeof\n");
    if (options.expires) |e|
        try writer.print("#!expires={d}\n", .{e});
    if (options.created) |e|
        try writer.print("#!created={d}\n", .{e});
    if (options.modified) |e|
        try writer.print("#!modified={d}\n", .{e});
}
fn epilogue(writer: *std.Io.Writer, options: FormatOptions) !void {
    if (!options.emit_directives) return;
    if (options.emit_eof)
        try writer.writeAll("#!eof\n");
}

/// Creates a streaming `RecordIterator` for the given reader. This is the
/// preferred entry point for parsing SRF data, as it yields records and
/// fields lazily without collecting them into slices.
///
/// The returned iterator owns an arena allocator that holds all parsed data
/// (string values, keys, etc.). Call `RecordIterator.deinit` to free
/// everything when done. Parsed field data remains valid until `deinit` is
/// called.
///
/// The iterator handles SRF header directives (`#!srfv1`, `#!long`,
/// `#!compact`, `#!requireeof`, `#!expires`) automatically during
/// construction. Notably this means you can check isFresh() immediately.
///
/// Also note that as state is allocated and stored within the recorditerator,
/// callers can assign the return value to a constant
pub fn iterator(reader: *std.Io.Reader, allocator: std.mem.Allocator, options: ParseOptions) ParseError!RecordIterator {

    // The arena and state are heap-allocated because RecordIterator is returned
    // by value. Both RecordIterator and FieldIterator must share mutable state,
    // so State is held by pointer to ensure mutations propagate across copies.
    // The arena pointer serves the same purpose -- an inline arena would be
    // duplicated on copy, creating dangling pointers. These are O(1) per parse
    // session (not per-record or per-field), so the cost is negligible.

    // create an arena allocator for everytyhing related to parsing
    const arena: *std.heap.ArenaAllocator = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const state = try arena.allocator().create(RecordIterator.State);
    state.* = .{
        .reader = reader,
        .current_line = null,
        .options = options,
        .aa = arena.allocator(),
        .allocator = allocator,
    };
    var it: RecordIterator = .{
        .arena = arena,
        .expires = null,
        .created = null,
        .modified = null,
        .state = state,
    };
    const first_line = it.state.nextLine() orelse return ParseError.ParseFailed;

    if (try Directive.parse(first_line, it.state)) |d| {
        if (d != .magic) try parseError("Magic header not found on first line", it.state);
    } else try parseError("Magic header not found on first line", it.state);

    // Loop through the header material and configure our main parsing
    it.state.current_line = blk: {
        while (it.state.nextLine()) |line| {
            if (try Directive.parse(line, it.state)) |d| {
                switch (d) {
                    .magic => try parseError("Found a duplicate magic header", it.state),
                    .long_format => it.state.field_delimiter = '\n',
                    .compact_format => it.state.field_delimiter = ',', // what if we have both?
                    .require_eof => it.state.require_eof = true,
                    .expires => |exp| it.expires = exp,
                    .created => |exp| it.created = exp,
                    .modified => |exp| it.modified = exp,
                    .eof => {
                        // there needs to be an eof then
                        if (it.state.nextLine()) |_| {
                            try parseError("Data found after #!eof", it.state);
                            return ParseError.ParseFailed; // this is terminal
                        } else return it;
                    },
                }
            } else break :blk line;
        }
        return it; //without current_line - we're at the end of file
    };
    return it; // with current_line
}
const DataScope = enum {
    key,
    value,
};
inline fn dupe(state: RecordIterator.State, data: []const u8, scope: DataScope) ParseError![]const u8 {
    if (findAllocator(state, scope)) |a|
        return try a.dupe(u8, data);
    return data;
}
inline fn findAllocator(state: RecordIterator.State, scope: DataScope) ?std.mem.Allocator {
    switch (state.options.parse_allocator) {
        .none, .none_with_fallback => return null,
        .parse_arena => return state.aa,
        .custom => |a| {
            const alloc = switch (scope) {
                .key => a.key_allocator,
                .value => a.value_allocator,
            };
            switch (alloc) {
                .none, .none_with_fallback => return null,
                .parse_arena => return state.aa,
                .allocator => |c| return c,
            }
        },
    }
}
/// Logs a parse error to diagnostics. Note that the allocator provided should
/// *NOT* be an arena, as the message must outlive the parse results, which will
/// be otherwise cleaned up in the arena deinit
inline fn parseError(message: []const u8, state: *RecordIterator.State) ParseError!void {
    log.debug("Parse error. Parse state {f}, message: {s}", .{ state, message });
    if (state.options.diagnostics) |d| {
        try d.addError(.{
            .message = message,
            .level = .err,
            .line = state.line,
            .column = state.column,
        });
    } else {
        return ParseError.ParseFailed;
    }
}

// Test-only types extracted to module level so that their pub methods
// (required by std.meta.hasMethod) do not appear in generated documentation.
const TestRecType = enum {
    foo,
    bar,
};
const TestCustomType = struct {
    const Self = @This();
    pub fn srfParse(val: []const u8) !CoercionResult(Self) {
        if (std.mem.eql(u8, "hi", val)) return .init(.{});
        return error.ValueNotEqualHi;
    }
    pub fn srfFormat(self: Self, comptime field_name: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.writeAll(field_name);
        try writer.writeAll("::hi");
    }
};

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
    var it = try iterator(&reader, allocator, .{});
    defer it.deinit();
    const maybe_record = try it.next();
    try std.testing.expect(maybe_record != null);
    const rec = maybe_record.?;
    const maybe_field = try rec.next();
    try std.testing.expect(maybe_field != null);
    const field = maybe_field.?;
    try std.testing.expectEqualStrings("key", field.key);
    try std.testing.expectEqualStrings(
        "string value, with any data except a \\n. an optional string length between the colons",
        field.value.?.string,
    );
    try std.testing.expect(try rec.next() == null);
    try std.testing.expect(try it.next() == null);
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
    const records = try iterator(&reader, allocator, .{});
    defer records.deinit();
    const first = (try records.next()).?;
    try std.testing.expect((try first.next()) != null);
    try std.testing.expect((try first.next()) == null);
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
    const records = try iterator(&reader, allocator, .{});
    defer records.deinit();
    var rec = (try records.next()).?;
    var field = (try rec.next()).?;
    try std.testing.expectEqualStrings("key", field.key);
    try std.testing.expectEqualStrings("string value, with any data except a \\n. an optional string length between the colons", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("this is a number", field.key);
    try std.testing.expectEqual(@as(f64, 5), field.value.?.number);
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("null value", field.key);
    try std.testing.expect(field.value == null);
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("array", field.key);
    try std.testing.expectEqualStrings(
        "array's don't exist. Use json or toml or something",
        field.value.?.string,
    );
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("data with newlines must have a length", field.key);
    try std.testing.expectEqualStrings("foo\nbar", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("boolean value", field.key);
    try std.testing.expect(!field.value.?.boolean);
    try std.testing.expect(try rec.next() == null);

    const second = (try records.next()).?;
    field = (try second.next()).?;
    try std.testing.expectEqualStrings("key", field.key);
    try std.testing.expectEqualStrings("this is the second record", field.value.?.string);
    field = (try second.next()).?;
    try std.testing.expectEqualStrings("this is a number", field.key);
    try std.testing.expectEqual(@as(f64, 42), field.value.?.number);
    field = (try second.next()).?;
    try std.testing.expectEqualStrings("null value", field.key);
    try std.testing.expect(field.value == null);
    field = (try second.next()).?;
    try std.testing.expectEqualStrings("array", field.key);
    try std.testing.expectEqualStrings("array's still don't exist", field.value.?.string);
    field = (try second.next()).?;
    try std.testing.expectEqualStrings("data with newlines must have a length", field.key);
    try std.testing.expectEqualStrings("single line", field.value.?.string);
    try std.testing.expect(try second.next() == null);
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
    const records = try iterator(&reader, allocator, .{});
    defer records.deinit();
    var first = (try records.next()).?;
    var field = (try first.next()).?;
    try std.testing.expectEqualStrings("key", field.key);
    try std.testing.expectEqualStrings("string value must have a length between colons or end with a comma", field.value.?.string);
    field = (try first.next()).?;
    try std.testing.expectEqualStrings("this is a number", field.key);
    try std.testing.expectEqual(@as(f64, 5), field.value.?.number);
    field = (try first.next()).?;
    try std.testing.expectEqualStrings("null value", field.key);
    try std.testing.expect(field.value == null);
    field = (try first.next()).?;
    try std.testing.expectEqualStrings("array", field.key);
    try std.testing.expectEqualStrings("array's don't exist. Use json or toml or something", field.value.?.string);
    field = (try first.next()).?;
    try std.testing.expectEqualStrings("data with newlines must have a length", field.key);
    try std.testing.expectEqualStrings("foo\nbar", field.value.?.string);
    field = (try first.next()).?;
    try std.testing.expectEqualStrings("boolean value", field.key);
    try std.testing.expect(!field.value.?.boolean);
    try std.testing.expect(try first.next() == null);

    const second = (try records.next()).?;
    field = (try second.next()).?;
    try std.testing.expectEqualStrings("key", field.key);
    try std.testing.expectEqualStrings("this is the second record", field.value.?.string);
    try std.testing.expect(try second.next() == null);
    try std.testing.expect(try records.next() == null);
}
test "serialize/deserialize" {
    const Data = struct {
        foo: []const u8,
        bar: u8,
        qux: ?TestRecType = .foo,
        b: bool = false,
        f: f32 = 4.2,
        custom: ?TestCustomType = null,
    };

    const compact =
        \\#!srfv1
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42,qux::bar
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42,qux::bar,b:bool:true,f:num:6.9,custom:string:hi
        \\
    ;
    // Now we'll do it with the iterator version
    var it_reader = std.Io.Reader.fixed(compact);
    const ri = try iterator(&it_reader, std.testing.allocator, .{});
    defer ri.deinit();
    const rec1_it = try (try ri.next()).?.to(Data, .{});
    try std.testing.expectEqualStrings("bar", rec1_it.foo);
    try std.testing.expectEqual(@as(u8, 42), rec1_it.bar);
    try std.testing.expectEqual(@as(TestRecType, .foo), rec1_it.qux);
    _ = try ri.next();
    _ = try ri.next();
    const rec4_it = try (try ri.next()).?.to(Data, .{});
    try std.testing.expectEqualStrings("bar", rec4_it.foo);
    try std.testing.expectEqual(@as(u8, 42), rec4_it.bar);
    try std.testing.expectEqual(@as(TestRecType, .bar), rec4_it.qux.?);
    try std.testing.expectEqual(true, rec4_it.b);
    try std.testing.expectEqual(@as(f32, 6.9), rec4_it.f);

    const all_data: []const Data = &.{
        .{ .foo = "hi", .bar = 42, .qux = .bar, .b = true, .f = 6.0, .custom = .{} },
        .{ .foo = "bar", .bar = 69 },
    };
    var buf: [4096]u8 = undefined;
    const compact_from = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(Data, all_data, .{})},
    );

    const expect =
        \\#!srfv1
        \\foo::hi,bar:num:42,qux::bar,b:bool:true,f:num:6,custom::hi
        \\foo::bar,bar:num:69
        \\
    ;
    try std.testing.expectEqualStrings(expect, compact_from);
}
test "serialize/deserialize allows overflow lifetime semantics" {
    const Data = struct {
        foo: []const u8,
        bar: u8,
        qux: ?TestRecType = .foo,
        b: bool = false,
        f: f32 = 4.2,
        custom: ?TestCustomType = null,
    };

    const compact =
        \\#!srfv1
        \\foo:binary:YmFy,bar:num:42
        \\foo:binary:YmFy,bar:num:42
        \\foo:binary:YmFy,bar:num:42,qux::bar
        \\foo:binary:YmFy,bar:num:42,qux::bar,b:bool:true,f:num:6.9,custom:string:hi
        \\
    ;
    // Round trip and make sure we get equivalent objects back
    var compact_reader = std.Io.Reader.fixed(compact);
    var it = try iterator(
        &compact_reader,
        std.testing.allocator,
        .{ .parse_allocator = .none_with_fallback },
    );

    const rec1 = try (try it.next()).?.to(Data, .{});
    try std.testing.expect(it.state.fallback_arena != null);
    const fallback = it.toOwnedFallback();
    defer fallback.deinit();
    // This would not be possible otherwise
    try std.testing.expectEqualStrings("bar", rec1.foo);
    try std.testing.expectEqual(@as(u8, 42), rec1.bar);
    try std.testing.expectEqual(@as(TestRecType, .foo), rec1.qux);

    var another_reader = std.Io.Reader.fixed(compact);
    var another_it = try iterator(
        &another_reader,
        std.testing.allocator,
        .{ .parse_allocator = .none },
    );
    defer another_it.deinit();
    var fi = (try another_it.next()).?;
    try std.testing.expectError(error.AllocationRequired, fi.next());
}
test "conversion from string true/false to proper type" {
    const Data = struct {
        foo: []const u8,
        bar: u8,
        qux: ?TestRecType = .foo,
        b: bool = false,
        f: f32 = 4.2,
        custom: ?TestCustomType = null,
    };
    const compact =
        \\#!srfv1
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42,qux::bar,b::true,f:num:6.9,custom:string:hi
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42,qux::bar,b::false,f:num:6.9,custom:string:hi
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42,qux::bar,b::noneoftheabove,f:num:6.9,custom:string:hi
        \\
    ;
    // Round trip and make sure we get equivalent objects back
    var compact_reader = std.Io.Reader.fixed(compact);
    var it = try iterator(&compact_reader, std.testing.allocator, .{});
    defer it.deinit();

    const rec1 = try (try it.next()).?.to(Data, .{});
    try std.testing.expect(rec1.b);
    const rec2 = try (try it.next()).?.to(Data, .{});
    try std.testing.expect(!rec2.b);
    const rec3_raw = (try it.next()).?;
    try std.testing.expectError(
        error.StringValueOfBooleanMustBetrueOrfalse,
        rec3_raw.to(Data, .{}),
    );
}
test "iterator with blank" {
    const Data = struct {
        foo: []const u8,
        bar: u8,
        qux: ?TestRecType = .foo,
        b: bool = false,
        f: f32 = 4.2,
        custom: ?TestCustomType = null,
    };
    const compact =
        \\#!srfv1
        \\foo::1,bar:num:42
        \\
        \\# second record
        \\
        \\foo::2,bar:num:24
        \\
    ;
    // Round trip and make sure we get equivalent objects back
    var compact_reader = std.Io.Reader.fixed(compact);
    const it = try iterator(&compact_reader, std.testing.allocator, .{});
    defer it.deinit();

    const rec1 = try (try it.next()).?.to(Data, .{});
    try std.testing.expectEqual('1', rec1.foo[0]);
    try std.testing.expectEqual(@as(u8, 42), rec1.bar);
    const rec2 = try (try it.next()).?.to(Data, .{});
    try std.testing.expectEqual('2', rec2.foo[0]);
    try std.testing.expectEqual(@as(u8, 24), rec2.bar);
}
test "unions" {
    const Foo = struct {
        number: u8,
        true_or_false: bool,
    };
    const Bar = struct {
        sentence: []const u8,
        decimal: f64,
    };
    const MixedData = union(enum) {
        foo: Foo,
        bar: Bar,

        // pub const srf_tag_field = "foobar";
    };

    const data: []const MixedData = &.{
        .{ .foo = .{ .number = 42, .true_or_false = true } },
        .{ .bar = .{ .sentence = "foobar", .decimal = 6.9 } },
    };
    var buf: [4096]u8 = undefined;
    const compact_from = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(MixedData, data, .{})},
    );
    const expect =
        \\#!srfv1
        \\type::foo,number:num:42,true_or_false:bool:true
        \\type::bar,sentence::foobar,decimal:num:6.9
        \\
    ;
    try std.testing.expectEqualStrings(expect, compact_from);

    var compact_reader = std.Io.Reader.fixed(expect);
    const it = try iterator(&compact_reader, std.testing.allocator, .{});
    defer it.deinit();

    const rec1 = try (try it.next()).?.to(MixedData, .{});
    try std.testing.expectEqualDeep(data[0], rec1);
    const rec2 = try (try it.next()).?.to(MixedData, .{});
    try std.testing.expectEqualDeep(data[1], rec2);
}
test "union with custom-allocator initTo: dispatch tag must not leak" {
    // Repro for: FieldIterator.to(T) on a tagged union dupes the
    // dispatch tag's string value via the value-side allocator, then
    // discards the slice without freeing it. With `.parse_arena`,
    // the leak is masked by `it.deinit()`. With
    // `.{ .custom = .initTo(my_alloc) }`, the slice lives in the
    // caller's allocator and DebugAllocator catches the leak.
    //
    // Each parsed union record produces exactly one leaked
    // allocation: the `type::<variant>` string.
    const Foo = struct {
        number: u8,
    };
    const Bar = struct {
        decimal: f64,
    };
    const MixedData = union(enum) {
        foo: Foo,
        bar: Bar,
    };
    const compact =
        \\#!srfv1
        \\type::foo,number:num:42
        \\type::bar,decimal:num:6.9
        \\
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(compact);
    var ri = try iterator(&reader, allocator, .{
        .parse_allocator = .{ .custom = .initTo(allocator) },
    });
    defer ri.deinit();
    // Each `to(MixedData, .{})` call leaks one string allocation
    // (the dispatch tag) into `allocator`. Walk both records; on
    // exit, DebugAllocator should report 2 leaks.
    const rec1 = try (try ri.next()).?.to(MixedData, .{});
    try std.testing.expectEqual(@as(u8, 42), rec1.foo.number);
    const rec2 = try (try ri.next()).?.to(MixedData, .{});
    try std.testing.expectEqual(@as(f64, 6.9), rec2.bar.decimal);
}
test "enums" {
    const Types = enum {
        foo,
        bar,

        // pub const srf_tag_field = "foobar";
    };

    const Data = struct {
        data_type: ?Types = null,
        yo: u8,
    };
    // The original test here was using the non-iterator version of the parser
    // (now deleted). That allowed random access, so we could coerce to
    // multiple data types if they had a similar shape. I'm not sure why you
    // might want to do that, but since we are consuming the reader in a single
    // pass this is no longer possible. This note is here to provide some
    // context in case this functionality is actually ever needed, we can
    // maybe figure this out and re-enable this portion of the test
    // const Data2 = struct {
    //     data_type: Types = .bar,
    //     yo: u8,
    // };

    const data: []const Data = &.{
        .{ .data_type = .foo, .yo = 42 },
        .{ .data_type = null, .yo = 69 },
    };
    var buf: [4096]u8 = undefined;
    const compact_from = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(Data, data, .{})},
    );
    const expect =
        \\#!srfv1
        \\data_type::foo,yo:num:42
        \\yo:num:69
        \\
    ;
    try std.testing.expectEqualStrings(expect, compact_from);

    var compact_reader = std.Io.Reader.fixed(expect);
    const it = try iterator(&compact_reader, std.testing.allocator, .{});
    defer it.deinit();

    const rec1 = try (try it.next()).?.to(Data, .{});
    try std.testing.expectEqualDeep(data[0], rec1);
    const rec2 = try (try it.next()).?.to(Data, .{});
    try std.testing.expectEqualDeep(data[1], rec2);

    const missing_tag =
        \\#!srfv1
        \\yo:num:69
        \\
    ;
    var mt_reader = std.Io.Reader.fixed(missing_tag);
    const mt = try iterator(&mt_reader, std.testing.allocator, .{});
    defer mt.deinit();
    const mt_rec1 = (try mt.next()).?;
    const mt_data = try mt_rec1.to(Data, .{});
    try std.testing.expect(mt_data.data_type == null);

    // const mt_dt2 = try mt_rec1.to(Data2, .{});
    // try std.testing.expect(mt_dt2.data_type == .bar);
}
test "compact format length-prefixed string as last field" {
    // When a length-prefixed value is the last field on the line,
    // rest_of_data.len == size exactly. The check on line 216 uses
    // strict > instead of >=, falling through to the multi-line path
    // where size - rest_of_data.len - 1 underflows.
    const data =
        \\#!srfv1
        \\name::alice,desc:5:world
    ;
    var reader = std.Io.Reader.fixed(data);
    const it = try iterator(&reader, std.testing.allocator, .{});
    defer it.deinit();
    const rec = (try it.next()).?;
    const field1 = (try rec.next()).?;
    try std.testing.expectEqualStrings("name", field1.key);
    try std.testing.expectEqualStrings("alice", field1.value.?.string);
    const field2 = (try rec.next()).?;
    try std.testing.expectEqualStrings("desc", field2.key);
    try std.testing.expectEqualStrings("world", field2.value.?.string);
    try std.testing.expectEqual(null, try rec.next());
    try std.testing.expectEqual(null, try it.next());
}
test iterator {
    // Example: streaming through records and fields using the iterator API.
    // This is the preferred parsing approach -- no intermediate slices are
    // allocated for fields or records.
    const data =
        \\#!srfv1
        \\name::alice,desc:5:world
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    var ri = try iterator(&reader, allocator, .{});
    defer ri.deinit();

    // Advance to the first (and only) record
    const fi = (try ri.next()).?;

    // Iterate fields within the record
    const field1 = (try fi.next()).?;
    try std.testing.expectEqualStrings("name", field1.key);
    try std.testing.expectEqualStrings("alice", field1.value.?.string);
    const field2 = (try fi.next()).?;
    try std.testing.expectEqualStrings("desc", field2.key);
    try std.testing.expectEqualStrings("world", field2.value.?.string);

    // No more fields in this record
    try std.testing.expect(try fi.next() == null);
    // No more records
    try std.testing.expect(try ri.next() == null);
}
test "iterator with custom allocator" {
    // Example: streaming through records and fields using the iterator API.
    // This is the preferred parsing approach -- no intermediate slices are
    // allocated for fields or records.
    const data =
        \\#!srfv1
        \\name::alice,desc:5:world
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    var ri = try iterator(
        &reader,
        allocator,
        .{
            .parse_allocator = .{ .custom = .initIterator(std.testing.allocator) },
        },
    );
    defer ri.deinit();

    // Advance to the first (and only) record
    const fi = (try ri.next()).?;

    // Iterate fields within the record
    const field1 = (try fi.next()).?;
    defer allocator.free(field1.key);
    defer allocator.free(field1.value.?.string);
    try std.testing.expectEqualStrings("name", field1.key);
    try std.testing.expectEqualStrings("alice", field1.value.?.string);
    const field2 = (try fi.next()).?;
    defer allocator.free(field2.key);
    defer allocator.free(field2.value.?.string);
    try std.testing.expectEqualStrings("desc", field2.key);
    try std.testing.expectEqualStrings("world", field2.value.?.string);

    // No more fields in this record
    try std.testing.expect(try fi.next() == null);
    // No more records
    try std.testing.expect(try ri.next() == null);
}
test "iterator with custom allocator - to() pattern" {
    // const ll = std.testing.log_level;
    // std.testing.log_level = .debug;
    // defer std.testing.log_level = ll;
    // Example: streaming through records and fields using the iterator API.
    // This is the preferred parsing approach -- no intermediate slices are
    // allocated for fields or records.
    const data =
        \\#!srfv1
        \\name::alice,desc:5:world
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    var ri = try iterator(
        &reader,
        allocator,
        .{
            .parse_allocator = .{ .custom = .initTo(std.testing.allocator) },
        },
    );
    defer ri.deinit();

    // Advance to the first (and only) record
    const fi = (try ri.next()).?;
    const rec = try fi.to(struct { name: []const u8, desc: []const u8 }, .{});
    defer allocator.free(rec.name);
    defer allocator.free(rec.desc);
    try std.testing.expectEqualStrings("alice", rec.name);
    try std.testing.expectEqualStrings("world", rec.desc);

    // No more fields in this record
    try std.testing.expect(try fi.next() == null);
    // No more records
    try std.testing.expect(try ri.next() == null);
}
test "iterator with custom allocator - to() pattern, relaxed and custom coercion" {
    const ll = std.testing.log_level;
    std.testing.log_level = .debug;
    defer std.testing.log_level = ll;
    // Example: streaming through records and fields using the iterator API.
    // This is the preferred parsing approach -- no intermediate slices are
    // allocated for fields or records.
    // Should this also allow the lienient number parsing? probably so
    const data =
        \\#!srfv1
        \\name::alice,desc:5:world,cost::$5
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    var ri = try iterator(
        &reader,
        allocator,
        .{
            .parse_allocator = .{ .custom = .initTo(std.testing.allocator) },
        },
    );
    defer ri.deinit();

    // Advance to the first (and only) record
    const fi = (try ri.next()).?;
    const rec = try fi.to(struct { name: []const u8, desc: []const u8, cost: usize }, .{ .strings_to_numbers = true });
    defer allocator.free(rec.name);
    defer allocator.free(rec.desc);
    try std.testing.expectEqualStrings("alice", rec.name);
    try std.testing.expectEqualStrings("world", rec.desc);

    // No more fields in this record
    try std.testing.expect(try fi.next() == null);
    // No more records
    try std.testing.expect(try ri.next() == null);
}
test "iterator basic long form" {
    // Example: batch parsing collects all records and fields into slices.
    // Prefer `iterator` for streaming; use `parse` when random access to
    // all records is needed.
    const data =
        \\#!srfv1
        \\#!long
        \\name::alice
        \\age:num:30
        \\
        \\name::bob
        \\age:num:25
        \\#!eof
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    // Diagnostics are optional, but if you would like them, include
    // these three lines and set the options field:
    var diags: BoundedDiagnostics(10) = .empty;
    var diag: Diagnostics = diags.diagnostics();
    var it = try iterator(&reader, allocator, .{ .diagnostics = &diag });
    defer it.deinit();

    const first_field_first_record = (try ((try it.next()).?.next())).?;
    try std.testing.expectEqualStrings("alice", first_field_first_record.value.?.string);
    const first_field_second_record = (try ((try it.next()).?.next())).?;
    try std.testing.expectEqualStrings("bob", first_field_second_record.value.?.string);
    try std.testing.expectEqual(null, try it.next());
}
test "parse tolerates commas and currency in numbers" {
    // Example: batch parsing collects all records and fields into slices.
    // Prefer `iterator` for streaming; use `parse` when random access to
    // all records is needed.
    const data =
        \\#!srfv1
        \\#!long
        \\name::bananas
        \\cost:num:$30.00
        \\
        \\name::spaceship
        \\cost:num:$1,000,000,000.42
        \\
        \\name::Omikase in Tokyo
        \\cost:num:¥15,000
        \\
        \\name::Airbus A380
        \\cost:num:€410,000,000
        \\
        \\name::Bread in London
        \\cost:num:5 €
        \\
        \\name::The other way
        \\cost:num:€ 5
        \\#!eof
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    var it = try iterator(&reader, allocator, .{ .strict_number_parsing = false });
    defer it.deinit();

    var rec = (try it.next()).?;
    var field = (try rec.next()).?;
    // Dollars are single byte currency
    try std.testing.expectEqualStrings("bananas", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqual(@as(f64, 30), field.value.?.number);

    // Add commas to the mix
    rec = (try it.next()).?;
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("spaceship", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqual(@as(f64, 1_000_000_000.42), field.value.?.number);

    // Yen symbol is two bytes long
    rec = (try it.next()).?;
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("Omikase in Tokyo", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqual(@as(f64, 15_000), field.value.?.number);

    rec = (try it.next()).?;
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("Airbus A380", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqual(@as(f64, 410_000_000), field.value.?.number);

    rec = (try it.next()).?;
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("Bread in London", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqual(@as(f64, 5), field.value.?.number);

    rec = (try it.next()).?;
    field = (try rec.next()).?;
    try std.testing.expectEqualStrings("The other way", field.value.?.string);
    field = (try rec.next()).?;
    try std.testing.expectEqual(@as(f64, 5), field.value.?.number);

    try std.testing.expectEqual(null, try it.next());
}
test fmt {
    // Example: serialize typed Zig values directly to SRF format.
    const Data = struct {
        name: []const u8,
        age: u8,
    };
    const values: []const Data = &.{
        .{ .name = "alice", .age = 30 },
        .{ .name = "bob", .age = 25 },
    };
    var buf: [4096]u8 = undefined;
    const result = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(Data, values, .{})},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\name::alice,age:num:30
        \\name::bob,age:num:25
        \\
    , result);
}
test "fmt commas" {
    // Example: serialize typed Zig values directly to SRF format.
    const Data = struct {
        name: []const u8 = "bob",
        age: u8,
    };
    const values: []const Data = &.{
        .{ .name = "alice, yo", .age = 30 },
    };
    var buf: [4096]u8 = undefined;
    const result = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(Data, values, .{})},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\name:9:alice, yo,age:num:30
        \\
    , result);
}
test "fmt outputs defaults with option" {
    // Example: serialize typed Zig values directly to SRF format.
    const Data = struct {
        name: []const u8 = "bob",
        age: u8,
    };
    const values: []const Data = &.{
        .{ .age = 30 },
    };
    var buf: [4096]u8 = undefined;
    const result = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(Data, values, .{ .emit_default_values = true })},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\name::bob,age:num:30
        \\
    , result);
}
test "parse with diagnostics" {
    // Example: batch parsing collects all records and fields into slices.
    // Prefer `iterator` for streaming; use `parse` when random access to
    // all records is needed.
    const data =
        \\#!srfv1
        \\#!long
        \\name:num:alice
        \\age:num:30
        \\
        \\name::bob
        \\age:num:25
        \\#!eof
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    var diags: BoundedDiagnostics(10) = .empty;
    var diag: Diagnostics = diags.diagnostics();
    try std.testing.expect(
        blk: {
            var it = iterator(&reader, allocator, .{ .diagnostics = &diag }) catch break :blk false;
            defer it.deinit();
            while (true) {
                _ = it.next() catch |err| break :blk err == error.ParseFailed;
            }
            break :blk false;
        },
    );
    const errors = diags.errors();
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    const first = errors[0];
    try std.testing.expectEqual(@as(usize, 3), first.line);
    // TODO: this is at the end of the line. I'm not sure what the actual column
    // should be here, but it's probably not that. Maybe at the beginning of
    // "alice", which would be column 10?
    try std.testing.expectEqual(@as(usize, 15), first.column);
    try std.testing.expectEqualStrings("error parsing numeric value", first.message);
    // const second = errors[1];
    // try std.testing.expectEqualStrings("yo", second.message);
}
