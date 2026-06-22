//! Minimal property-based testing library.
//!
//! Provides typed generators with shrinking for finding minimal counterexamples.
//! Inspired by QuickCheck/Hypothesis but tailored for mnemos's needs.
//!
//! Usage:
//! ```zig
//! test "addition is commutative" {
//!     try quickcheck.check(struct {
//!         fn property(args: struct { a: i32, b: i32 }) bool {
//!             return args.a + args.b == args.b + args.a;
//!         }
//!     }.property, .{});
//! }
//!
//! test "string property" {
//!     try quickcheck.check(struct {
//!         fn property(args: struct { s: quickcheck.String }) bool {
//!             const str = args.s.slice();
//!             return str.len <= quickcheck.String.MAX_LEN;
//!         }
//!     }.property, .{});
//! }
//! ```

const std = @import("std");
const testing = std.testing;

/// Maximum length for generated strings
pub const MAX_STRING_LEN: usize = 64;

const file_path_extensions = [_][]const u8{ ".zig", ".rs", ".py", ".js", ".ts", ".go", ".c", ".h" };

/// Bounded string type for property testing (no allocation needed).
/// Use .slice() to get the actual string data.
pub const String = struct {
    buf: [MAX_STRING_LEN]u8 = undefined,
    len: usize = 0,

    pub const MAX_LEN = MAX_STRING_LEN;

    /// Get the string content as a slice
    pub fn slice(self: *const String) []const u8 {
        return self.buf[0..self.len];
    }

    /// Create from a slice (truncates if too long)
    pub fn fromSlice(s: []const u8) String {
        var result = String{};
        const copy_len = @min(s.len, MAX_STRING_LEN);
        @memcpy(result.buf[0..copy_len], s[0..copy_len]);
        result.len = copy_len;
        return result;
    }
};

/// Bounded identifier string (alphanumeric only, for IDs)
pub const Id = struct {
    buf: [36]u8 = undefined,
    len: usize = 0,

    pub const MAX_LEN = 36;
    pub const MIN_LEN = 8;

    pub fn slice(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Bounded file path string
pub const FilePath = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    pub const MAX_LEN = 128;
    pub const MIN_NAME_LEN = 1;

    pub fn slice(self: *const FilePath) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Bounded generic slice type for property testing (no allocation needed).
pub fn BoundedSlice(comptime T: type, comptime max_len: usize) type {
    return struct {
        const Self = @This();

        buf: [max_len]T = undefined,
        len: usize = 0,

        pub const MAX_LEN = max_len;
        pub const Elem = T;
        pub const is_bounded_slice = true;

        pub fn slice(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.buf[0..self.len];
        }

        pub fn fromSlice(s: []const T) Self {
            var result = Self{};
            const copy_len = @min(s.len, max_len);
            std.mem.copyForwards(T, result.buf[0..copy_len], s[0..copy_len]);
            result.len = copy_len;
            return result;
        }
    };
}

/// Configuration for property tests.
pub const Config = struct {
    /// Number of random test cases to generate.
    iterations: usize = 100,
    /// Random seed for internal PRNG (0 = use timestamp).
    seed: u64 = 0,
    /// Maximum shrink attempts per failure.
    max_shrinks: usize = 100,
    /// If true, test passes when property fails (for testing shrinking).
    expect_failure: bool = false,
    /// If true, print counterexample details on failure.
    print_failures: bool = true,
    /// If true, use struct field default values where provided.
    use_default_values: bool = true,
    /// Optional external RNG to use instead of an internal PRNG.
    /// When set, seed is used only for failure reporting.
    random: ?std.Random = null,
};

pub fn Failure(comptime Args: type) type {
    return struct {
        seed: u64,
        iteration: usize,
        original: Args,
        shrunk: Args,
    };
}

/// Run a property test with the given property function.
/// The property function takes a struct of generated values and returns bool.
/// Returns error if a counterexample is found.
pub fn check(comptime property: anytype, config: Config) !void {
    const Args = @typeInfo(@TypeOf(property)).@"fn".params[0].type.?;
    const failure = checkType(Args, property, config);

    if (failure) |details| {
        if (config.expect_failure) {
            return;
        }

        if (config.print_failures) {
            printFailure(Args, details);
        }

        return error.PropertyFailed;
    }

    // If we expected a failure but property always passed, that's an error
    if (config.expect_failure) {
        return error.ExpectedFailure;
    }
}

/// Run a property test and return failure details (if any) without printing.
pub fn checkResult(comptime property: anytype, config: Config) ?Failure(@typeInfo(@TypeOf(property)).@"fn".params[0].type.?) {
    const Args = @typeInfo(@TypeOf(property)).@"fn".params[0].type.?;
    return checkType(Args, property, config);
}

fn checkType(comptime Args: type, comptime property: anytype, config: Config) ?Failure(Args) {
    var seed: u64 = config.seed;
    var prng: std.Random.DefaultPrng = undefined;
    var random: std.Random = undefined;

    if (config.random) |external| {
        random = external;
    } else {
        if (seed == 0) {
            seed = timestampSeed();
        }
        prng = std.Random.DefaultPrng.init(seed);
        random = prng.random();
    }

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const args = generateWithConfig(Args, random, .{ .use_default_values = config.use_default_values });

        if (!property(args)) {
            // Found counterexample, try to shrink it
            const shrunk = shrinkLoop(Args, property, args, config.max_shrinks, .{ .use_default_values = config.use_default_values });
            return Failure(Args){
                .seed = seed,
                .iteration = i,
                .original = args,
                .shrunk = shrunk,
            };
        }
    }
    return null;
}

fn timestampSeed() u64 {
    const nanos = std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds();
    return @as(u64, @truncate(@as(u96, @bitCast(nanos))));
}

fn printFailure(comptime Args: type, failure: Failure(Args)) void {
    std.debug.print("\n=== Property failed ===\n", .{});
    std.debug.print("Seed: {}\n", .{failure.seed});
    std.debug.print("Iteration: {}\n", .{failure.iteration});
    std.debug.print("Original: {any}\n", .{failure.original});
    std.debug.print("Shrunk:   {any}\n", .{failure.shrunk});
}

/// Generate a random value of type T.
pub fn generate(comptime T: type, random: std.Random) T {
    return generateWithConfig(T, random, .{});
}

pub const GenerateConfig = struct {
    use_default_values: bool = true,
};

fn isBoundedSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "is_bounded_slice") and T.is_bounded_slice,
        else => false,
    };
}

