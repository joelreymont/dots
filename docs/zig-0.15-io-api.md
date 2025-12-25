# Zig 0.15 API Reference

## Comptime for Performance

Use `comptime` aggressively for zero-cost abstractions:

### Comptime Lookup Tables
```zig
// Generate character class lookup at compile time
const char_class = comptime blk: {
    var table: [256]CharType = .{.invalid} ** 256;
    for ('a'..='z') |c| table[c] = .alpha;
    for ('A'..='Z') |c| table[c] = .alpha;
    for ('0'..='9') |c| table[c] = .digit;
    break :blk table;
};

// Usage - single array lookup instead of branching
fn classifyChar(c: u8) CharType {
    return char_class[c];
}
```

### Comptime Type Generation
```zig
fn Instruction(comptime fields: []const Field) type {
    return packed struct {
        // Generate fields at compile time
        // ...
    };
}
```

### Comptime vs Runtime Branching
```zig
// BAD - runtime check on every call
fn encode(comptime big_endian: bool, value: u32) [4]u8 {
    if (big_endian) { ... } else { ... }  // evaluated at compile time!
}

// Comptime parameter eliminates dead branch at compile time
// Both versions exist as separate functions
```

### Force Inlining for Hot Paths
```zig
inline fn decodeFast(bytes: []const u8) u32 {
    // Compiler MUST inline - no function call overhead
}
```

### Comptime String Operations
```zig
// BAD - runtime format
const msg = std.fmt.allocPrint(alloc, "error: {s}", .{name});

// GOOD - comptime format validation, but still runtime allocation
const msg = try std.fmt.allocPrint(alloc, "error: {s}", .{name});

// BEST - comptime when possible
const msg = comptime std.fmt.comptimePrint("error: {s}", .{"known"});
```

### Comptime State Machines
```zig
// Generate DFA transition table at compile time from regex
const dfa = comptime buildDFA("identifier|number|string");

fn lex(input: []const u8) Token {
    var state: u8 = 0;
    for (input) |c| {
        state = dfa.transition[state][c];  // single lookup
    }
    return dfa.accept[state];
}
```

## CRITICAL: ArrayList is Unmanaged

In Zig 0.15, `std.ArrayList(T)` no longer stores an allocator. You MUST pass the allocator to every method.

```zig
// OLD (pre-0.15) - WRONG:
var list = std.ArrayList(T).init(allocator);
try list.append(item);
const slice = list.toOwnedSlice();
list.deinit();

// NEW (0.15) - CORRECT:
var list = std.ArrayList(T){};  // or: var list: std.ArrayList(T) = .{};
try list.append(allocator, item);
const slice = try list.toOwnedSlice(allocator);
list.deinit(allocator);
```

## ArrayList Method Signatures (0.15)

| Method | Old | New |
|--------|-----|-----|
| init | `.init(alloc)` | `{}` or `.{}` |
| append | `.append(item)` | `.append(alloc, item)` |
| appendSlice | `.appendSlice(items)` | `.appendSlice(alloc, items)` |
| pop | `.pop()` | `.pop()` (no change) |
| toOwnedSlice | `.toOwnedSlice()` | `.toOwnedSlice(alloc)` |
| deinit | `.deinit()` | `.deinit(alloc)` |
| items | `.items` | `.items` (no change) |

## StringHashMap - Still Managed

`std.StringHashMap(V)` still uses `.init(allocator)` - it's managed.

```zig
var map = std.StringHashMap([]const u8).init(allocator);
defer map.deinit();
try map.put(key, value);
```

## I/O Changes

## stdout Pattern

```zig
const std = @import("std");
const fs = std.fs;

pub fn main() !void {
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;  // std.Io.Writer

    try w.print("Hello {s}\n", .{"world"});
    try w.writeAll("raw bytes");
    try w.writeByte('x');
    try w.flush();
}
```

## File.Writer Structure

```zig
pub const Writer = struct {
    file: File,
    err: ?WriteError = null,
    interface: std.Io.Writer,  // <-- use this for print/writeAll
    // ...
};
```

## std.Io.Writer Methods

| Method | Signature | Notes |
|--------|-----------|-------|
| `print` | `fn(*Writer, comptime []const u8, anytype) Error!void` | Formatted output |
| `writeAll` | `fn(*Writer, []const u8) Error!void` | Write all bytes |
| `writeByte` | `fn(*Writer, u8) Error!void` | Single byte |
| `write` | `fn(*Writer, []const u8) Error!usize` | Partial write OK |
| `flush` | `fn(*Writer) Error!void` | Drain buffer |

## No writeByteNTimes - Use Loop

```zig
fn writeByteNTimes(w: *std.Io.Writer, byte: u8, n: usize) !void {
    for (0..n) |_| try w.writeByte(byte);
}
```

## ArrayList Changes

```zig
// Old (pre-0.15):
var list = std.ArrayList(T).init(allocator);
try list.append(item);
list.deinit();

// New (0.15):
var list = std.ArrayList(T){};  // or .empty
try list.append(allocator, item);  // allocator passed to methods
list.deinit(allocator);
```

## ArrayListUnmanaged

Same API as new ArrayList - they're now equivalent.

## File Reading

```zig
const file = try fs.openFileAbsolute(path, .{});
defer file.close();
const content = try file.readToEndAlloc(allocator, max_size);
defer allocator.free(content);
```

## File.Reader (buffered line reading)

```zig
const file = try fs.openFileAbsolute(path, .{});
defer file.close();

var read_buf: [64 * 1024]u8 = undefined;
var file_reader = fs.File.Reader.init(file, &read_buf);
const reader = &file_reader.interface;

while (true) {
    const line = reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            _ = reader.discardDelimiterExclusive('\n') catch break;
            continue;
        },
        error.ReadFailed => break,
    } orelse break;
    // process line...
}
```

## Threading with ArenaAllocator

```zig
// Per-thread arena to avoid allocator contention
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();
// allocator.free() is a no-op - arena frees all at once

// Atomic work stealing
var work_index = std.atomic.Value(usize).init(0);
const idx = work_index.fetchAdd(1, .monotonic);
```

## JSON Parsing

```zig
const parsed = try std.json.parseFromSlice(
    std.json.Value,
    allocator,
    json_string,
    .{}
);
defer parsed.deinit();
const obj = parsed.value.object;
```
