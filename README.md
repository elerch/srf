# SRF (Simple Record Format)

SRF is a minimal data format designed for L2 caches and simple structured storage suitable for simple configuration as well. It provides human-readable key-value records with basic type hints, while avoiding the parsing complexity and escaping requirements of JSON. Current benchmarking with hyperfine demonstrate approximately twice the performance of JSON parsing, though for L2 caches, JSON may be a poor choice. Compared to jsonl, it is approximately 40x faster. Performance also improves by 8% if you instruct the library not to copy strings around (ParseOptions alloc_strings = false).

**Features:**
- No escaping required - use length-prefixed strings for complex data
- Single-pass streaming parser with minimal memory allocation
- Basic type system (string, num, bool, null, binary) with explicit type hints
- Compact format for machine generation, long format for human editing
- Built-in corruption detection with optional EOF markers
- Iterator-based API for zero-copy, low-allocation streaming
- Comptime type coercion directly from the iterator (no intermediate collections)

**When to use SRF:**
- L2 caches that need occasional human inspection
- Simple configuration files with mixed data types
- Data exchange where JSON escaping is problematic
- Applications requiring fast, predictable parsing

**When not to use SRF:**
- Complex nested data structures (use JSON/TOML instead)
- Schema validation requirements
- Arrays or object hierarchies (arrays can be managed in the data itself, however)

## Parsing API

SRF provides two parsing APIs. The **iterator API is preferred** for most use cases
as it avoids collecting all records and fields into memory at once.

### Iterator (preferred)

The `iterator` function returns a `RecordIterator` that streams records lazily.
Each call to `RecordIterator.next` yields a `FieldIterator` for the next record,
and each call to `FieldIterator.next` yields individual `Field` values. No
intermediate slices or ArrayLists are allocated -- fields are yielded one at a
time directly from the parser state.

For type coercion, `FieldIterator.to(T)` consumes the remaining fields in the
current record and maps them into a Zig struct or tagged union at comptime,
with zero additional allocations beyond what field parsing itself requires. This
can further be minimized with the parsing option `.alloc_strings = false`.

```zig
const srf = @import("srf");

const Data = struct {
    name: []const u8,
    age: u8,
    active: bool = false,
};

var reader = std.Io.Reader.fixed(raw_data);
var ri = try srf.iterator(&reader, allocator, .{});
defer ri.deinit();

while (try ri.next()) |fi| {
    const record = try fi.to(Data);
    // process record...
}
```

### Batch parse

The `parse` function collects all records into memory at once, returning a
`Parsed` struct with a `records: []Record` slice. This is built on top of
the iterator internally. It is convenient when you need random access to all
records, but costs more memory since every field is collected into ArrayLists
before being converted to owned slices.

```zig
const srf = @import("srf");

var reader = std.Io.Reader.fixed(raw_data);
const parsed = try srf.parse(&reader, allocator, .{});
defer parsed.deinit();

for (parsed.records) |record| {
    const data = try record.to(Data);
    // process data...
}
```

## Data Formats

### Long format

Long format uses newlines to delimit fields and blank lines to separate records.
It is human-friendly and suitable for hand-edited configuration files.

```
#!srfv1 # mandatory comment with format and version. Parser instructions start with #!
#!requireeof # Set this if you want parsing to fail when #!eof not present on last line
#!long # Mandatory to use multiline records, compact format is optional #!compact
# A comment
# empty lines ignored

key::string value, with any data except a \n. an optional string length between the colons
this is a number:num: 5
null value:null:
array::array's don't exist. Use json or toml or something
data with newlines must have a length:7:foo
bar
boolean value:bool:false

  # Empty line separates records, but comments don't count as empty
key::this is the second record
this is a number:num:42
null value:null:
array::array's still don't exist
data with newlines must have a length::single line
#!eof # eof marker, useful to make sure your file wasn't cut in half. Only considered if requireeof set at top
```

### Compact format

Compact format uses commas to delimit fields and newlines to separate records.
It is designed for machine generation where space efficiency matters.

```
#!srfv1 # mandatory comment with format and version. Parser instructions start with #!
key::string value must have a length between colons or end with a comma,this is a number:num:5 ,null value:null:,array::array's don't exist. Use json or toml or something,data with newlines must have a length:7:foo
bar,boolean value:bool:false
key::this is the second record
```

## Serialization

SRF supports serializing Zig structs, unions, and enums back to SRF format.
Use `Record.from` to create a record from a typed value, or `fmtFrom` to
format a slice of values directly to a writer.

```zig
const srf = @import("srf");

const all_data: []const Data = &.{
    .{ .name = "alice", .age = 30, .active = true },
    .{ .name = "bob", .age = 25 },
};
var buf: [4096]u8 = undefined;
const formatted = try std.fmt.bufPrint(&buf, "{f}", .{
    srf.fmtFrom(Data, allocator, all_data, .{ .long_format = true }),
});
```

## Type System

Fields follow the format `key:type_hint:value`:

| Type                   | Hint                  | Example                 |
|------------------------|-----------------------|-------------------------|
| String                 | *(empty)* or `string` | `name::alice`           |
| Number (internally f64)| `num`                 | `age:num:30`            |
| Boolean                | `bool`                | `active:bool:true`      |
| Null                   | `null`                | `missing:null:`         |
| Binary                 | `binary`              | `data:binary:base64...` |
| Length-prefixed string | *(byte count)*        | `bio:12:hello\nworld!`  |

## Directives

Directives are parser instructions that appear at the top of an SRF file. They
use the `#!` prefix and must appear before any data records (except `#!eof`,
which marks the end of data). Inline comments are allowed after directives.
Unrecognized directives are silently ignored for forward compatibility.

| Directive                  | Parameters       | Description                                          |
|----------------------------|------------------|------------------------------------------------------|
| `#!srfv1`                  | none             | Magic header identifying the file as SRF version 1   |
| `#!long`                   | none             | Select long format (newline-delimited fields)         |
| `#!compact`                | none             | Select compact format (comma-delimited fields)        |
| `#!requireeof`             | none             | Require `#!eof` marker or parsing fails               |
| `#!eof`                    | none             | End-of-file marker for corruption detection           |
| `#!expires=<unix_ts>`      | `i64` timestamp  | Cache expiration time (checked via `isFresh()`)       |
| `#!created=<unix_ts>`      | `i64` timestamp  | Data creation timestamp (metadata only)               |
| `#!modified=<unix_ts>`     | `i64` timestamp  | Data modification timestamp (metadata only)           |

### `#!srfv1`

Mandatory magic header that must appear on the very first line of every SRF
file. Identifies the file format and version. A missing header causes a parse
error; duplicates are also rejected.

### `#!long`

Selects long format mode where fields are delimited by newlines and records are
separated by blank lines. Suitable for hand-edited configuration files. Mutually
exclusive with `#!compact`.

### `#!compact`

Selects compact format mode where fields are delimited by commas and records are
separated by newlines. This is the default format, so the directive is optional.
Designed for machine generation where space efficiency matters.

### `#!requireeof`

When present, parsing will fail if the `#!eof` marker is not found at the end of
the file. This is a corruption detection mechanism to ensure the file was not
truncated during a write.

### `#!eof`

Marks the end of SRF data. Any data appearing after this directive causes a
parse error. Can appear in the header (indicating an empty file) or after data
records. Paired with `#!requireeof` for corruption detection.

### `#!expires=<unix_timestamp>`

Sets a cache expiration timestamp. The value is a Unix timestamp (seconds since
epoch) as an `i64`. The `RecordIterator.isFresh()` method checks this against
the current time. Data is always returned regardless of freshness -- callers
decide whether to use stale data.

```
#!srfv1
#!expires=1772589213
key::cached_value
```

### `#!created=<unix_timestamp>`

Records when the data was created. The value is a Unix timestamp as an `i64`.
This is metadata only -- the library tracks it but takes no action on it.
Available on the iterator/parsed result immediately after construction.

### `#!modified=<unix_timestamp>`

Records when the data was last modified. The value is a Unix timestamp as an
`i64`. Like `#!created`, this is metadata only and is available on the
iterator/parsed result after construction.

### Example with multiple directives

```
#!srfv1
#!requireeof
#!long
#!expires=1772589213
#!created=1772500000
name::alice
age:num:30

name::bob
age:num:25
#!eof
```

## Implementation Concerns

**Parser robustness:**
- Integer overflow: Length parsing could overflow on malformed input - need bounds checking
- Memory exhaustion: Malicious length values could cause huge allocations before you realize the data isn't there
- Partial reads: What happens if you read a length but the actual data is truncated?
- Type coercion edge cases: How do you handle "5.0" for num type, or "TRUE" vs "true" for bool?

**Format specification:**
- Zero-length keys are invalid
- Key collisions are allowed - second occurrence overwrites the first
- Whitespace is significant and preserved in values
- Length-prefixed strings are bags of bytes
- Binary type uses base64 encoding for binary data
- Empty keys: Zero-length keys (`::value`) are invalid
- Trailing separators are invalid in both formats (e.g., `key:val,` or extra newlines beyond record separators)

**Cache-specific issues:**
- Corruption detection: Beyond #!eof, partial writes mid-record detection is an outstanding issue
- Version compatibility: Decision should be made by library consumer (ignore or delete/recreate)
- Record limits: No limits on record size or field count - handled by library consumer
- Extra fields: When consumer provides struct, should extra fields in file be ignored or error? (configuration option, default to error)

**Stream parsing compatibility:**
- Format designed to support stream parsing
- Hash directive (#!hash) question relates to streaming support

**Error handling:**
- Clear error types needed for different parse failure modes
- Distinguish between format errors, data errors, and I/O errors

## AI Use

AI was used in this project for comments, parts of the README, benchmarking code,
build.zig and unit test generation. All other code is human generated.