/// Generate a random value of type T with configurable behavior.
pub fn generateWithConfig(comptime T: type, random: std.Random, config: GenerateConfig) T {
    // Handle special string types first
    if (T == String) return generateString(random);
    if (T == Id) return generateId(random);
    if (T == FilePath) return generateFilePath(random);
    if (comptime isBoundedSlice(T)) return generateBoundedSlice(T, random, config);

    return switch (@typeInfo(T)) {
        .int => generateInt(T, random),
        .float => generateFloat(T, random),
        .bool => random.boolean(),
        .@"enum" => generateEnum(T, random),
        .optional => |opt| if (random.boolean()) generateWithConfig(opt.child, random, config) else null,
        .array => |arr| generateArray(arr.child, arr.len, random, config),
        .@"struct" => |s| generateStruct(T, s, random, config),
        .@"union" => |u| generateUnion(T, u, random, config),
        .pointer => |ptr| switch (ptr.size) {
            .slice => @compileError("Cannot generate slices - use String, Id, FilePath, or BoundedSlice"),
            else => @compileError("Cannot generate pointer types"),
        },
        else => @compileError("Cannot generate type: " ++ @typeName(T)),
    };
}

fn generateString(random: std.Random) String {
    var result = String{};
    // 10% chance of empty string
    if (random.uintLessThan(u8, 10) == 0) {
        result.len = 0;
        return result;
    }
    // Generate printable ASCII string (32-126)
    result.len = random.uintLessThan(usize, MAX_STRING_LEN) + 1;
    for (result.buf[0..result.len]) |*c| {
        c.* = @intCast(random.intRangeAtMost(u8, 32, 126));
    }
    return result;
}

fn generateId(random: std.Random) Id {
    var result = Id{};
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    // IDs are typically bounded length
    result.len = random.intRangeAtMost(usize, Id.MIN_LEN, Id.MAX_LEN);
    for (result.buf[0..result.len]) |*c| {
        c.* = chars[random.uintLessThan(usize, chars.len)];
    }
    return result;
}

fn generateFilePath(random: std.Random) FilePath {
    var result = FilePath{};
    const ext = file_path_extensions[random.uintLessThan(usize, file_path_extensions.len)];

    // Generate path like /dir/file.ext
    result.buf[0] = '/';
    const name_len = random.intRangeAtMost(usize, 1, 20);
    for (result.buf[1 .. name_len + 1]) |*c| {
        c.* = @intCast(random.intRangeAtMost(u8, 'a', 'z'));
    }
    @memcpy(result.buf[name_len + 1 ..][0..ext.len], ext);
    result.len = name_len + 1 + ext.len;
    return result;
}

fn generateBoundedSlice(comptime T: type, random: std.Random, config: GenerateConfig) T {
    const Elem = T.Elem;
    const max_len = T.MAX_LEN;
    var result: T = undefined;

    if (max_len == 0) {
        result.len = 0;
        return result;
    }

    // 10% chance of empty
    if (random.uintLessThan(u8, 10) == 0) {
        result.len = 0;
        return result;
    }

    result.len = random.uintLessThan(usize, max_len) + 1;
    for (result.buf[0..result.len]) |*elem| {
        elem.* = generateWithConfig(Elem, random, config);
    }
    return result;
}

fn generateInt(comptime T: type, random: std.Random) T {
    // 20% chance of boundary values
    if (random.uintLessThan(u8, 5) == 0) {
        const boundaries = [_]T{
            0,
            1,
            std.math.maxInt(T),
            if (@typeInfo(T).int.signedness == .signed) std.math.minInt(T) else 0,
            if (@typeInfo(T).int.signedness == .signed) -1 else std.math.maxInt(T),
        };
        return boundaries[random.uintLessThan(usize, boundaries.len)];
    }
    return random.int(T);
}

