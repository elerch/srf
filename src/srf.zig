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
    pub fn deinit(self: Diagnostics) void {
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

const ValueWithMetaData = struct {
    item_value: ?Value,
    error_parsing: bool = false,
    reader_advanced: bool = false,
};
pub const Value = union(enum) {
    number: f64,

    /// Bytes are converted to/from base64, string is not
    bytes: []const u8,

    /// String is not touched in any way
    string: []const u8,

    boolean: bool,

    // pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    //     switch (self) {
    //         .number => try writer.print("num: {d}", .{self.number}),
    //         .bytes => try writer.print("bytes: {x}", .{self.bytes}),
    //         .string => try writer.print("string: {s}", .{self.string}),
    //         .boolean => try writer.print("boolean: {}", .{self.boolean}),
    //     }
    // }
    pub fn parse(allocator: std.mem.Allocator, str: []const u8, state: *RecordIterator.State, delimiter: u8) ParseError!ValueWithMetaData {
        const type_val_sep_raw = std.mem.indexOfScalar(u8, str, ':');
        if (type_val_sep_raw == null) {
            try parseError(allocator, "no type data or value after key", state);
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
                .item_value = .{ .string = try dupe(allocator, state.options, val) },
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
                try parseError(allocator, "error parsing base64 value", state);
                return .{
                    .item_value = null,
                    .error_parsing = true,
                };
            };
            const data = try allocator.alloc(u8, size);
            errdefer allocator.free(data);
            Decoder.decode(data, val) catch {
                try parseError(allocator, "error parsing base64 value", state);
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
            // log.debug("num total_chars: {d}", .{total_chars});
            state.column += total_chars;
            state.partial_line_column += total_chars;
            const val_trimmed = std.mem.trim(u8, val, &std.ascii.whitespace);
            const number = std.fmt.parseFloat(@FieldType(Value, "number"), val_trimmed) catch {
                try parseError(allocator, "error parsing numeric value", state);
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

                try parseError(allocator, "error parsing boolean value", state);
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
            try parseError(allocator, "unrecognized metadata for key", state);
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
                .item_value = .{ .string = val },
            };
        }
        // This is not enough, we need more data from the reader
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
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
};

// A field has a key and a value, but the value may be null
pub const Field = struct {
    key: []const u8,
    value: ?Value,
};

fn coerce(name: []const u8, comptime T: type, val: ?Value) !T {
    // Here's the deduplicated set of field types that coerce needs to handle:
    // Direct from SRF values:
    // Need parsing from string:
    // - Date, ?Date -- Date.parse(string)
    //
    // Won't work with Record.to(T) generically:
    // - []const OptionContract -- nested sub-records (OptionsChain has calls/puts arrays)
    // - ?[]const Holding, ?[]const SectorWeight -- nested sub-records in EtfProfile
    //
    const ti = @typeInfo(T);
    if (val == null and ti != .optional)
        return error.NullValueCannotBeAssignedToNonNullField;

    // []const u8 is classified as a pointer
    switch (ti) {
        .optional => |o| if (val) |_|
            return try coerce(name, o.child, val)
        else
            return null,
        .pointer => |p| {
            // We don't have an allocator, so the only thing we can do
            // here is manage []const u8 or []u8
            if (p.size != .slice or p.child != u8)
                return error.CoercionNotPossible;
            if (val.? != .string and val.? != .bytes)
                return error.CoercionNotPossible;
            if (val.? == .string)
                return val.?.string;
            return val.?.bytes;
        },
        .type, .void, .noreturn => return error.CoercionNotPossible,
        .comptime_float, .comptime_int, .undefined, .null, .error_union => return error.CoercionNotPossible,
        .error_set, .@"fn", .@"opaque", .frame => return error.CoercionNotPossible,
        .@"anyframe", .vector, .enum_literal => return error.CoercionNotPossible,
        .int => return @as(T, @intFromFloat(val.?.number)),
        .float => return @as(T, @floatCast(val.?.number)),
        .bool => return val.?.boolean,
        .@"enum" => return std.meta.stringToEnum(T, val.?.string).?,
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

// A record has a list of fields, with no assumptions regarding duplication,
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
    fields: []const Field,

    pub fn fmt(value: Record, options: FormatOptions) RecordFormatter {
        return .{ .value = value, .options = options };
    }

    pub fn firstFieldByName(self: Record, field_name: []const u8) ?Field {
        for (self.fields) |f|
            if (std.mem.eql(u8, f.key, field_name)) return f;
        return null;
    }

    fn maxFields(comptime T: type) usize {
        const ti = @typeInfo(T);
        if (ti != .@"union") return std.meta.fields(T).len;
        comptime var max_fields = 0;
        inline for (std.meta.fields(T)) |f| {
            const field_count = std.meta.fields(f.type).len;
            if (field_count > max_fields) max_fields = field_count;
        }
        return max_fields + 1;
    }

    fn OwnedRecord(comptime T: type) type {
        // for unions, we don't know how many fields we're dealing with...
        return struct {
            fields_buf: [fields_len]Field,
            fields_allocated: [fields_len]bool = .{false} ** fields_len,
            allocator: std.mem.Allocator,
            source_value: T,
            cached_record: ?Record = null,

            const Self = @This();
            const fields_len = maxFields(T);

            pub const SourceType = T;

            pub fn init(allocator: std.mem.Allocator, source: T) Self {
                return .{
                    // SAFETY: fields_buf is set by record() and is guarded by fields_set
                    .fields_buf = undefined,
                    .allocator = allocator,
                    .source_value = source,
                };
            }

            const FormatResult = struct {
                value: ?Value,
                allocated: bool = false,
            };
            fn setField(
                self: *Self,
                inx: usize,
                comptime field_name: []const u8,
                comptime field_type: type,
                comptime default_value_ptr: ?*const anyopaque,
                val: field_type,
            ) !usize {
                if (default_value_ptr) |d| {
                    const default_val: *const field_type = @ptrCast(@alignCast(d));
                    if (std.meta.eql(val, default_val.*)) return inx;
                }
                const value = try self.formatField(field_type, field_name, val);
                self.fields_buf[inx] = .{
                    .key = field_name,
                    .value = value.value,
                };
                self.fields_allocated[inx] = value.allocated;
                return inx + 1;
            }
            fn formatField(self: Self, comptime field_type: type, comptime field_name: []const u8, val: anytype) !FormatResult {
                const ti = @typeInfo(field_type);
                switch (ti) {
                    .optional => |o| {
                        if (val) |v|
                            return self.formatField(o.child, field_name, v);
                        return .{ .value = null };
                    },
                    .pointer => |p| {
                        // We don't have an allocator, so the only thing we can do
                        // here is manage []const u8 or []u8
                        if (p.size != .slice or p.child != u8)
                            return error.CoercionNotPossible;
                        return .{ .value = .{ .string = val } };
                    },
                    .type, .void, .noreturn => return error.CoercionNotPossible,
                    .comptime_float, .comptime_int, .undefined, .null, .error_union => return error.CoercionNotPossible,
                    .error_set, .@"fn", .@"opaque", .frame => return error.CoercionNotPossible,
                    .@"anyframe", .vector, .enum_literal => return error.CoercionNotPossible,
                    .int => return .{ .value = .{ .number = @floatFromInt(val) } },
                    .float => return .{ .value = .{ .number = @floatCast(val) } },
                    .bool => return .{ .value = .{ .boolean = val } },
                    .@"enum" => return .{ .value = .{ .string = @tagName(val) } },
                    .array => return error.NotImplemented,
                    .@"struct", .@"union" => {
                        if (std.meta.hasMethod(field_type, "srfFormat")) {
                            return .{
                                .value = val.srfFormat(self.allocator, field_name) catch |e| {
                                    log.err(
                                        "custom format of field {s} failed : {}",
                                        .{ field_name, e },
                                    );
                                    return error.CustomFormatFailed;
                                },
                                .allocated = true,
                            };
                        }
                        return error.CoercionNotPossible;
                    },
                }
            }
            pub fn record(self: *Self) !Record {
                return self.recordInternal(SourceType, self.source_value, 0);
            }
            fn recordInternal(self: *Self, comptime U: type, val: U, start_inx: usize) !Record {
                if (self.cached_record) |r| return r;
                var inx: usize = start_inx;
                const ti = @typeInfo(U);
                switch (ti) {
                    .@"struct" => |info| {
                        inline for (info.fields) |f| {
                            const field_val = @field(val, f.name);
                            inx = try self.setField(inx, f.name, f.type, f.default_value_ptr, field_val);
                        }
                    },
                    .@"union" => {
                        const active_tag_name = @tagName(val);
                        const key = if (@hasDecl(U, "srf_tag_field"))
                            U.srf_tag_field
                        else
                            "active_tag";
                        self.fields_buf[inx] = .{
                            .key = key,
                            .value = .{ .string = active_tag_name },
                        };
                        inx += 1;
                        switch (val) {
                            inline else => |payload| {
                                if (@typeInfo(@TypeOf(payload)) == .@"union")
                                    @compileError("Nested unions not supported for srf serialization");
                                return self.recordInternal(@TypeOf(payload), payload, inx);
                            },
                        }
                    },
                    .@"enum" => |info| {
                        // TODO: I do not believe this is correct
                        inline for (info.fields) |f|
                            inx = try self.setField(inx, f.name, self.SourceType, null, val);
                    },
                    .error_set => return error.ErrorSetNotSupported,
                    else => @compileError("Expected struct, union, error set or enum type, found '" ++ @typeName(T) ++ "'"),
                }
                self.cached_record = .{ .fields = self.fields_buf[0..inx] };
                return self.cached_record.?;
            }
            pub fn deinit(self: *Self) void {
                for (0..fields_len) |i| {
                    if (self.fields_allocated[i]) {
                        if (self.fields_buf[i].value) |v| switch (v) {
                            .string => |s| self.allocator.free(s),
                            .bytes => |b| self.allocator.free(b),
                            else => {},
                        };
                    }
                }
            }
        };
    }
    /// Create an OwnedRecord from a Zig struct value. Fields are mapped by name:
    /// string/optional string fields become string Values, numeric fields become
    /// number Values, bools become boolean Values, and enums are converted via
    /// @tagName. Struct/union fields with a `srfFormat` method use that for
    /// custom serialization (allocated via the provided allocator).
    ///
    /// The returned OwnedRecord borrows string data from `val` for any
    /// []const u8 fields. The caller must ensure `val` (and any data it
    /// references) outlives the OwnedRecord.
    ///
    /// Call `deinit()` to free any allocations made for custom-formatted fields.
    pub fn from(comptime T: type, allocator: std.mem.Allocator, val: T) !OwnedRecord(T) {
        return OwnedRecord(T).init(allocator, val);
    }

    /// Coerce Record to a type. Does not handle fields with arrays
    pub fn to(self: Record, comptime T: type) !T {
        const ti = @typeInfo(T);

        switch (ti) {
            .@"struct" => {
                // SAFETY: all fields updated below or error is returned
                var obj: T = undefined;
                inline for (std.meta.fields(T)) |type_field| {
                    // find the field in the data by field name, set the value
                    // if not found, return an error
                    if (self.firstFieldByName(type_field.name)) |srf_field| {
                        @field(obj, type_field.name) = try coerce(type_field.name, type_field.type, srf_field.value);
                    } else {
                        // No srf_field found...revert to default value
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
                    "active_tag";
                if (self.firstFieldByName(active_tag_name)) |srf_field| {
                    if (srf_field.value == null or srf_field.value.? != .string)
                        return error.ActiveTagValueMustBeAString;
                    const active_tag = srf_field.value.?.string;
                    inline for (std.meta.fields(T)) |f| {
                        if (std.mem.eql(u8, active_tag, f.name)) {
                            return @unionInit(T, f.name, try self.to(f.type));
                        }
                    }
                    return error.ActiveTagDoesNotExist;
                } else return error.ActiveTagFieldNotFound;
            },
            else => @compileError("Deserialization not supported on " ++ @tagName(ti) ++ " types"),
        }
        return error.CoercionNotPossible;
    }
};

/// The Parsed struct is equivalent to Parsed(T) in std.json. Since most are
/// familiar with std.json, it differs in the following ways:
///
/// * There is a records field instead of a value field. In json, one type of
/// value is an array. SRF does not have an array data type, but the set of
/// records is an array. json as a format is structred as a single object at
/// the outermost
///
/// * This is not generic. In SRF, it is a separate function to bind the list
/// of records to a specific data type. This will add some (hopefully minimal)
/// overhead, but also avoid conflating parsing from the coercion from general
/// type to specifics, and avoids answering questions like "what if I have
/// 15 values for the same key" until you're actually dealing with that problem
/// (see std.json.ParseOptions duplicate_field_behavior and ignore_unknown_fields)
///
/// When implemented, there will include a pub fn bind(self: Parsed, comptime T: type, options, BindOptions) BindError![]T
/// function. The options will include things related to duplicate handling and
/// missing fields
pub const RecordIterator = struct {
    arena: *std.heap.ArenaAllocator,
    /// optional expiry time for the data. Useful for caching
    /// Note that on a parse, data will always be returned and it will be up
    /// to the caller to check is_fresh and determine the right thing to do
    expires: ?i64,

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

    pub fn next(self: RecordIterator) !?FieldIterator {
        // TODO: we need to capture the fieldIterator here and make sure it's run
        // to the ground to keep our state intact
        const state = self.state;
        if (state.field_iterator) |f| {
            // We need to finish the fields on the previous record
            while (try f.next()) |_| {}
            state.field_iterator = null;
        }
        if (state.current_line == null) {
            if (state.options.diagnostics) |d|
                if (d.errors.items.len > 0) return ParseError.ParseFailed;
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
        if (try Directive.parse(self.arena.allocator(), state.current_line.?, state)) |d| {
            switch (d) {
                .eof => {
                    // there needs to be an eof then
                    if (state.nextLine()) |_| {
                        try parseError(self.arena.allocator(), "Data found after #!eof", state);
                        return ParseError.ParseFailed; // this is terminal
                    } else {
                        state.eof_found = true;
                        state.current_line = null;
                        return null; // all is good, we're done
                    }
                },
                else => {
                    try parseError(self.arena.allocator(), "Directive found after data started", state);
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

    pub const FieldIterator = struct {
        state: *State,
        arena: *std.heap.ArenaAllocator,

        pub fn next(self: FieldIterator) !?Field {
            const state = self.state;
            const aa = self.arena.allocator();
            // Main parsing. We already have the first line of data, which could
            // be a record (compact format) or a key/value pair (long format)

            // log.debug("", .{});
            log.debug("current line:{?s}", .{state.current_line});
            if (state.current_line == null) return null;
            if (state.end_of_record_reached) return null;
            // non-blank line, but we could have an eof marker
            // TODO: deduplicate this code
            if (try Directive.parse(aa, state.current_line.?, state)) |d| {
                switch (d) {
                    .eof => {
                        // there needs to be an eof then
                        if (state.nextLine()) |_| {
                            try parseError(aa, "Data found after #!eof", state);
                            return ParseError.ParseFailed; // this is terminal
                        } else {
                            state.eof_found = true;
                            state.current_line = null;
                            return null; // all is good, we're done
                        }
                    },
                    else => {
                        try parseError(aa, "Directive found after data started", state);
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
                aa,
                it.rest(),
                state,
                state.field_delimiter,
            );

            var field: ?Field = null;
            if (!value.error_parsing) {
                field = .{ .key = try dupe(aa, state.options, key), .value = value.item_value };
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

        /// Coerce Record to a type. Does not handle fields with arrays
        pub fn to(self: FieldIterator, comptime T: type) !T {
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
                                @field(obj, type_field.name) =
                                    try coerce(type_field.name, type_field.type, f.value);
                                // Now account for this in our magic found struct...
                                @field(found, type_field.name) = true;
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
                        "active_tag";
                    const first_try = try self.next();
                    if (first_try == null) return error.ActiveTagFieldNotFound;
                    const f = first_try.?;
                    if (!std.mem.eql(u8, f.key, active_tag_name))
                        return error.ActiveTagNotFirstField; // required here, but not on the Record version of to
                    if (f.value == null or f.value.? != .string)
                        return error.ActiveTagValueMustBeAString;
                    const active_tag = f.value.?.string;
                    inline for (std.meta.fields(T)) |field_type| {
                        if (std.mem.eql(u8, active_tag, field_type.name)) {
                            return @unionInit(T, field_type.name, try self.to(field_type.type));
                        }
                    }
                    return error.ActiveTagDoesNotExist;
                },
                else => @compileError("Deserialization not supported on " ++ @tagName(ti) ++ " types"),
            }
            return error.CoercionNotPossible;
        }
    };
    pub fn deinit(self: RecordIterator) void {
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        child_allocator.destroy(self.arena);
    }

    pub fn isFresh(self: RecordIterator) bool {
        if (self.expires) |exp|
            return std.time.timestamp() < exp;

        // no expiry: always fresh, never frozen
        return true;
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
    expires: i64,

    pub fn parse(allocator: std.mem.Allocator, str: []const u8, state: *RecordIterator.State) ParseError!?Directive {
        if (!std.mem.startsWith(u8, str, "#!")) return null;
        // strip any comments off
        var it = std.mem.splitScalar(u8, str[2..], '#');
        const line = std.mem.trimEnd(u8, it.first(), &std.ascii.whitespace);
        if (std.mem.eql(u8, "srfv1", line)) return .magic;
        if (std.mem.eql(u8, "requireeof", line)) return .require_eof;
        if (std.mem.eql(u8, "requireof", line)) {
            try parseError(allocator, "#!requireof found. Did you mean #!requireeof?", state);
            return null;
        }
        if (std.mem.eql(u8, "eof", line)) return .eof;
        if (std.mem.eql(u8, "compact", line)) return .compact_format;
        if (std.mem.eql(u8, "long", line)) return .long_format;
        if (std.mem.startsWith(u8, line, "expires=")) {
            return .{ .expires = std.fmt.parseInt(i64, line["expires=".len..], 10) catch return ParseError.ParseFailed };
            // try parseError(allocator, options, "#!requireof found. Did you mean #!requireeof?", state);
            // return null;
        }
        return null;
    }
};
pub const FormatOptions = struct {
    long_format: bool = false,

    /// Will emit the eof directive as well as requireeof
    emit_eof: bool = false,

    /// Specify an expiration time for the data being written
    expires: ?i64 = null,

    /// By setting this to false, you can avoid writing any header/footer data
    /// and just format the record. This is useful for appending to an existing
    /// srf file rather than overwriting all the data
    emit_directives: bool = true,
};

/// Returns a formatter that formats the given value
pub fn fmt(value: []const Record, options: FormatOptions) Formatter {
    return .{ .value = value, .options = options };
}
/// Returns a formatter that formats the given value. This will take a concrete
/// type, convert it to the SRF record format automatically (using srfFormat if
/// found), and output to the writer. It is recommended to use a FixedBufferAllocator
/// for the allocator, which is only used for custom srfFormat functions (I think - what about enum tag names?)
pub fn fmtFrom(comptime T: type, allocator: std.mem.Allocator, value: []const T, options: FormatOptions) FromFormatter(T) {
    return .{ .value = value, .options = options, .allocator = allocator };
}
pub fn FromFormatter(comptime T: type) type {
    return struct {
        value: []const T,
        options: FormatOptions,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try frontMatter(writer, self.options);
            var first = true;
            for (self.value) |item| {
                if (!first and self.options.long_format) try writer.writeByte('\n');
                first = false;
                var owned_record = Record.from(T, self.allocator, item) catch
                    return std.Io.Writer.Error.WriteFailed;
                defer owned_record.deinit();
                const record = owned_record.record() catch return std.Io.Writer.Error.WriteFailed;
                try writer.print("{f}\n", .{Record.fmt(record, self.options)});
            }
            try epilogue(writer, self.options);
        }
    };
}
test fmt {
    const records: []const Record = &.{
        .{ .fields = &.{.{ .key = "foo", .value = .{ .string = "bar" } }} },
    };
    var buf: [1024]u8 = undefined;
    const formatted = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(records, .{ .long_format = true })},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\#!long
        \\foo::bar
        \\
    , formatted);
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
}
fn epilogue(writer: *std.Io.Writer, options: FormatOptions) !void {
    if (!options.emit_directives) return;
    if (options.emit_eof)
        try writer.writeAll("#!eof\n");
}

pub const Formatter = struct {
    value: []const Record,
    options: FormatOptions,

    pub fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try frontMatter(writer, self.options);
        var first = true;
        for (self.value) |record| {
            if (!first and self.options.long_format) try writer.writeByte('\n');
            first = false;
            try writer.print("{f}\n", .{Record.fmt(record, self.options)});
        }
        try epilogue(writer, self.options);
    }
};
pub const RecordFormatter = struct {
    value: Record,
    options: FormatOptions,

    pub fn format(self: RecordFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.value.fields, 0..) |f, i| {
            try writer.writeAll(f.key);
            if (f.value == null) {
                try writer.writeAll(":null:");
            } else {
                try writer.writeByte(':');
                switch (f.value.?) {
                    .string => |s| {
                        const newlines = std.mem.containsAtLeastScalar(u8, s, 1, '\n');
                        // Output the count if newlines exist
                        const count = if (newlines) s.len else null;
                        if (count) |c| try writer.print("{d}", .{c});
                        try writer.writeByte(':');
                        try writer.writeAll(s);
                    },
                    .number => |n| try writer.print("num:{d}", .{@as(f64, @floatCast(n))}),
                    .boolean => |b| try writer.print("bool:{}", .{b}),
                    .bytes => |b| try writer.print("binary:{b64}", .{b}),
                }
            }
            const delimiter: u8 = if (self.options.long_format) '\n' else ',';
            if (i < self.value.fields.len - 1)
                try writer.writeByte(delimiter);
        }
    }
};

pub const Parsed = struct {
    records: []Record,
    arena: *std.heap.ArenaAllocator,
    expires: ?i64,

    pub fn deinit(self: Parsed) void {
        const ca = self.arena.child_allocator;
        self.arena.deinit();
        ca.destroy(self.arena);
    }
};

/// parse function
pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator, options: ParseOptions) ParseError!Parsed {
    var records = std.ArrayList(Record).empty;
    var it = try iterator(reader, allocator, options);
    errdefer it.deinit();
    const aa = it.arena.allocator();
    var field_count: usize = 1;
    while (try it.next()) |fi| {
        var al = try std.ArrayList(Field).initCapacity(aa, field_count);
        while (try fi.next()) |f| {
            try al.append(aa, .{
                .key = f.key,
                .value = f.value,
            });
        }
        // assume that most records are same number of fields
        field_count = @max(field_count, al.items.len);
        try records.append(aa, .{
            .fields = try al.toOwnedSlice(aa),
        });
    }
    return .{
        .records = try records.toOwnedSlice(aa),
        .arena = it.arena,
        .expires = it.expires,
    };
}

/// Gets an iterator to stream through the data
pub fn iterator(reader: *std.Io.Reader, allocator: std.mem.Allocator, options: ParseOptions) ParseError!RecordIterator {

    // The arena and state are heap-allocated because RecordIterator is returned
    // by value. Both RecordIterator and FieldIterator must share mutable state,
    // so State is held by pointer to ensure mutations propagate across copies.
    // The arena pointer serves the same purpose -- an inline arena would be
    // duplicated on copy, creating dangling pointers. These are O(1) per parse
    // session (not per-record or per-field), so the cost is negligible.

    // create an arena allocator for everytyhing related to parsing
    const arena: *std.heap.ArenaAllocator = try allocator.create(std.heap.ArenaAllocator);
    errdefer if (options.diagnostics == null) allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer if (options.diagnostics == null) arena.deinit();
    const aa = arena.allocator();
    const state = try aa.create(RecordIterator.State);
    state.* = .{
        .reader = reader,
        .current_line = null,
        .options = options,
    };
    var it: RecordIterator = .{
        .arena = arena,
        .expires = null,
        .state = state,
    };
    const first_line = it.state.nextLine() orelse return ParseError.ParseFailed;

    if (try Directive.parse(aa, first_line, it.state)) |d| {
        if (d != .magic) try parseError(aa, "Magic header not found on first line", it.state);
    } else try parseError(aa, "Magic header not found on first line", it.state);

    // Loop through the header material and configure our main parsing
    it.state.current_line = blk: {
        while (it.state.nextLine()) |line| {
            if (try Directive.parse(aa, line, it.state)) |d| {
                switch (d) {
                    .magic => try parseError(aa, "Found a duplicate magic header", it.state),
                    .long_format => it.state.field_delimiter = '\n',
                    .compact_format => it.state.field_delimiter = ',', // what if we have both?
                    .require_eof => it.state.require_eof = true,
                    .expires => |exp| it.expires = exp,
                    .eof => {
                        // there needs to be an eof then
                        if (it.state.nextLine()) |_| {
                            try parseError(aa, "Data found after #!eof", it.state);
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

inline fn dupe(allocator: std.mem.Allocator, options: ParseOptions, data: []const u8) ParseError![]const u8 {
    if (options.alloc_strings)
        return try allocator.dupe(u8, data);
    return data;
}
inline fn parseError(allocator: std.mem.Allocator, message: []const u8, state: *RecordIterator.State) ParseError!void {
    log.debug("Parse error. Parse state {f}, message: {s}", .{ state, message });
    if (state.options.diagnostics) |d| {
        try d.addError(allocator, .{
            .message = try dupe(allocator, state.options, message),
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
    try std.testing.expectEqual(@as(usize, 1), records.records.len);
    try std.testing.expectEqual(@as(usize, 1), records.records[0].fields.len);
    const kvps = records.records[0].fields;
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
    try std.testing.expectEqual(@as(usize, 1), records.records.len);
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
    try std.testing.expectEqual(@as(usize, 2), records.records.len);
    const first = records.records[0];
    try std.testing.expectEqual(@as(usize, 6), first.fields.len);
    try std.testing.expectEqualStrings("key", first.fields[0].key);
    try std.testing.expectEqualStrings("string value, with any data except a \\n. an optional string length between the colons", first.fields[0].value.?.string);
    try std.testing.expectEqualStrings("this is a number", first.fields[1].key);
    try std.testing.expectEqual(@as(f64, 5), first.fields[1].value.?.number);
    try std.testing.expectEqualStrings("null value", first.fields[2].key);
    try std.testing.expect(first.fields[2].value == null);
    try std.testing.expectEqualStrings("array", first.fields[3].key);
    try std.testing.expectEqualStrings("array's don't exist. Use json or toml or something", first.fields[3].value.?.string);
    try std.testing.expectEqualStrings("data with newlines must have a length", first.fields[4].key);
    try std.testing.expectEqualStrings("foo\nbar", first.fields[4].value.?.string);
    try std.testing.expectEqualStrings("boolean value", first.fields[5].key);
    try std.testing.expect(!first.fields[5].value.?.boolean);

    const second = records.records[1];
    try std.testing.expectEqual(@as(usize, 5), second.fields.len);
    try std.testing.expectEqualStrings("key", second.fields[0].key);
    try std.testing.expectEqualStrings("this is the second record", second.fields[0].value.?.string);
    try std.testing.expectEqualStrings("this is a number", second.fields[1].key);
    try std.testing.expectEqual(@as(f64, 42), second.fields[1].value.?.number);
    try std.testing.expectEqualStrings("null value", second.fields[2].key);
    try std.testing.expect(second.fields[2].value == null);
    try std.testing.expectEqualStrings("array", second.fields[3].key);
    try std.testing.expectEqualStrings("array's still don't exist", second.fields[3].value.?.string);
    try std.testing.expectEqualStrings("data with newlines must have a length", second.fields[4].key);
    try std.testing.expectEqualStrings("single line", second.fields[4].value.?.string);
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
    try std.testing.expectEqual(@as(usize, 2), records.records.len);
    const first = records.records[0];
    try std.testing.expectEqual(@as(usize, 6), first.fields.len);
    try std.testing.expectEqualStrings("key", first.fields[0].key);
    try std.testing.expectEqualStrings("string value must have a length between colons or end with a comma", first.fields[0].value.?.string);
    try std.testing.expectEqualStrings("this is a number", first.fields[1].key);
    try std.testing.expectEqual(@as(f64, 5), first.fields[1].value.?.number);
    try std.testing.expectEqualStrings("null value", first.fields[2].key);
    try std.testing.expect(first.fields[2].value == null);
    try std.testing.expectEqualStrings("array", first.fields[3].key);
    try std.testing.expectEqualStrings("array's don't exist. Use json or toml or something", first.fields[3].value.?.string);
    try std.testing.expectEqualStrings("data with newlines must have a length", first.fields[4].key);
    try std.testing.expectEqualStrings("foo\nbar", first.fields[4].value.?.string);
    try std.testing.expectEqualStrings("boolean value", first.fields[5].key);
    try std.testing.expect(!first.fields[5].value.?.boolean);

    const second = records.records[1];
    try std.testing.expectEqual(@as(usize, 1), second.fields.len);
    try std.testing.expectEqualStrings("key", second.fields[0].key);
    try std.testing.expectEqualStrings("this is the second record", second.fields[0].value.?.string);
}
test "format all the things" {
    const records: []const Record = &.{
        .{ .fields = &.{
            .{ .key = "foo", .value = .{ .string = "bar" } },
            .{ .key = "foo", .value = null },
            .{ .key = "foo", .value = .{ .bytes = "bar" } },
            .{ .key = "foo", .value = .{ .number = 42 } },
        } },
        .{ .fields = &.{
            .{ .key = "foo", .value = .{ .string = "bar" } },
            .{ .key = "foo", .value = null },
            .{ .key = "foo", .value = .{ .bytes = "bar" } },
            .{ .key = "foo", .value = .{ .number = 42 } },
        } },
    };
    var buf: [1024]u8 = undefined;
    const formatted_eof = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(records, .{ .long_format = true, .emit_eof = true })},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\#!long
        \\#!requireeof
        \\foo::bar
        \\foo:null:
        \\foo:binary:YmFy
        \\foo:num:42
        \\
        \\foo::bar
        \\foo:null:
        \\foo:binary:YmFy
        \\foo:num:42
        \\#!eof
        \\
    , formatted_eof);

    const formatted = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(records, .{ .long_format = true })},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\#!long
        \\foo::bar
        \\foo:null:
        \\foo:binary:YmFy
        \\foo:num:42
        \\
        \\foo::bar
        \\foo:null:
        \\foo:binary:YmFy
        \\foo:num:42
        \\
    , formatted);

    // Round trip and make sure we get equivalent objects back
    var formatted_reader = std.Io.Reader.fixed(formatted);
    const parsed = try parse(&formatted_reader, std.testing.allocator, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(records, parsed.records);

    const compact = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(records, .{})},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42
        \\
    , compact);
    // Round trip and make sure we get equivalent objects back
    var compact_reader = std.Io.Reader.fixed(compact);
    const parsed_compact = try parse(&compact_reader, std.testing.allocator, .{});
    defer parsed_compact.deinit();
    try std.testing.expectEqualDeep(records, parsed_compact.records);

    const expected_expires: i64 = 1772589213;
    const compact_expires = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmt(records, .{ .expires = expected_expires })},
    );
    try std.testing.expectEqualStrings(
        \\#!srfv1
        \\#!expires=1772589213
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42
        \\
    , compact_expires);
    // Round trip and make sure we get equivalent objects back
    var expires_reader = std.Io.Reader.fixed(compact_expires);
    const parsed_expires = try parse(&expires_reader, std.testing.allocator, .{});
    defer parsed_expires.deinit();
    try std.testing.expectEqualDeep(records, parsed_expires.records);
    try std.testing.expectEqual(expected_expires, parsed_expires.expires.?);
}
test "serialize/deserialize" {
    const RecType = enum {
        foo,
        bar,
    };

    const Custom = struct {
        const Self = @This();
        pub fn srfParse(val: []const u8) !Self {
            if (std.mem.eql(u8, "hi", val)) return .{};
            return error.ValueNotEqualHi;
        }
        pub fn srfFormat(self: Self, allocator: std.mem.Allocator, comptime field_name: []const u8) !Value {
            _ = self;
            _ = field_name;
            return .{
                .string = try allocator.dupe(u8, "hi"),
            };
        }
    };

    const Data = struct {
        foo: []const u8,
        bar: u8,
        qux: ?RecType = .foo,
        b: bool = false,
        f: f32 = 4.2,
        custom: ?Custom = null,
    };

    const compact =
        \\#!srfv1
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42,qux::bar
        \\foo::bar,foo:null:,foo:binary:YmFy,foo:num:42,bar:num:42,qux::bar,b:bool:true,f:num:6.9,custom:string:hi
        \\
    ;
    // Round trip and make sure we get equivalent objects back
    var compact_reader = std.Io.Reader.fixed(compact);
    const parsed = try parse(&compact_reader, std.testing.allocator, .{});
    defer parsed.deinit();

    const rec1 = try parsed.records[0].to(Data);
    try std.testing.expectEqualStrings("bar", rec1.foo);
    try std.testing.expectEqual(@as(u8, 42), rec1.bar);
    try std.testing.expectEqual(@as(RecType, .foo), rec1.qux);
    const rec4 = try parsed.records[3].to(Data);
    try std.testing.expectEqualStrings("bar", rec4.foo);
    try std.testing.expectEqual(@as(u8, 42), rec4.bar);
    try std.testing.expectEqual(@as(RecType, .bar), rec4.qux.?);
    try std.testing.expectEqual(true, rec4.b);
    try std.testing.expectEqual(@as(f32, 6.9), rec4.f);

    // Now we'll do it with the iterator version
    var it_reader = std.Io.Reader.fixed(compact);
    const ri = try iterator(&it_reader, std.testing.allocator, .{});
    defer ri.deinit();
    const rec1_it = try (try ri.next()).?.to(Data);
    try std.testing.expectEqualStrings("bar", rec1_it.foo);
    try std.testing.expectEqual(@as(u8, 42), rec1_it.bar);
    try std.testing.expectEqual(@as(RecType, .foo), rec1_it.qux);
    _ = try ri.next();
    _ = try ri.next();
    const rec4_it = try (try ri.next()).?.to(Data);
    try std.testing.expectEqualStrings("bar", rec4_it.foo);
    try std.testing.expectEqual(@as(u8, 42), rec4_it.bar);
    try std.testing.expectEqual(@as(RecType, .bar), rec4_it.qux.?);
    try std.testing.expectEqual(true, rec4_it.b);
    try std.testing.expectEqual(@as(f32, 6.9), rec4_it.f);

    const alloc = std.testing.allocator;
    var owned_record_1 = try Record.from(Data, alloc, rec1);
    defer owned_record_1.deinit();
    const record_1 = try owned_record_1.record();
    try std.testing.expectEqual(@as(usize, 2), record_1.fields.len);
    var owned_record_4 = try Record.from(Data, alloc, rec4);
    defer owned_record_4.deinit();
    try std.testing.expectEqual(std.meta.fields(Data).len, owned_record_4.fields_buf.len);
    const record_4 = try owned_record_4.record();
    // const Data = struct {
    //     foo: []const u8,
    //     bar: u8,
    //     qux: ?RecType = .foo,
    //     b: bool = false,
    //     f: f32 = 4.2,
    //     custom: ?Custom = null,
    // };
    try std.testing.expectEqual(@as(usize, 6), record_4.fields.len);

    const all_data: []const Data = &.{
        .{ .foo = "hi", .bar = 42, .qux = .bar, .b = true, .f = 6.0, .custom = .{} },
        .{ .foo = "bar", .bar = 69 },
    };
    var buf: [4096]u8 = undefined;
    const compact_from = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmtFrom(Data, alloc, all_data, .{})},
    );

    const expect =
        \\#!srfv1
        \\foo::hi,bar:num:42,qux::bar,b:bool:true,f:num:6,custom::hi
        \\foo::bar,bar:num:69
        \\
    ;
    try std.testing.expectEqualStrings(expect, compact_from);
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
    const alloc = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    const compact_from = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmtFrom(MixedData, alloc, data, .{})},
    );
    const expect =
        \\#!srfv1
        \\active_tag::foo,number:num:42,true_or_false:bool:true
        \\active_tag::bar,sentence::foobar,decimal:num:6.9
        \\
    ;
    try std.testing.expectEqualStrings(expect, compact_from);

    var compact_reader = std.Io.Reader.fixed(expect);
    const parsed = try parse(&compact_reader, std.testing.allocator, .{});
    defer parsed.deinit();

    const rec1 = try parsed.records[0].to(MixedData);
    try std.testing.expectEqualDeep(data[0], rec1);
    const rec2 = try parsed.records[1].to(MixedData);
    try std.testing.expectEqualDeep(data[1], rec2);
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
    const Data2 = struct {
        data_type: Types = .bar,
        yo: u8,
    };

    const data: []const Data = &.{
        .{ .data_type = .foo, .yo = 42 },
        .{ .data_type = null, .yo = 69 },
    };
    const alloc = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    const compact_from = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{fmtFrom(Data, alloc, data, .{})},
    );
    const expect =
        \\#!srfv1
        \\data_type::foo,yo:num:42
        \\yo:num:69
        \\
    ;
    try std.testing.expectEqualStrings(expect, compact_from);

    var compact_reader = std.Io.Reader.fixed(expect);
    const parsed = try parse(&compact_reader, std.testing.allocator, .{});
    defer parsed.deinit();

    const rec1 = try parsed.records[0].to(Data);
    try std.testing.expectEqualDeep(data[0], rec1);
    const rec2 = try parsed.records[1].to(Data);
    try std.testing.expectEqualDeep(data[1], rec2);

    const missing_tag =
        \\#!srfv1
        \\yo:num:69
        \\
    ;
    var mt_reader = std.Io.Reader.fixed(missing_tag);
    const mt_parsed = try parse(&mt_reader, std.testing.allocator, .{});
    defer mt_parsed.deinit();
    const mt_rec1 = try mt_parsed.records[0].to(Data);
    try std.testing.expect(mt_rec1.data_type == null);

    const mt_rec1_dt2 = try mt_parsed.records[0].to(Data2);
    try std.testing.expect(mt_rec1_dt2.data_type == .bar);
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
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    const records = try parse(&reader, allocator, .{});
    defer records.deinit();
    try std.testing.expectEqual(@as(usize, 1), records.records.len);
    const rec = records.records[0];
    try std.testing.expectEqual(@as(usize, 2), rec.fields.len);
    try std.testing.expectEqualStrings("name", rec.fields[0].key);
    try std.testing.expectEqualStrings("alice", rec.fields[0].value.?.string);
    try std.testing.expectEqualStrings("desc", rec.fields[1].key);
    try std.testing.expectEqualStrings("world", rec.fields[1].value.?.string);
}
test "iterator" {
    // When a length-prefixed value is the last field on the line,
    // rest_of_data.len == size exactly. The check on line 216 uses
    // strict > instead of >=, falling through to the multi-line path
    // where size - rest_of_data.len - 1 underflows.
    const data =
        \\#!srfv1
        \\name::alice,desc:5:world
    ;
    const allocator = std.testing.allocator;
    var reader = std.Io.Reader.fixed(data);
    var ri = try iterator(&reader, allocator, .{});
    defer ri.deinit();

    const nfi = try ri.next();
    try std.testing.expect(nfi != null);
    const fi = nfi.?;
    // defer fi.deinit();
    const field1 = try fi.next();
    try std.testing.expect(field1 != null);
    try std.testing.expectEqualStrings("name", field1.?.key);
    try std.testing.expectEqualStrings("alice", field1.?.value.?.string);
    const field2 = try fi.next();
    try std.testing.expect(field2 != null);
    try std.testing.expectEqualStrings("desc", field2.?.key);
    try std.testing.expectEqualStrings("world", field2.?.value.?.string);
    const field3 = try fi.next();
    try std.testing.expect(field3 == null);

    const next = try ri.next();
    try std.testing.expect(next == null);
}
