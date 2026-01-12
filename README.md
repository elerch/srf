# SRF (Simple Record Format)

SRF is a minimal data format designed for L2 caches and simple structured storage suitable for simple configuration as well. It provides human-readable key-value records with basic type hints, while avoiding the parsing complexity and escaping requirements of JSON.

**Features:**
- No escaping required - use length-prefixed strings for complex data
- Single-pass parsing with minimal memory allocation
- Basic type system (string, num, bool, null, binary) with explicit type hints
- Compact format for machine generation, long format for human editing
- Built-in corruption detection with optional EOF markers

**When to use SRF:**
- L2 caches that need occasional human inspection
- Simple configuration files with mixed data types
- Data exchange where JSON escaping is problematic
- Applications requiring fast, predictable parsing

**When not to use SRF:**
- Complex nested data structures (use JSON/TOML instead)
- Schema validation requirements
- Arrays or object hierarchies (arrays can be managed in the data itself, however)

Long format:

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
  # Empty line separates records
key::this is the second record
this is a number:num:42 
null value:null:
array::array's still don't exist
data with newlines must have a length::single line
#!eof # eof marker, useful to make sure your file wasn't cut in half. Only considered if requireeof set at top
```

compact format:
```
#!srfv1 # mandatory comment with format and version. Parser instructions start with #!
key::string value must have a length between colons or end with a comma,this is a number:num:5 ,null value:null:,array::array's don't exist. Use json or toml or something,data with newlines must have a length:7:foo
bar,boolean value:bool:false
key::this is the second record
```

Second record problem...these

## Implementation

**Note:** Long format may be tabled for later development. Initial implementation will focus on compact format only.

 Unrecognized `#!<keyword>` should be an error:
  requireof -> requireeof will probably be a common problem.
#! anywhere other than the beginning or end is an error

newline separates records in compact format. An empty line is required in long format

comma separates fields in compact format
newline separates fields in long format

Should we have a #!hash directive to include all data not starting with `#!` ?

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