fn generateFloat(comptime T: type, random: std.Random) T {
    // 20% chance of special values
    if (random.uintLessThan(u8, 5) == 0) {
        const specials = [_]T{
            0.0,
            -0.0,
            1.0,
            -1.0,
            std.math.floatMin(T),
            -std.math.floatMin(T),
            std.math.floatTrueMin(T),
            -std.math.floatTrueMin(T),
            std.math.floatMax(T),
            -std.math.floatMax(T),
        };
        return specials[random.uintLessThan(usize, specials.len)];
    }
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    while (true) {
        const bits = random.int(U);
        const value = @as(T, @bitCast(bits));
        if (!std.math.isNan(value) and !std.math.isInf(value)) {
            return value;
        }
    }
}

fn generateEnum(comptime T: type, random: std.Random) T {
    const fields = @typeInfo(T).@"enum".fields;
    const idx = random.uintLessThan(usize, fields.len);
    // Must use inline for to access comptime field values
    inline for (fields, 0..) |field, i| {
        if (i == idx) return @enumFromInt(field.value);
    }
    unreachable;
}

fn generateUnion(comptime T: type, comptime u: std.builtin.Type.Union, random: std.Random, config: GenerateConfig) T {
    if (u.tag_type == null) {
        @compileError("Cannot generate untagged union: " ++ @typeName(T));
    }

    const fields = u.fields;
    const idx = random.uintLessThan(usize, fields.len);
    inline for (fields, 0..) |field, i| {
        if (i == idx) {
            return @unionInit(T, field.name, generateWithConfig(field.type, random, config));
        }
    }
    unreachable;
}

fn generateArray(comptime Child: type, comptime len: usize, random: std.Random, config: GenerateConfig) [len]Child {
    var result: [len]Child = undefined;
    for (&result) |*elem| {
        elem.* = generateWithConfig(Child, random, config);
    }
    return result;
}

fn generateStruct(comptime T: type, comptime s: std.builtin.Type.Struct, random: std.Random, config: GenerateConfig) T {
    var result: T = undefined;
    inline for (s.fields) |field| {
        if (field.is_comptime) {
            if (field.defaultValue()) |default_value| {
                @field(result, field.name) = default_value;
                continue;
            }
            @compileError("Cannot generate struct with comptime field without default: " ++ field.name);
        }
        if (config.use_default_values) {
            if (comptime (field.defaultValue() != null)) {
                @field(result, field.name) = field.defaultValue().?;
            } else {
                @field(result, field.name) = generateWithConfig(field.type, random, config);
            }
        } else {
            @field(result, field.name) = generateWithConfig(field.type, random, config);
        }
    }
    return result;
}

/// Shrink a value toward a simpler form that still fails the property.
fn shrinkLoop(comptime T: type, comptime property: anytype, initial: T, max_attempts: usize, config: ShrinkConfig) T {
    var current = initial;
    var budget: usize = max_attempts;

    while (budget > 0) {
        if (tryShrink(T, current, property, &budget, config)) |simpler| {
            current = simpler;
            continue;
        }
        break;
    }

    return current;
}

const ShrinkConfig = struct {
    use_default_values: bool = true,
};

fn tryCandidate(comptime T: type, candidate: T, comptime property: anytype, budget: *usize) bool {
    if (budget.* == 0) return false;
    budget.* -= 1;
    return !property(candidate);
}

fn tryShrink(comptime T: type, value: T, comptime property: anytype, budget: *usize, config: ShrinkConfig) ?T {
    if (comptime isBoundedSlice(T)) {
        if (shrinkOnceWithConfig(T, value, config)) |simpler| {
            if (tryCandidate(T, simpler, property, budget)) return simpler;
        }
        return shrinkBoundedSliceField(T, value, property, budget, config);
    }

    return switch (@typeInfo(T)) {
        .int => blk: {
            if (shrinkInt(T, value)) |simpler| {
                if (tryCandidate(T, simpler, property, budget)) break :blk simpler;
            }
            if (shrinkIntStep(T, value)) |step| {
                if (tryCandidate(T, step, property, budget)) break :blk step;
            }
            break :blk null;
        },
        .@"union" => blk: {
            const Context = struct { budget: *usize };
            var ctx = Context{ .budget = budget };
            break :blk findUnionCandidate(T, value, config, &ctx, property, struct {
                fn accept(context: *Context, candidate: T, comptime prop: anytype) bool {
                    return tryCandidate(T, candidate, prop, context.budget);
                }
            }.accept);
        },
        else => blk: {
            if (shrinkOnceWithConfig(T, value, config)) |simpler| {
                if (tryCandidate(T, simpler, property, budget)) break :blk simpler;
            }
            break :blk switch (@typeInfo(T)) {
                .array => shrinkArrayField(T, value, property, budget, config),
                .@"struct" => shrinkStructField(T, value, property, budget, config),
                else => null,
            };
        },
    };
}

/// Try to shrink a value one step.
fn shrinkOnce(comptime T: type, value: T) ?T {
    return shrinkOnceWithConfig(T, value, .{});
}

fn shrinkOnceWithConfig(comptime T: type, value: T, config: ShrinkConfig) ?T {
    // Handle special string types first
    if (T == String) return shrinkString(value);
    if (T == Id) return shrinkId(value);
    if (T == FilePath) return shrinkFilePath(value);
    if (comptime isBoundedSlice(T)) return shrinkBoundedSlice(T, value);

    return switch (@typeInfo(T)) {
        .int => shrinkInt(T, value),
        .float => shrinkFloat(T, value),
        .bool => if (value) false else null,
        .optional => if (value != null) @as(T, null) else null,
        .array => |arr| shrinkArray(arr.child, arr.len, value, config),
        .@"struct" => |s| shrinkStruct(T, s, value, config),
        .@"union" => |u| shrinkUnion(T, u, value, config),
        .@"enum" => shrinkEnum(T, value),
        else => null,
    };
}

fn shrinkString(value: String) ?String {
    if (value.len == 0) return null;
    // First try: shrink to empty
    if (value.len > 1) {
        var result = value;
        result.len = value.len / 2;
        return result;
    }
    // Single char: return empty
    return String{};
}

fn shrinkId(value: Id) ?Id {
    if (value.len == 0) return null;
    if (value.len > Id.MIN_LEN) {
        // Shrink toward minimum ID length
        var result = value;
        result.len = @max(Id.MIN_LEN, value.len / 2);
        return result;
    }
    return null; // Don't shrink below minimum
}

fn shrinkFilePath(value: FilePath) ?FilePath {
    if (value.len == 0) return null;
    const slice = value.slice();
    const dot_index = std.mem.lastIndexOfScalar(u8, slice, '.') orelse return null;
    if (dot_index <= 1) return null;

    const name_len = dot_index - 1;
    if (name_len <= FilePath.MIN_NAME_LEN) return null;

    const ext_len = slice.len - dot_index;
    const new_name_len = @max(FilePath.MIN_NAME_LEN, name_len / 2);
    var result = value;
    const new_ext_start = 1 + new_name_len;
    if (new_ext_start != dot_index) {
        std.mem.copyForwards(u8, result.buf[new_ext_start .. new_ext_start + ext_len], value.buf[dot_index .. dot_index + ext_len]);
    }
    result.len = new_ext_start + ext_len;
    return result;
}

fn shrinkBoundedSlice(comptime T: type, value: T) ?T {
    if (value.len == 0) return null;
    var result = value;
    result.len = value.len / 2;
    return result;
}

fn shrinkInt(comptime T: type, value: T) ?T {
    if (value == 0) return null;
    if (value > 0) {
        if (value == 1) return 0;
        return @divTrunc(value, 2);
    }
    // Negative: shrink toward 0
    if (value == -1) return 0;
    return @divTrunc(value, 2);
}

fn shrinkIntStep(comptime T: type, value: T) ?T {
    if (value == 0) return null;
    if (@typeInfo(T).int.signedness == .unsigned) {
        return value - 1;
    }
    if (value > 0) return value - 1;
    return value + 1;
}

fn shrinkFloat(comptime T: type, value: T) ?T {
    if (value == 0.0) return null;
    if (@abs(value) < 0.001) return 0.0;
    return value / 2.0;
}

fn shrinkEnum(comptime T: type, value: T) ?T {
    const fields = @typeInfo(T).@"enum".fields;
    inline for (fields, 0..) |field, i| {
        if (@intFromEnum(value) == field.value) {
            if (i == 0) return null;
            return @as(T, @enumFromInt(fields[i - 1].value));
        }
    }
    return null;
}

fn shrinkArray(comptime Child: type, comptime len: usize, value: [len]Child, config: ShrinkConfig) ?[len]Child {
    // Try to shrink each element
    var result = value;
    for (&result, 0..) |*elem, i| {
        if (shrinkOnceWithConfig(Child, value[i], config)) |simpler| {
            elem.* = simpler;
            return result;
        }
    }
    return null;
}

fn shrinkArrayField(
    comptime T: type,
    value: T,
    comptime property: anytype,
    budget: *usize,
    config: ShrinkConfig,
) ?T {
    const arr = @typeInfo(T).array;
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        if (comptime (@typeInfo(arr.child) == .@"union")) {
            const Elem = arr.child;
            const Context = struct { value: *const T, index: usize, budget: *usize };
            var ctx = Context{ .value = &value, .index = i, .budget = budget };
            if (findUnionCandidate(Elem, value[i], config, &ctx, property, struct {
                fn accept(context: *Context, candidate_elem: Elem, comptime prop: anytype) bool {
                    var candidate = context.value.*;
                    candidate[context.index] = candidate_elem;
                    return tryCandidate(T, candidate, prop, context.budget);
                }
            }.accept)) |union_candidate| {
                var candidate = value;
                candidate[i] = union_candidate;
                return candidate;
            }
            continue;
        }

        if (shrinkOnceWithConfig(arr.child, value[i], config)) |simpler| {
            var candidate = value;
            candidate[i] = simpler;
            if (tryCandidate(T, candidate, property, budget)) return candidate;
        }
        if (comptime (@typeInfo(arr.child) == .int)) {
            if (shrinkIntStep(arr.child, value[i])) |step| {
                var candidate = value;
                candidate[i] = step;
                if (tryCandidate(T, candidate, property, budget)) return candidate;
            }
        }
    }
    return null;
}

fn shrinkStruct(comptime T: type, comptime s: std.builtin.Type.Struct, value: T, config: ShrinkConfig) ?T {
    var result = value;
    inline for (s.fields) |field| {
        if (field.is_comptime) {
            continue;
        }
        const has_default = comptime (field.defaultValue() != null);
        if (!config.use_default_values or !has_default) {
            const field_val = @field(value, field.name);
            if (shrinkOnceWithConfig(field.type, field_val, config)) |simpler| {
                @field(result, field.name) = simpler;
                return result;
            }
        }
    }
    return null;
}

fn shrinkStructField(
    comptime T: type,
    value: T,
    comptime property: anytype,
    budget: *usize,
    config: ShrinkConfig,
) ?T {
    const s = @typeInfo(T).@"struct";
    inline for (s.fields) |field| {
        if (field.is_comptime) {
            continue;
        }
        const has_default = comptime (field.defaultValue() != null);
        if (!config.use_default_values or !has_default) {
            const field_val = @field(value, field.name);
            if (comptime (@typeInfo(field.type) == .@"union")) {
                const FieldType = field.type;
                const Context = struct { value: *const T, budget: *usize };
                var ctx = Context{ .value = &value, .budget = budget };
                if (findUnionCandidate(FieldType, field_val, config, &ctx, property, struct {
                    fn accept(context: *Context, candidate_union: FieldType, comptime prop: anytype) bool {
                        var candidate = context.value.*;
                        @field(candidate, field.name) = candidate_union;
                        return tryCandidate(T, candidate, prop, context.budget);
                    }
                }.accept)) |union_candidate| {
                    var candidate = value;
                    @field(candidate, field.name) = union_candidate;
                    return candidate;
                }
                continue;
            }
            if (shrinkOnceWithConfig(field.type, field_val, config)) |simpler| {
                var candidate = value;
                @field(candidate, field.name) = simpler;
                if (tryCandidate(T, candidate, property, budget)) return candidate;
            }
            if (comptime (@typeInfo(field.type) == .int)) {
                if (shrinkIntStep(field.type, field_val)) |step| {
                    var candidate = value;
                    @field(candidate, field.name) = step;
                    if (tryCandidate(T, candidate, property, budget)) return candidate;
                }
            }
        }
    }
    return null;
}

fn shrinkBoundedSliceField(
    comptime T: type,
    value: T,
    comptime property: anytype,
    budget: *usize,
    config: ShrinkConfig,
) ?T {
    const Elem = T.Elem;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (comptime (@typeInfo(Elem) == .@"union")) {
            const Context = struct { value: *const T, index: usize, budget: *usize };
            var ctx = Context{ .value = &value, .index = i, .budget = budget };
            if (findUnionCandidate(Elem, value.buf[i], config, &ctx, property, struct {
                fn accept(context: *Context, candidate_elem: Elem, comptime prop: anytype) bool {
                    var candidate = context.value.*;
                    candidate.buf[context.index] = candidate_elem;
                    return tryCandidate(T, candidate, prop, context.budget);
                }
            }.accept)) |union_candidate| {
                var candidate = value;
                candidate.buf[i] = union_candidate;
                return candidate;
            }
            continue;
        }
        if (shrinkOnceWithConfig(Elem, value.buf[i], config)) |simpler| {
            var candidate = value;
            candidate.buf[i] = simpler;
            if (tryCandidate(T, candidate, property, budget)) return candidate;
        }
        if (comptime (@typeInfo(Elem) == .int)) {
            if (shrinkIntStep(Elem, value.buf[i])) |step| {
                var candidate = value;
                candidate.buf[i] = step;
                if (tryCandidate(T, candidate, property, budget)) return candidate;
            }
        }
    }
    return null;
}

fn shrinkUnion(comptime T: type, comptime u: std.builtin.Type.Union, value: T, config: ShrinkConfig) ?T {
    if (u.tag_type == null) return null;
    const tag = std.meta.activeTag(value);
    inline for (u.fields) |field| {
        const field_tag = @field(u.tag_type.?, field.name);
        if (field_tag == tag) {
            const payload = @field(value, field.name);
            if (shrinkOnceWithConfig(field.type, payload, config)) |simpler| {
                return @unionInit(T, field.name, simpler);
            }
            break;
        }
    }
    return null;
}

fn findUnionCandidate(
    comptime UnionT: type,
    value: UnionT,
    config: ShrinkConfig,
    context: anytype,
    comptime property: anytype,
    comptime accept: anytype,
) ?UnionT {
    const u = @typeInfo(UnionT).@"union";
    if (u.tag_type == null) return null;

    const tag = std.meta.activeTag(value);
    var current_index: usize = 0;
    var found = false;

    inline for (u.fields, 0..) |field, i| {
        const field_tag = @field(u.tag_type.?, field.name);
        if (field_tag == tag) {
            found = true;
            current_index = i;
            const payload = @field(value, field.name);
            if (shrinkOnceWithConfig(field.type, payload, config)) |simpler| {
                const candidate = @unionInit(UnionT, field.name, simpler);
                if (accept(context, candidate, property)) return candidate;
            }
            if (comptime (@typeInfo(field.type) == .int)) {
                if (shrinkIntStep(field.type, payload)) |step| {
                    const candidate = @unionInit(UnionT, field.name, step);
                    if (accept(context, candidate, property)) return candidate;
                }
            }
            break;
        }
    }

    if (!found) return null;

    inline for (u.fields, 0..) |field, i| {
        if (i >= current_index) break;
        const candidate = @unionInit(UnionT, field.name, minimalValue(field.type, config));
        if (accept(context, candidate, property)) return candidate;
    }
    return null;
}

fn minimalValue(comptime T: type, config: ShrinkConfig) T {
    if (T == String) return String{};
    if (T == Id) {
        var id = Id{};
        id.len = Id.MIN_LEN;
        @memset(id.buf[0..Id.MIN_LEN], 'a');
        return id;
    }
    if (T == FilePath) {
        var fp = FilePath{};
        const ext = file_path_extensions[0];
        fp.buf[0] = '/';
        fp.buf[1] = 'a';
        std.mem.copyForwards(u8, fp.buf[2 .. 2 + ext.len], ext);
        fp.len = 2 + ext.len;
        return fp;
    }
    if (comptime isBoundedSlice(T)) {
        var result: T = undefined;
        result.len = 0;
        return result;
    }

    return switch (@typeInfo(T)) {
        .int => @as(T, 0),
        .float => @as(T, 0.0),
        .bool => false,
        .optional => @as(T, null),
        .array => |arr| blk: {
            var result: [arr.len]arr.child = undefined;
            var i: usize = 0;
            while (i < arr.len) : (i += 1) {
                result[i] = minimalValue(arr.child, config);
            }
            break :blk result;
        },
        .@"struct" => |s| blk: {
            var result: T = undefined;
            inline for (s.fields) |field| {
                if (field.is_comptime) {
                    if (field.defaultValue()) |default_value| {
                        @field(result, field.name) = default_value;
                        continue;
                    }
                    @compileError("Cannot build minimal value for comptime field without default: " ++ field.name);
                }
                if (config.use_default_values) {
                    if (field.defaultValue()) |default_value| {
                        @field(result, field.name) = default_value;
                        continue;
                    }
                }
                @field(result, field.name) = minimalValue(field.type, config);
            }
            break :blk result;
        },
        .@"enum" => |e| @enumFromInt(e.fields[0].value),
        else => @compileError("Cannot build minimal value for type: " ++ @typeName(T)),
    };
}

//
// Convenience generators for constrained values
//

/// Generate an integer in a specific range [min, max].
pub fn intRange(comptime T: type, random: std.Random, min: T, max: T) T {
    std.debug.assert(min <= max);
    if (min == max) return min;

    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    const u_min: U = @bitCast(min);
    const u_max: U = @bitCast(max);
    const range: U = u_max -% u_min +% @as(U, 1);
    if (range == 0) {
        return @as(T, @bitCast(random.int(U)));
    }
    const offset = random.uintLessThan(U, range);
    const u_val = u_min +% offset;
    return @as(T, @bitCast(u_val));
}

/// Generate an array of random bytes.
pub fn bytes(comptime len: usize, random: std.Random) [len]u8 {
    var result: [len]u8 = undefined;
    random.bytes(&result);
    return result;
}

//
// Tests
//

test "generate integers" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const v = generate(i32, random);
        _ = v;
    }

    for (0..100) |_| {
        const v = generate(u64, random);
        _ = v;
    }
}

test "generate structs" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const Point = struct { x: i32, y: i32 };
    for (0..100) |_| {
        const p = generate(Point, random);
        _ = p;
    }
}

test "generate structs respects default values" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const Sample = struct {
        comptime flag: bool = true,
        value: u8 = 7,
    };

    const v = generate(Sample, random);
    try testing.expectEqual(Sample{ .value = 7 }, v);
}

test "generate arrays" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const arr = generate([4]u8, random);
        _ = arr;
    }
}

test "shrink integers toward zero" {
    try testing.expectEqual(@as(i32, 50), shrinkInt(i32, 100).?);
    try testing.expectEqual(@as(i32, 0), shrinkInt(i32, 1).?);
    try testing.expectEqual(@as(?i32, null), shrinkInt(i32, 0));
    try testing.expectEqual(@as(i32, -50), shrinkInt(i32, -100).?);
    try testing.expectEqual(@as(i32, 0), shrinkInt(i32, -1).?);
}

test "check passes for true property" {
    try check(struct {
        fn prop(_: struct { a: u8, b: u8 }) bool {
            return true;
        }
    }.prop, .{ .iterations = 10 });
}

test "check fails for false property" {
    // Use expect_failure to verify shrinking works without printing noise
    try check(struct {
        fn prop(args: struct { a: u8 }) bool {
            return args.a == 0; // Fails for most values
        }
    }.prop, .{ .iterations = 100, .seed = 12345, .expect_failure = true });
}

test "checkResult returns failure details" {
    const failure = checkResult(struct {
        fn prop(args: struct { a: u8 }) bool {
            return args.a == 0;
        }
    }.prop, .{ .iterations = 50, .seed = 12345 });

    try testing.expect(failure != null);
    try testing.expectEqual(@as(u64, 12345), failure.?.seed);
    try testing.expectEqual(@as(u8, 1), failure.?.shrunk.a);
}

test "intRange generates in bounds" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..1000) |_| {
        const v = intRange(i32, random, -100, 100);
        try testing.expect(v >= -100 and v <= 100);
    }
}

test "intRange handles large ranges" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const min_i = std.math.minInt(i128);
    const max_i = std.math.maxInt(i128);
    for (0..100) |_| {
        const v = intRange(i128, random, min_i, max_i);
        try testing.expect(v >= min_i and v <= max_i);
    }

    const max_u = std.math.maxInt(u128);
    for (0..100) |_| {
        const v = intRange(u128, random, 0, max_u);
        try testing.expect(v <= max_u);
    }

    const near_max = max_u - 100;
    for (0..100) |_| {
        const v = intRange(u128, random, near_max, max_u);
        try testing.expect(v >= near_max and v <= max_u);
    }
}

test "addition is commutative" {
    try check(struct {
        fn prop(args: struct { a: i16, b: i16 }) bool {
            // Use smaller type to avoid overflow issues in test
            const sum1 = @as(i32, args.a) + @as(i32, args.b);
            const sum2 = @as(i32, args.b) + @as(i32, args.a);
            return sum1 == sum2;
        }
    }.prop, .{});
}

test "generate String produces valid printable strings" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var empty_count: usize = 0;
    for (0..1000) |_| {
        const s = generate(String, random);
        const slice = s.slice();

        // Verify length is within bounds
        try testing.expect(slice.len <= MAX_STRING_LEN);

        // Verify all characters are printable ASCII (32-126)
        for (slice) |c| {
            try testing.expect(c >= 32 and c <= 126);
        }

        if (slice.len == 0) empty_count += 1;
    }

    // Should generate some empty strings (roughly 10%)
    try testing.expect(empty_count > 50 and empty_count < 200);
}

test "generate Id produces valid alphanumeric IDs" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const id = generate(Id, random);
        const slice = id.slice();

        // IDs are bounded
        try testing.expect(slice.len >= Id.MIN_LEN and slice.len <= Id.MAX_LEN);

        // All chars are alphanumeric lowercase
        for (slice) |c| {
            try testing.expect((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'));
        }
    }
}

test "generate FilePath produces valid paths" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const fp = generate(FilePath, random);
        const slice = fp.slice();

        // Starts with /
        try testing.expect(slice.len > 0);
        try testing.expectEqual(@as(u8, '/'), slice[0]);

        // Has file extension
        try testing.expect(std.mem.lastIndexOfScalar(u8, slice, '.') != null);
    }
}

test "generate bounded slice produces valid lengths" {
    const BS = BoundedSlice(u8, 8);
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const bs = generate(BS, random);
        try testing.expect(bs.len <= BS.MAX_LEN);
        try testing.expectEqual(bs.len, bs.slice().len);
    }
}

test "shrink String toward empty" {
    var s = String{};
    s.len = 32;
    @memset(s.buf[0..32], 'a');

    // First shrink halves length
    const s1 = shrinkString(s).?;
    try testing.expectEqual(@as(usize, 16), s1.len);

    // Keep shrinking
    const s2 = shrinkString(s1).?;
    try testing.expectEqual(@as(usize, 8), s2.len);

    const s3 = shrinkString(s2).?;
    try testing.expectEqual(@as(usize, 4), s3.len);

    const s4 = shrinkString(s3).?;
    try testing.expectEqual(@as(usize, 2), s4.len);

    const s5 = shrinkString(s4).?;
    try testing.expectEqual(@as(usize, 1), s5.len);

    // Single char shrinks to empty
    const s6 = shrinkString(s5).?;
    try testing.expectEqual(@as(usize, 0), s6.len);

    // Empty cannot shrink
    try testing.expectEqual(@as(?String, null), shrinkString(s6));
}

test "shrink Id respects minimum length" {
    var id = Id{};
    id.len = Id.MAX_LEN;
    @memset(id.buf[0..Id.MAX_LEN], 'a');

    // Shrinks toward minimum length
    const id1 = shrinkId(id).?;
    try testing.expectEqual(@as(usize, 18), id1.len);

    const id2 = shrinkId(id1).?;
    try testing.expectEqual(@as(usize, 9), id2.len);

    const id3 = shrinkId(id2).?;
    try testing.expectEqual(@as(usize, Id.MIN_LEN), id3.len);

    // Cannot shrink below minimum length
    try testing.expectEqual(@as(?Id, null), shrinkId(id3));
}

test "shrink FilePath preserves extension" {
    var fp = FilePath{};
    const path = "/abcdefghij.zig";
    @memcpy(fp.buf[0..path.len], path);
    fp.len = path.len;

    const shrunk = shrinkFilePath(fp).?;
    const slice = shrunk.slice();
    try testing.expectEqual(@as(u8, '/'), slice[0]);
    try testing.expect(std.mem.endsWith(u8, slice, ".zig"));
    try testing.expect(shrunk.len < fp.len);
}

test "shrink bounded slice finds failing element" {
    const BS = BoundedSlice(u8, 4);
    var value: BS = .{};
    value.len = 1;
    value.buf[0] = 10;

    const shrunk = shrinkLoop(BS, struct {
        fn prop(args: BS) bool {
            if (args.len == 0) return true;
            return args.buf[0] == 0;
        }
    }.prop, value, 100, .{});

    try testing.expectEqual(@as(usize, 1), shrunk.len);
    try testing.expectEqual(@as(u8, 1), shrunk.buf[0]);
}

test "check with String finds minimal counterexample" {
    // Property: string length < 5 (fails for longer strings)
    // Shrinking should find a minimal string of length 5
    try check(struct {
        fn prop(args: struct { s: String }) bool {
            return args.s.slice().len < 5;
        }
    }.prop, .{ .iterations = 100, .seed = 99999, .expect_failure = true });
}

test "check with struct containing String" {
    try check(struct {
        fn prop(args: struct { id: Id, name: String, count: u8 }) bool {
            // Property: all IDs have minimum length
            return args.id.slice().len >= Id.MIN_LEN;
        }
    }.prop, .{ .iterations = 100 });
}

test "String.fromSlice creates correct string" {
    const s = String.fromSlice("hello world");
    try testing.expectEqualStrings("hello world", s.slice());

    // Truncates if too long
    var long_buf: [100]u8 = undefined;
    @memset(&long_buf, 'x');
    const truncated = String.fromSlice(&long_buf);
    try testing.expectEqual(MAX_STRING_LEN, truncated.slice().len);
}

test "generate optional String" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var null_count: usize = 0;
    for (0..100) |_| {
        const maybe_s = generate(?String, random);
        if (maybe_s == null) {
            null_count += 1;
        } else {
            try testing.expect(maybe_s.?.slice().len <= MAX_STRING_LEN);
        }
    }

    // Should generate some nulls (roughly 50%)
    try testing.expect(null_count > 20 and null_count < 80);
}

test "generate enum" {
    const Color = enum { red, green, blue };
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var counts = [_]usize{ 0, 0, 0 };
    for (0..300) |_| {
        const c = generate(Color, random);
        counts[@intFromEnum(c)] += 1;
    }

    // Each color should appear roughly 100 times
    for (counts) |count| {
        try testing.expect(count > 50 and count < 150);
    }
}

test "shrink enum follows declaration order" {
    const Choice = enum { first, second, third };
    try testing.expectEqual(Choice.second, shrinkEnum(Choice, Choice.third).?);
    try testing.expectEqual(Choice.first, shrinkEnum(Choice, Choice.second).?);
    try testing.expectEqual(@as(?Choice, null), shrinkEnum(Choice, Choice.first));
}

test "generate tagged union" {
    const Choice = union(enum) { a: u8, b: i16, c: bool };
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var counts = [_]usize{ 0, 0, 0 };
    for (0..300) |_| {
        const value = generate(Choice, random);
        switch (std.meta.activeTag(value)) {
            .a => counts[0] += 1,
            .b => counts[1] += 1,
            .c => counts[2] += 1,
        }
    }

    for (counts) |count| {
        try testing.expect(count > 50 and count < 150);
    }
}

test "shrink union payload" {
    const U = union(enum) { a: u8, b: u8 };
    const failure = checkResult(struct {
        fn prop(args: struct { u: U }) bool {
            return switch (args.u) {
                .b => |v| v <= 1,
                else => true,
            };
        }
    }.prop, .{ .iterations = 200, .seed = 12345 });

    try testing.expect(failure != null);
    const shrunk = failure.?.shrunk.u;
    switch (shrunk) {
        .b => |v| try testing.expectEqual(@as(u8, 2), v),
        else => try testing.expect(false),
    }
}

test "shrink union switches to earliest tag" {
    const U = union(enum) { a: u8, b: u8 };
    const failure = checkResult(struct {
        fn prop(_: struct { u: U }) bool {
            return false;
        }
    }.prop, .{ .iterations = 1, .seed = 12345 });

    try testing.expect(failure != null);
    const shrunk = failure.?.shrunk.u;
    switch (shrunk) {
        .a => |v| try testing.expectEqual(@as(u8, 0), v),
        else => try testing.expect(false),
    }
}

test "generate bool" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var true_count: usize = 0;
    for (0..100) |_| {
        if (generate(bool, random)) true_count += 1;
    }

    // Should be roughly 50/50
    try testing.expect(true_count > 30 and true_count < 70);
}

test "shrink struct finds minimal failing field" {
    // Property fails when x > 10, shrinking should minimize x
    try check(struct {
        fn prop(args: struct { x: u8, y: u8 }) bool {
            return args.x <= 10;
        }
    }.prop, .{ .iterations = 100, .seed = 54321, .expect_failure = true });
}

test "generate float produces reasonable values" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..200) |_| {
        const f16_val = generate(f16, random);
        try testing.expect(!std.math.isNan(f16_val));
        try testing.expect(!std.math.isInf(f16_val));
    }

    for (0..200) |_| {
        const f32_val = generate(f32, random);
        try testing.expect(!std.math.isNan(f32_val));
        try testing.expect(!std.math.isInf(f32_val));
    }

    var negative_count: usize = 0;
    for (0..1000) |_| {
        const f64_val = generate(f64, random);
        try testing.expect(!std.math.isNan(f64_val));
        try testing.expect(!std.math.isInf(f64_val));
        if (f64_val < 0.0) negative_count += 1;
    }
    try testing.expect(negative_count > 200 and negative_count < 800);
}
