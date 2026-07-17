// MIT License (c) Timur Fayzrakhmanov.
// tim.fayzrakhmanov@gmail.com (github.com/timfayz)

const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const builtin = @import("builtin");

/// Pretty formatting options.
pub const Options = struct {

    // [Generic printing options]

    /// Activate single line printing mode.
    inline_mode: bool = false,
    /// Limit the printing depth (0 does not limit).
    max_depth: u8 = 10,
    /// Specify depths to include or exclude from the output.
    filter_depths: Filter(usize) = .{ .exclude = &.{} },
    /// Indentation size for multi-line printing mode.
    tab_size: u8 = 2,
    /// Add extra empty line at the end of print (to stack up multiple prints).
    print_extra_empty_line: bool = false,
    /// Indicate empty output with a message (otherwise empty output length is 0).
    indicate_empty_output: bool = true,
    /// Specify a custom format string (eg. `pre{s}post`) to surround the resulting output.
    fmt: []const u8 = "",

    // [Type printing options]

    /// Show type tags (ie. `std.builtin.TypeId`, such as `.Union`, `.Int`).
    show_type_tags: bool = false,
    /// Show type names.
    show_type_names: bool = true,
    /// Limit the length of type names (0 does not limit).
    type_name_max_len: usize = 60,
    /// Specify depth of folding parentheses in type names (0 does not fold).
    type_name_fold_parens: usize = 1,
    /// Refine depth of folding parentheses in function signatures (0 does not fold).
    type_name_fold_parens_fn: usize = 2,
    /// Refine depth of folding parentheses for special case `@TypeOf(..)` (0 does not fold).
    type_name_fold_parens_type_of: usize = 2,

    // [Value printing options]

    /// Show values.
    show_vals: bool = true,
    /// Show empty values.
    show_empty_vals: bool = true,

    // [Pointer printing options]

    /// Follow pointers instead of printing their address.
    ptr_deref: bool = true,
    /// Reduce duplicating depths when dereferencing pointers.
    ptr_skip_dup_unfold: bool = true,
    /// TODO Show pointer addresses
    ptr_show_addr: bool = true,
    /// Treat `[*:sentinel]T` as array (except `[*:0]u8`, see `.ptr_many_u8z_is_str` instead)
    ptr_many_with_sentinel_is_array: bool = true,

    // [Optional printing options]

    /// Reduce duplicating depths when unfolding optional types.
    optional_skip_dup_unfold: bool = true,

    // [Struct and union printing options]

    /// Show struct fields.
    struct_show_field_names: bool = true,
    /// Treat empty structs as having `(empty)` value.
    struct_show_empty: bool = true,
    /// Inline primitive type values to save vertical space.
    struct_inline_prim_types: bool = true,
    /// Limit the number of fields in the output (0 does not limit).
    struct_max_len: usize = 15,
    /// Specify field names to include or exclude from the output.
    filter_field_names: Filter([]const u8) = .{ .exclude = &.{} },
    /// Specify field type tags to include or exclude from the output.
    filter_field_type_tags: Filter(std.builtin.TypeId) = .{ .exclude = &.{} },
    /// Specify field types to include or exclude from the output.
    filter_field_types: Filter(type) = .{ .exclude = &.{} },

    // [Array and slice printing options]

    /// Limit the number of items in the output (0 does not limit).
    array_max_len: usize = 20,
    /// Show item indices.
    array_show_item_idx: bool = true,
    /// Inline primitive types to save vertical space.
    array_inline_prim_types: bool = true,
    /// Show primitive types' type information (name and tag).
    array_show_prim_type_info: bool = false,

    // [Primitive type printing options]

    /// Specify type tags to treat as primitives.
    prim_type_tags: Filter(std.builtin.TypeId) = .{ .include = &.{
        .int,
        .comptime_int,
        .float,
        .comptime_float,
        .void,
        .bool,
    } },
    /// Specify concrete types to treat as primitives.
    prim_types: Filter(type) = .{ .include = &.{} },

    /// Print a u21 as a 'c'odepoint.
    u21_is_codepoint: bool = true,

    // [String printing options]

    /// Limit the length of strings (0 does not limit).
    str_max_len: usize = 80,
    /// Treat `[]u8` as `"string"`.
    slice_u8_is_str: bool = true,
    /// Treat `[:0]u8` as `"string"`.
    slice_u8z_is_str: bool = true,
    /// Treat `[n]u8` as `"string"`.
    array_u8_is_str: bool = false,
    /// Treat `[n:0]u8` as `"string"`.
    array_u8z_is_str: bool = true,
    /// Treat `[*:0]u8` as `"string"`.
    ptr_many_u8z_is_str: bool = true,
    /// Treat `[*c]u8` as `"string"`.
    ptr_c_u8_is_str: bool = true,

    // TODO
    // show_colors
    // solo_mode (for certain fields, recursively)
    // ?inline_unions = true
    // ?inline_small_struct = true
    // ?small_struct_size = 3
    show_tree_lines: bool = false, // '├' '─' '│' '└'
};

var stdout_buffer: [4096]u8 = undefined;

/// Prints pretty formatted string for an arbitrary input value.
pub fn print(alloc: Allocator, val: anytype, comptime opt: Options) !void {
    var pretty = Pretty(opt).init(alloc);
    defer pretty.deinit();
    try pretty.render(val, true);

    if (builtin.is_test) {
        std.debug.print("{s}", .{pretty.buffer.items});
    } else {
        // Perform buffered stdout write
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        try stdout_writer.interface.print("{s}", .{pretty.buffer.items});
        try stdout_writer.interface.flush();
    }
}

/// Prints pretty formatted string for an arbitrary input value (forced inline mode).
pub fn printInline(alloc: Allocator, val: anytype, comptime opt: Options) !void {
    comptime var copy = opt;
    copy.inline_mode = true; // force
    try print(alloc, val, copy);
}

/// Generates a pretty formatted string and returns it as a []u8 slice.
pub fn dump(alloc: Allocator, val: anytype, comptime opt: Options) ![]u8 {
    var pretty = Pretty(opt).init(alloc);
    defer pretty.deinit();
    return pretty.toOwnedSlice(val, false);
}

/// Generates a pretty formatted string and returns it as std.ArrayList interface.
pub fn dumpList(alloc: Allocator, val: anytype, comptime opt: Options) !std.ArrayList(u8) {
    var pretty = Pretty(opt).init(alloc);
    defer pretty.arena.deinit();
    try pretty.render(val, false);
    return pretty.buffer;
}

/// Pretty implementation structure.
fn Pretty(opt: Options) type {
    if (opt.tab_size < 1) @compileError(".tab_size cannot be less than 1.");
    return struct {
        alloc: Allocator,
        arena: std.heap.ArenaAllocator,
        buffer: std.ArrayList(u8),
        /// Tracking visited pointers to prevent recursion.
        pointers: struct {
            stack: [80]*anyopaque = [1]*anyopaque{@ptrFromInt(1)} ** 80,
            top: usize = 0,

            fn find(s: *@This(), ptr: anytype) bool {
                if (@typeInfo(@TypeOf(ptr)) != .pointer) @compileError("Value must be a pointer.");
                for (0..s.top) |i|
                    if (s.stack[i] == @as(*anyopaque, @ptrCast(@constCast(ptr)))) return true;
                return false;
            }

            fn pop(s: *@This()) void {
                s.top -= 1;
            }

            fn push(s: *@This(), ptr: anytype) bool {
                if (@typeInfo(@TypeOf(ptr)) != .pointer) @compileError("Value must be a pointer.");
                if (s.top >= s.stack.len) return false;
                s.stack[s.top] = @ptrCast(@constCast(ptr));
                s.top += 1;
                return true;
            }
        } = .{},
        last_tok: Token = .none,

        /// TODO tree rendering view
        // last_child: bool = false,

        /// Transient state between recursive calls.
        const Context = struct {
            /// Indices for arrays and slices.
            index: usize = 0,
            /// Field names for structs and unions.
            field: []const u8 = "",
            /// Recursion depth
            depth: usize = 0, // TODO .depth = .min = usize/.max = usize/.range = {usize, usize}
            depth_skip: usize = 0,
            inline_mode: bool = if (opt.inline_mode) true else false,
        };

        const Self = @This();

        /// Pretty output is a sequence of tokens in the following format:
        ///   output ::= none | output | [index]:, field:, [tag], type, @addr, = value
        /// The separators between tokens are resolved automatically, depending
        /// on previous/current token type.
        const Token = enum {
            none,
            info_index,
            info_field,
            info_tag,
            info_type,
            info_addr,
            info_paren,
            value,

            fn isInfo(tok: Token) bool {
                if (@intFromEnum(tok) >= @intFromEnum(Token.info_index) and
                    @intFromEnum(tok) <= @intFromEnum(Token.info_paren))
                    return true;
                return false;
            }

            fn isSameOrReverse(tok: Token, prev: Token) bool {
                return @intFromEnum(tok) <= @intFromEnum(prev);
            }
        };

        pub fn init(alloc: Allocator) Self {
            return Self{
                .alloc = alloc,
                .arena = std.heap.ArenaAllocator.init(alloc),
                .buffer = std.ArrayList(u8).empty,
            };
        }

        /// Deallocates all the intermediate results and the buffer itself.
        pub fn deinit(s: *Self) void {
            s.buffer.deinit(s.alloc);
            s.arena.deinit();
        }

        /// Returns the final pretty string. The caller owns the returned memory.
        pub fn toOwnedSlice(s: *Self, val: anytype, for_print: bool) ![]u8 {
            try s.render(val, for_print);
            return s.buffer.toOwnedSlice(s.alloc);
        }

        pub fn render(s: *Self, val: anytype, for_print: bool) !void {
            try s.traverse(val, null, .{});

            // [Option] Indicate empty output
            if (opt.indicate_empty_output and s.buffer.items.len == 0)
                try s.buffer.appendSlice(s.alloc, "(empty output)");

            // [Option] Apply custom formatting (if specified)
            if (opt.fmt.len > 0) {
                const fmt_output = try std.fmt.allocPrint(s.alloc, opt.fmt, .{s.buffer.items});
                s.buffer.deinit(s.alloc); // release original buffer
                s.buffer = std.ArrayList(u8).fromOwnedSlice(fmt_output); // replace
            }

            if (for_print) {
                // [Option] Insert an extra newline at the end to stack up multiple prints
                if (opt.fmt.len == 0) {
                    const last_line = if (opt.print_extra_empty_line) "\n\n" else "\n";
                    try s.buffer.appendSlice(s.alloc, last_line);
                }
            }
        }

        fn appendTok(s: *Self, tok: Token, str: []const u8, ctx: Context) !void {
            // [Option] Stop if depth exceeds
            if (opt.max_depth > 0 and ctx.depth > opt.max_depth -| 1)
                return;

            // [Option] Stop if depth is not included
            if (!opt.filter_depths.includes(ctx.depth))
                return;

            // std.log.err("{s} {s}", .{ @tagName(s.last_tok), @tagName(tok) });

            // Resolve separator between last two tokens:
            if (s.last_tok != .none) {
                // special case: type name followed by value token
                if (s.last_tok == .info_type and tok == .value) {
                    if (ctx.inline_mode) {
                        try s.buffer.appendSlice(s.alloc, " = ");
                    } else try s.appendSpecial(.indent, ctx);
                }
                // two same tokens or tokens in reverse logical order
                else if (tok.isSameOrReverse(s.last_tok)) {
                    if (ctx.inline_mode) { // special case: comma in sequences
                        try s.buffer.appendSlice(s.alloc, if (ctx.index > 0) ", " else " ");
                    } else try s.appendSpecial(.indent, ctx);
                }
                // two info tokens in normal logical order
                else {
                    if (ctx.inline_mode) { // special case: type name and open bracket (`type{`)
                        try s.buffer.appendSlice(s.alloc, if (s.last_tok == .info_type) "" else " ");
                    } else try s.buffer.appendSlice(s.alloc, " ");
                }
            }

            try s.buffer.appendSlice(s.alloc, str);
            s.last_tok = tok;
        }

        fn appendSpecial(s: *Self, comptime tag: enum { indent, paren_open, paren_closed }, ctx: Context) !void {
            switch (tag) {
                .indent => {
                    // // [Option] Show tree lines
                    // if (opt.show_tree_lines and s.depth > 0) {
                    //     const prefix = if (s.is_last) "\n└" else "\n├";
                    //     return prefix ++ ("─" ** ((s.depth * opt.tab_size) - 1));
                    // } else {
                    try s.buffer.append(s.alloc, '\n');
                    try s.buffer.appendNTimes(s.alloc, ' ', (ctx.depth -| ctx.depth_skip) * opt.tab_size);
                },
                .paren_open => {
                    if (ctx.inline_mode)
                        // If type is hidden, add a canonical dot to mimic zig's anonymous structs
                        try s.appendTok(.info_paren, if (!opt.show_type_names) ".{" else "{", ctx);
                },
                .paren_closed => {
                    if (ctx.inline_mode)
                        try s.buffer.appendSlice(s.alloc, " }"); // no token resolution logic required
                },
            }
        }

        fn appendVal(s: *Self, str: []const u8, ctx: Context) !void {
            // [Option] Show value
            if (opt.show_vals)
                try s.appendTok(.value, str, ctx);
        }

        fn appendValSpecial(s: *Self, comptime tag: enum { unknown, skip, empty, recursion }, ctx: Context) !void {
            switch (tag) {
                .unknown => {
                    try s.appendVal("?", ctx);
                },
                .skip => {
                    try s.appendVal("..", ctx);
                },
                .empty => {
                    // [Option] Show empty values
                    if (opt.show_empty_vals)
                        try s.appendVal("(empty)", ctx);
                },
                .recursion => {
                    try s.appendVal("(recursion)", ctx);
                },
            }
        }

        fn appendValString(s: *Self, str: []const u8, ctx: Context) !void {
            // [Option] Trim string if exceeds
            // if (opt.str_max_len > 0 and str.len > opt.str_max_len)
            const trimmed = try strTrim(s.arena.allocator(), str, opt.str_max_len, "..", .auto);

            // [Option-less] Embrace with double quotes
            const quoted = try strEmbraceWith(s.arena.allocator(), trimmed.items, "\"", "\"");
            try s.appendVal(quoted.items, ctx);
        }

        fn appendValFmt(s: *Self, comptime fmt: []const u8, val: anytype, ctx: Context) !void {
            const res = try std.fmt.allocPrint(s.arena.allocator(), fmt, .{val});
            try s.appendVal(res, ctx);
        }

        fn appendInfo(s: *Self, val: anytype, prev: ?std.builtin.Type, ctx: Context) !Context {
            const val_T = @TypeOf(val);
            var c = ctx; // modifiable copy

            // [Option] Do not print value info if depth is excluded
            if (!opt.filter_depths.includes(ctx.depth)) {
                c.depth_skip += 1;
            } else {
                const saved_len = s.buffer.items.len;

                // Adjust how value info is printed depending on the parent type
                if (prev) |info| {
                    appendInfo: {
                        if (info == .array or
                            (info == .pointer and
                                (info.pointer.size == .slice or
                                    (info.pointer.size == .many and opt.ptr_many_with_sentinel_is_array))))
                        {
                            try s.appendInfoIndex(c);
                            // [Option] Show primitive types on the same line as index
                            if (opt.array_inline_prim_types and
                                opt.prim_type_tags.includes(typeTag(val_T)) or opt.prim_types.includes(val_T))
                            {
                                // [Option] Show primitive types' type info
                                if (!opt.array_show_prim_type_info)
                                    break :appendInfo;

                                c.inline_mode = true;
                            }
                        } else if (info == .@"struct" or info == .@"union") {
                            try s.appendInfoField(c);
                            // [Option] Show primitive types on the same line as field
                            if (!opt.inline_mode and
                                opt.struct_inline_prim_types and
                                (opt.prim_type_tags.includes(typeTag(val_T)) or opt.prim_types.includes(val_T)))
                            {
                                c.inline_mode = true;
                            }
                        } else if (info == .optional) {
                            // [Option] Reduce duplicate unfolding
                            if (opt.optional_skip_dup_unfold)
                                break :appendInfo;
                        } else if (info == .pointer) {
                            // [Option] Reduce dereferencing to avoid type info chain duplication
                            if (opt.ptr_skip_dup_unfold)
                                break :appendInfo;
                        }
                        try s.appendInfoType(val_T, c);
                    }
                }
                // No parent type available, print generic value info
                else {
                    try s.appendInfoType(val_T, c);
                }

                // No value info has been written (e.g. due to options)
                if (s.buffer.items.len == saved_len) {
                    c.depth_skip += 1; // adjust indent
                }
            }
            // Assume value info is always printed to progress in depth
            c.depth += 1;
            return c;
        }

        fn appendInfoIndex(s: *Self, ctx: Context) !void {
            // [Option] Show item index
            if (opt.array_show_item_idx) {
                const res = try std.fmt.allocPrint(s.arena.allocator(), "[{d}]:", .{ctx.index});
                try s.appendTok(.info_index, res, ctx);
            }
        }

        fn appendInfoField(s: *Self, ctx: Context) !void {
            // [Option] Show field name
            if (opt.struct_show_field_names) {
                const res = try std.fmt.allocPrint(s.arena.allocator(), ".{s}:", .{ctx.field});
                try s.appendTok(.info_field, res, ctx);
            }
        }

        fn appendInfoType(s: *Self, T: type, ctx: Context) !void {
            // [Option] Show type tag
            if (opt.show_type_tags) { // and !ctx.hasTypeHidden()
                try s.appendTok(.info_tag, "[" ++ @tagName(@typeInfo(T)) ++ "]", ctx);
            }

            const type_name: []const u8 = comptime blk: {
                var name: []const u8 = @typeName(T);

                // [Option] Shorten type name by folding brackets in it
                if (opt.type_name_fold_parens > 0) {
                    var level = opt.type_name_fold_parens;

                    // [Option] Shorten type except function signatures
                    if (@typeInfo(T) == .pointer and @typeInfo(meta.Child(T)) == .@"fn") {
                        level = opt.type_name_fold_parens_fn;
                    }
                    // [Option] If type name starts with '@TypeOf(..)' (rare case)
                    else if (name.len != 0 and name[0] == '@') {
                        level = opt.type_name_fold_parens_type_of;
                    }

                    name = strFoldBracketsCt(name, .{ .fold_depth = level, .bracket = .round });
                }

                // [Option] Cut the type name if exceeds the length
                if (opt.type_name_max_len > 0 and name.len > opt.type_name_max_len) {
                    name = name[0..opt.type_name_max_len] ++ "..";
                }

                break :blk name;
            };

            // [Option] Show type name
            if (opt.show_type_names) { // and !ctx.hasTypeHidden()
                try s.appendTok(.info_type, type_name, ctx);
            }
        }

        fn traverse(s: *Self, val: anytype, prev: ?std.builtin.Type, ctx: Context) std.mem.Allocator.Error!void {
            const val_T = @TypeOf(val);
            const val_info = @typeInfo(val_T);

            // [Option] Stop if depth exceeds
            if (opt.max_depth > 0 and ctx.depth > opt.max_depth -| 1)
                return;

            // std.log.err("{any}, {}", .{ val, ctx.depth });
            // Render value info
            var c = try s.appendInfo(val, prev, ctx);

            // Render value itself
            switch (val_info) {
                .pointer => |ptr| {
                    switch (ptr.size) {
                        .one => {
                            // [Option-less] Do not show opaque or function pointers
                            if (ptr.child == anyopaque or
                                @typeInfo(ptr.child) == .@"fn")
                                return;

                            // [Option] Follow the pointer
                            if (opt.ptr_deref) {
                                if (s.pointers.find(val)) {
                                    try s.appendValSpecial(.recursion, c);
                                } else if (s.pointers.push(val)) {
                                    try s.traverse(val.*, val_info, c);
                                    s.pointers.pop();
                                } else { // pointers stack is full
                                    try s.appendValSpecial(.skip, c);
                                }
                            } else {
                                try s.appendValFmt("{*}", val, c);
                            }
                        },
                        .c => {
                            // [Option] Interpret [*c]u8 as string
                            if (opt.ptr_c_u8_is_str) {
                                if (val == null) {
                                    try s.appendVal("null", c);
                                } else {
                                    try s.appendValString(
                                        std.mem.span(val),
                                        c,
                                    );
                                }
                            } else {
                                // Can't follow C pointers
                                try s.appendValSpecial(.unknown, c);
                            }
                        },
                        .many => {
                            // [Option] Interpret [*:0]u8 as string
                            if (opt.ptr_many_u8z_is_str and
                                ptr.child == u8 and meta.sentinel(val_T) == 0)
                            {
                                const len = std.mem.indexOfSentinel(u8, 0, val);
                                try s.appendValString(val[0..len :0], c);
                                return;
                            }

                            // [Option] Interpret [*:sentinel]T as array
                            if (opt.ptr_many_with_sentinel_is_array) {
                                if (meta.sentinel(val_T)) |sentinel| {
                                    var i: usize = 0;
                                    while (val[i] != sentinel) : (i += 1) {
                                        const len = i + 1;
                                        // [Option] Stop if the length of a slice exceeds
                                        if (opt.array_max_len > 0 and len > opt.array_max_len)
                                            break;

                                        c.index = i;
                                        // s.last_child = if (len == val.len) true else false;
                                        try s.traverse(val[i], val_info, c);
                                    }
                                    return;
                                }
                            }

                            // Can't follow the pointer
                            try s.appendValSpecial(.unknown, c);
                        },
                        .slice => {
                            // [Option] Interpret []u8 as string
                            if (opt.slice_u8_is_str and
                                meta.Child(val_T) == u8 and meta.sentinel(val_T) == null)
                            {
                                try s.appendValString(val, c);
                                return;
                            }

                            // [Option] Interpret [:0]u8 as string
                            if (opt.slice_u8z_is_str and
                                meta.Child(val_T) == u8 and meta.sentinel(val_T) == 0)
                            {
                                try s.appendValString(val, c);
                                return;
                            }

                            // Slice is empty
                            if (val.len == 0) {
                                try s.appendValSpecial(.empty, c);
                                return;
                            }

                            // Slice has multiple elements:
                            try s.appendSpecial(.paren_open, c);

                            // Comptime slice
                            if (isComptime(val)) {
                                inline for (val, 0..) |item, i| {
                                    const len = i + 1;
                                    // [Option] Stop if the length of a slice exceeds
                                    if (opt.array_max_len > 0 and len > opt.array_max_len)
                                        break;

                                    c.index = i;
                                    // s.last_child = if (len == val.len) true else false;
                                    try s.traverse(item, val_info, c);
                                }
                            }
                            // Runtime slice
                            else {
                                for (val, 0..) |item, i| {
                                    const len = i + 1;
                                    // [Option] Stop if the length of a slice exceeds
                                    if (opt.array_max_len > 0 and len > opt.array_max_len)
                                        break;

                                    c.index = i;
                                    // s.last_child = if (len == val.len) true else false;
                                    try s.traverse(item, val_info, c);
                                }
                            }
                            try s.appendSpecial(.paren_closed, c);
                        },
                    }
                },
                .@"struct" => {
                    if (meta.fields(val_T).len == 0) {
                        // [Option] Show empty struct as empty value
                        if (opt.struct_show_empty)
                            try s.appendValSpecial(.empty, c);
                        return;
                    }

                    try s.appendSpecial(.paren_open, c);

                    // Struct has fields
                    inline for (meta.fields(val_T), 0..) |field, i| {
                        // [Option] If field type tag should be ignored
                        if (comptime !opt.filter_field_type_tags.includes(typeTag(field.type)))
                            continue;

                        // [Option] If field type should be ignored
                        if (comptime !opt.filter_field_types.includes(field.type))
                            continue;

                        // [Option] If field name should be ignored
                        if (comptime !opt.filter_field_names.includes(field.name))
                            continue;

                        const len = i + 1;

                        // [Option] If the number of struct fields exceeds
                        if (opt.struct_max_len > 0 and len > opt.struct_max_len) {
                            try s.appendValSpecial(.skip, c);
                            break;
                        }

                        c.index = i;
                        c.field = field.name;
                        // s.last_child = if (meta.fields(val_T).len == len) true else false;
                        try s.traverse(@field(val, field.name), val_info, c);
                    }

                    try s.appendSpecial(.paren_closed, c);
                },
                .array => {
                    // [Option] Interpret [n]u8 array as string
                    if (opt.array_u8_is_str and meta.Child(val_T) == u8) {
                        try s.appendValString(&val, c);
                        return;
                    }

                    // [Option] Interpret [n:0]u8 array as string
                    if (opt.array_u8z_is_str and
                        (meta.Child(val_T) == u8 and meta.sentinel(val_T) == 0))
                    {
                        try s.appendValString(&val, c);
                        return;
                    }

                    try s.appendSpecial(.paren_open, c);
                    for (val, 0..) |item, i| {
                        const len = i + 1;
                        // [Option] Stop if the length of an array exceeds
                        if (opt.array_max_len > 0 and len > opt.array_max_len)
                            break;

                        c.index = i;
                        // c.last_child = if (len == val.len) true else false;
                        try s.traverse(item, val_info, c);
                    }
                    try s.appendSpecial(.paren_closed, c);
                },
                .optional => {
                    // Optional has payload
                    if (val) |v| {
                        try s.traverse(v, val_info, c);
                        return;
                    }

                    // Optional is null
                    try s.appendVal("null", c);
                },
                .@"union" => |uni| {
                    // Tagged union: union(enum) {..}
                    if (uni.tag_type != null) {
                        // [Option] Show primitive types on the same line as field
                        if (opt.struct_inline_prim_types and
                            (opt.prim_type_tags.includes(typeTag(val_T)) or
                                opt.prim_types.includes(val_T)))
                        {
                            c.inline_mode = true;
                        }
                        try s.appendSpecial(.paren_open, c);
                        switch (val) {
                            inline else => |v, tag| { // unwrap value and tag
                                c.field = @tagName(tag);
                                try s.traverse(v, val_info, c);
                            },
                        }
                        try s.appendSpecial(.paren_closed, c);
                        return;
                    }

                    // Untagged union: union {..}
                    try s.appendValSpecial(.unknown, c);
                },
                .@"enum" => |enm| {
                    // Exhaustive and named enums: enum {..}
                    if (std.enums.tagName(val_T, val)) |tag_name| {
                        const enum_name = try std.fmt.allocPrint(s.arena.allocator(), ".{s}", .{tag_name});
                        try s.appendVal(enum_name, c);
                        return;
                    }

                    // Non-exhaustive and unnamed enums: enum(int) {.., _}
                    const enum_name = try std.fmt.allocPrint(s.arena.allocator(), "{s}({d})", .{
                        @typeName(enm.tag_type),
                        @intFromEnum(val),
                    });
                    try s.appendVal(enum_name, c);
                },
                .int => |int| {
                    if (opt.u21_is_codepoint and int.bits == 21 and int.signedness == .unsigned) {
                        switch (val) {
                            // control characters we want to escape:
                            // https://en.wikipedia.org/wiki/C0_and_C1_control_codes
                            // C0s which are escaped as such in Zig
                            0x09 => try s.appendVal("'\\t'", c),
                            0x0a => try s.appendVal("'\\n'", c),
                            0x0d => try s.appendVal("'\\r'", c),
                            // remaining C0s
                            0x00...0x08,
                            0x0b...0x0c,
                            0x0e...0x1f,
                            // DEL (0x7f) and C1s
                            0x7f...0x9f,
                            // surrogate codepoints (invalid to encode in UTF-8):
                            0xd800...0xdfff,
                            => {
                                try s.appendValFmt("'\\u{{{x:0<2}}}'", val, c);
                            },
                            // everything else: includes too-high codepoints, which
                            // the {u} format replaces with the Unicode replacement
                            // character U+FFFD (�)
                            else => try s.appendValFmt("'{u}'", val, c),
                        }
                    } else {
                        try s.appendValFmt("{d}", val, c);
                    }
                },
                // consciously covered: .Type, .Float, .Void
                else => {
                    // Fall back to standard {any} formatter
                    try s.appendValFmt("{any}", val, c);
                },
            }
        }
    };
}

/// An interface that allows checking the inclusion or exclusion of items of
/// a specified type.
fn Filter(T: type) type {
    return union(enum(usize)) {
        include: []const T,
        exclude: []const T,
        fn includes(s: @This(), item: T) bool {
            switch (s) {
                .include => {
                    for (s.include) |elm| {
                        if (T == []const u8) {
                            if (std.mem.eql(u8, elm, item)) return true;
                        } else {
                            if (elm == item) return true;
                        }
                    }
                    return false;
                },
                .exclude => {
                    for (s.exclude) |elm| {
                        if (T == []const u8) {
                            if (std.mem.eql(u8, elm, item)) return false;
                        } else {
                            if (elm == item) return false;
                        }
                    }
                    return true;
                },
            }
        }
    };
}

test Filter {
    const expect = std.testing.expect;
    const opt1 = Options{
        .filter_depths = .{ .include = &.{ 1, 2, 3 } },
    };
    try expect(!opt1.filter_depths.includes(4));
    try expect(opt1.filter_depths.includes(2));

    const opt2 = Options{
        .filter_depths = .{ .exclude = &.{ 1, 2, 3 } },
    };
    try expect(opt2.filter_depths.includes(4));
    try expect(!opt2.filter_depths.includes(2));

    const opt3 = Options{
        .filter_depths = .{ .include = &.{} },
    };
    try expect(!opt3.filter_depths.includes(4));
    try expect(!opt3.filter_depths.includes(2));

    const opt4 = Options{
        .filter_depths = .{ .exclude = &.{} },
    };
    try expect(opt4.filter_depths.includes(4));
    try expect(opt4.filter_depths.includes(2));
}

/// Checks if the value is comptime-known
inline fn isComptime(val: anytype) bool {
    return meta.fields(@TypeOf(.{val}))[0].is_comptime;
}

test isComptime {
    try std.testing.expect(isComptime(std.builtin.Type.StructField));
    try std.testing.expect(isComptime(meta.fields(struct { f: u8 })));
    var rt_slice: []const u8 = &[_]u8{1};
    _ = &rt_slice;
    try std.testing.expect(!isComptime(rt_slice));
}

/// Retrieves the value type tag.
fn typeTag(comptime T: type) std.builtin.TypeId {
    return meta.activeTag(@typeInfo(T));
}

test typeTag {
    try std.testing.expect(typeTag(@TypeOf(typeTag)) == .@"fn");
    try std.testing.expect(typeTag(@TypeOf(struct {}{})) == .@"struct");
    try std.testing.expect(typeTag(@TypeOf(42)) == .comptime_int);
    try std.testing.expect(typeTag(@TypeOf(null)) == .null);
}

/// Retrieves the default value of a struct field.
fn typeDefaultValue(comptime T: type, comptime field: @TypeOf(.enum_literal)) meta.fieldInfo(T, field).type {
    const f = meta.fieldInfo(T, field);
    if (f.default_value_ptr == null) @compileError("Field doesn't have a default value.");
    const dval_ptr = @as(*align(f.alignment) const anyopaque, @alignCast(f.default_value_ptr.?));
    const val = @as(*const f.type, @ptrCast(dval_ptr)).*;
    return val;
}

test typeDefaultValue {
    const Data = struct {
        val1: []const u8 = "test",
        val2: u8 = 42,
        val3: ?u8 = null,
        val4: type = ?u8,
        val5: struct {} = .{},
    };

    const equal = std.testing.expectEqual;
    try equal("test", typeDefaultValue(Data, .val1));
    try equal(42, typeDefaultValue(Data, .val2));
    try equal(null, typeDefaultValue(Data, .val3));
    try equal(?u8, typeDefaultValue(Data, .val4));
    try equal(std.meta.fieldInfo(Data, .val5).type{}, typeDefaultValue(Data, .val5));
}

/// Concatenates arg strings with the separator in between (comptime only).
fn strAddSepCt(sep: []const u8, args: anytype) []const u8 {
    if (!@inComptime()) @compileError("Must be called at comptime.");
    const args_len = meta.fields(@TypeOf(args)).len;
    const items: [args_len][]const u8 = args;

    var out: []const u8 = "";
    for (items) |field| {
        if (field.len == 0) continue;
        out = out ++ field ++ sep;
    }

    return out[0..out.len -| sep.len];
}

/// Concatenates arg strings with the separator in between (runtime only).
fn strAddSep(alloc: Allocator, sep: []const u8, args: anytype) !std.ArrayList(u8) {
    const args_len = meta.fields(@TypeOf(args)).len;
    const items: [args_len][]const u8 = args;

    var out = std.ArrayList(u8).empty;
    for (items) |field| {
        if (field.len == 0) continue;
        try out.appendSlice(alloc, field);
        try out.appendSlice(alloc, sep);
    }

    out.shrinkRetainingCapacity(out.items.len -| sep.len);
    return out;
}

test strAddSep {
    const equal = std.testing.expectEqualStrings;
    const run = struct {
        pub fn case(comptime expect: []const u8, comptime sep: []const u8, args: anytype) !void {
            try equal(expect, comptime strAddSepCt(sep, args));

            var out = try strAddSep(std.testing.allocator, sep, args);
            defer out.deinit(std.testing.allocator);
            try equal(expect, out.items);
        }
    };

    try run.case("a=b=c", "=", .{ "a", "b", "c" });
    try run.case("a", "=", .{ "", "a" });
    try run.case("a", "=", .{ "a", "" });
    try run.case("a", "=", .{"a"});
    try run.case("", "=", .{ "", "" });
    try run.case("", "=", .{""});
}

/// Configuration structure for strFoldBracketsCt.
const FoldBracketOptions = struct {
    fold_depth: u8 = 1, // 0 = do not fold
    bracket: enum { round, square, curly, angle, any } = .any,
    max_cap: usize = 32,
};

/// Folds content inside brackets with ".." based on the specified
/// configuration. Defaults are: nesting level = 1 (0 means no folding),
/// bracket type = any, and max capacity = 32. Returns unchanged input if
/// brackets are unbalanced or their nesting level, as well as the number of
/// pairs, exceeds the max capacity. (Function is comptime only)
fn strFoldBracketsCt(str: []const u8, conf: FoldBracketOptions) []const u8 {
    if (!@inComptime()) @compileError("Must be called at comptime.");
    if (conf.fold_depth == 0) return str;

    const Bracket = struct {
        i: usize,
        type: u8,
        pub fn isPairTo(self: *const @This(), closing: u8) bool {
            return switch (self.type) {
                '(' => closing == ')',
                '[' => closing == ']',
                '{' => closing == '}',
                '<' => closing == '>',
                else => false,
            };
        }
    };
    const IndexPair = struct { start: usize, end: usize };

    var brackets = Stack(Bracket, conf.max_cap){};
    var fold_stack = Stack(IndexPair, conf.max_cap){};

    const closing = switch (conf.bracket) {
        .round => ')', // 40 41
        .square => ']', // 91 93
        .curly => '}', // 123 125
        .angle => '>', // 60 62
        else => 0,
    };

    // Collect indices for trimming
    for (str, 0..) |c, i| {
        if (c == '(' or c == '[' or c == '{' or c == '<') {
            if (brackets.push(.{ .i = i, .type = c }) != true)
                return str;
        } else if (c == ')' or c == ']' or c == '}' or c == '>') {
            if (brackets.pop()) |start_bracket| {
                // If a closing bracket does not match the opening one (unbalanced)
                if (!start_bracket.isPairTo(c))
                    return str;
                // Save trimming indices only for the necessary bracket level and type
                const bracket_depth = brackets.len();
                if (bracket_depth == (conf.fold_depth - 1) and (c == closing or conf.bracket == .any)) {
                    // Save open and closed indices
                    if (!fold_stack.push(.{ .start = start_bracket.i, .end = i }))
                        return str;
                }
            } else {
                // If a closing bracket was found but there wasn't an opening one (unbalanced)
                return str;
            }
        }
    }

    // If there is nothing to fold
    if (fold_stack.empty()) return str;

    // Trim according to the collected bracket indices
    var out: []const u8 = "";
    var i: usize = 0;
    var next: usize = 0;

    // Per each trim index pair
    while (i < fold_stack.len()) : (i += 1) {
        const start = fold_stack.stack[i].start;
        const end = fold_stack.stack[i].end;
        out = out ++ str[next .. start + 1] ++ if ((end - start) > 1) ".." else str[start + 1 .. end];
        next = end;
    }

    // Append leftovers
    out = out ++ str[next..];

    return out;
}

test strFoldBracketsCt {
    const equal = std.testing.expectEqualStrings;
    try equal("", comptime strFoldBracketsCt("", .{}));
    try equal("()", comptime strFoldBracketsCt("()", .{}));
    try equal("f", comptime strFoldBracketsCt("f", .{}));
    try equal("foo", comptime strFoldBracketsCt("foo", .{}));
    try equal("(..)", comptime strFoldBracketsCt("(foo)", .{ .fold_depth = 1 }));

    try equal("f()[]<>f", comptime strFoldBracketsCt("f()[]<>f", .{ .fold_depth = 0, .bracket = .any }));
    try equal("f(1)[1]<1>f", comptime strFoldBracketsCt("f(1)[1]<1>f", .{ .fold_depth = 0, .bracket = .any }));
    try equal("f(..)[..]<..>f", comptime strFoldBracketsCt("f(1)[1]<1>f", .{ .fold_depth = 1, .bracket = .any }));
    try equal("<..>[..](..)f(..)[..]<..>", comptime strFoldBracketsCt("<1>[1](1)f(1)[1]<1>", .{ .fold_depth = 1, .bracket = .any }));
    try equal("<1>[1](..)f(..)[1]<1>", comptime strFoldBracketsCt("<1>[1](1)f(1)[1]<1>", .{ .fold_depth = 1, .bracket = .round }));
    try equal("<1>[..](1)f(1)[..]<1>", comptime strFoldBracketsCt("<1>[1](1)f(1)[1]<1>", .{ .fold_depth = 1, .bracket = .square }));
    try equal("<..>[1](1)f(1)[1]<..>", comptime strFoldBracketsCt("<1>[1](1)f(1)[1]<1>", .{ .fold_depth = 1, .bracket = .angle }));

    try equal("(1(..)1(..)1)", comptime strFoldBracketsCt("(1(2)1(2)1)", .{ .fold_depth = 2 }));
    try equal("(1(2(..)2)1((..))1)", comptime strFoldBracketsCt("(1(2(3)2)1((3))1)", .{ .fold_depth = 3 }));
    try equal("(1(2(3)2)1)", comptime strFoldBracketsCt("(1(2(3)2)1)", .{ .fold_depth = 3, .bracket = .angle }));
    try equal("(1(2<..>2)1)", comptime strFoldBracketsCt("(1(2<3>2)1)", .{ .fold_depth = 3, .bracket = .angle }));
    try equal("(1(2<3>2{..}2)1)", comptime strFoldBracketsCt("(1(2<3>2{3}2)1)", .{ .fold_depth = 3, .bracket = .curly }));
    try equal("(1(2<..>2{..}2)1)", comptime strFoldBracketsCt("(1(2<3>2{3}2)1)", .{ .fold_depth = 3, .bracket = .any }));
}

/// Embraces the specified string with pre- and post-fixes.
pub fn strEmbraceWith(alloc: Allocator, str: []const u8, pre: []const u8, post: []const u8) !std.ArrayList(u8) {
    var out = try std.ArrayList(u8).initCapacity(alloc, str.len + pre.len + post.len);
    out.appendSliceAssumeCapacity(pre);
    out.appendSliceAssumeCapacity(str);
    out.appendSliceAssumeCapacity(post);
    return out;
}

test strEmbraceWith {
    const run = struct {
        pub fn case(expect: []const u8, actual: []const u8, arg: struct { pre: []const u8, post: []const u8 }) !void {
            var out = try strEmbraceWith(std.testing.allocator, actual, arg.pre, arg.post);
            defer out.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(expect, out.items);
        }
    };

    try run.case("[]", "", .{ .pre = "[", .post = "]" });
    try run.case("[Hello world]", "Hello world", .{ .pre = "[", .post = "]" });
}

/// Trims the string if its length exceeds the maximum, appending the `dots`
/// according to the logic of the `mode`. If `max` is 0, the function does
/// not truncate. (Function is comptime only)
///
/// Function provides three `mode`s:
///   - in: Truncate the `str` and try to fit `dots` inside, or omit.
///   - out: Truncate the `str` and try to fit `dots` outside, or omit.
///   - auto: Truncate the `str` and try to fit `dots` outside, inside, or omit.
fn strTrimCt(str: []const u8, max: usize, dots: []const u8, mode: enum { in, out, auto }) []const u8 {
    if (!@inComptime()) @compileError("Must be called at comptime.");
    if (max == 0 or max >= str.len) return str;
    switch (mode) {
        .in => {
            if (dots.len <= max) // dots fit inside
                return str[0 .. max - dots.len] ++ dots
            else
                return str[0..max]; // omit
        },
        .out => {
            if (dots.len + max <= str.len) // dots fit outside
                return str[0..max] ++ dots
            else
                return str[0..max]; // omit
        },
        .auto => {
            if (dots.len + max <= str.len) // outside
                return str[0..max] ++ dots
            else if (dots.len <= max) // inside
                return str[0 .. max - dots.len] ++ dots
            else
                return str[0..max]; // omit
        },
    }
    unreachable;
}

/// Trims the string if its length exceeds the maximum. For const `"literal"`
/// strings, the copy will be created. See `trimStrCT()` for more details.
fn strTrim(alloc: std.mem.Allocator, str: []const u8, max: usize, dots: []const u8, mode: enum { in, out, auto }) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    if (max == 0 or max >= str.len) {
        try out.appendSlice(alloc, str); // just copy
    } else {
        switch (mode) {
            .in => {
                if (dots.len <= max) { // dots fit inside
                    try out.appendSlice(alloc, str[0 .. max - dots.len]);
                    try out.appendSlice(alloc, dots);
                } else try out.appendSlice(alloc, str[0..max]); // omit
            },
            .out => {
                if (dots.len + max <= str.len) { // dots fit outside
                    try out.appendSlice(alloc, str[0..max]);
                    try out.appendSlice(alloc, dots);
                } else try out.appendSlice(alloc, str[0..max]); // omit
            },
            .auto => {
                if (dots.len + max <= str.len) { // dots fit outside
                    try out.appendSlice(alloc, str[0..max]);
                    try out.appendSlice(alloc, dots);
                } else if (dots.len <= max) { // dots fit inside
                    try out.appendSlice(alloc, str[0 .. max - dots.len]);
                    try out.appendSlice(alloc, dots);
                } else try out.appendSlice(alloc, str[0..max]);
            },
        }
    }
    return out;
}

test strTrim {
    const run = struct {
        pub fn case(expect: []const u8, comptime str: []const u8, comptime max: usize, comptime with: []const u8, mode: @TypeOf(.e)) !void {
            try std.testing.expectEqualStrings(expect, comptime strTrimCt(str, max, with, mode));
            var out = try strTrim(std.testing.allocator, str, max, with, mode);
            defer out.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(expect, out.items);
        }
    };

    // any mode
    try run.case("abcd", "abcd", 5, "..", .in);

    try run.case("abcd", "abcd", 4, "..", .in);
    try run.case("a..", "abcd", 3, "..", .in);
    try run.case("..", "abcd", 2, "..", .in);
    try run.case("a", "abcd", 1, "..", .in);
    try run.case("abcd", "abcd", 0, "..", .in);

    try run.case("abcd", "abcd", 4, "..", .out);
    try run.case("abc", "abcd", 3, "..", .out);
    try run.case("ab..", "abcd", 2, "..", .out);
    try run.case("a..", "abcd", 1, "..", .out);
    try run.case("abcd", "abcd", 0, "..", .out);

    try run.case("abcd", "abcd", 4, "..", .auto);
    try run.case("a..", "abcd", 3, "..", .auto);
    try run.case("ab..", "abcd", 2, "..", .auto);
    try run.case("a..", "abcd", 1, "..", .auto);
    try run.case("abcd", "abcd", 0, "..", .auto);

    try run.case("ab", "abcd", 2, ".....", .in); // dots do not fit
    try run.case("ab", "abcd", 2, ".....", .out); // dots do not fit
    try run.case("ab", "abcd", 2, ".....", .auto); // dots do not fit
}

/// Implementation of a basic stack.
fn Stack(comptime T: type, comptime length: usize) type {
    return struct {
        const Self = @This();

        stack: [length]T = undefined,
        top: usize = 0,
        nil: bool = true,

        pub fn empty(self: *Self) bool {
            return self.nil;
        }

        pub fn cap(self: *Self) usize {
            return self.stack.len;
        }

        pub fn left(self: *Self) usize {
            return self.cap() - self.len();
        }

        pub fn len(self: *Self) usize {
            return self.top;
        }

        pub fn fits(self: *Self, count: usize) bool {
            return self.left() >= count;
        }

        pub fn push(self: *Self, val: T) bool {
            if (length == 0) return false; // comptime

            if (!self.fits(1)) return false;
            self.stack[self.top] = val;
            self.top += 1;
            self.nil = false;
            return true;
        }

        pub fn pop(self: *Self) ?T {
            if (length == 0) return null; // comptime

            if (self.nil) return null;
            self.top -= 1;
            if (self.top == 0) self.nil = true;
            return self.stack[self.top];
        }
    };
}

test Stack {
    const equal = std.testing.expectEqual;
    {
        var stack = Stack(usize, 0){};
        try equal(0, stack.cap());
        try equal(true, stack.empty());
        try equal(false, stack.push(42)); // push beyond cap
        try equal(null, stack.pop()); // pop beyond len
        try equal(true, stack.empty());
    }
    {
        var stack = Stack(usize, 1){};
        try equal(1, stack.cap());
        try equal(true, stack.empty());

        try equal(true, stack.push(42));
        try equal(false, stack.empty());
        try equal(false, stack.push(42)); // push beyond cap

        try equal(42, stack.pop());
        try equal(true, stack.empty());
        try equal(null, stack.pop()); // pop beyond len
    }
    {
        const stack_size = 100;
        var stack = Stack(usize, stack_size){};

        try equal(stack_size, stack.cap());

        // push
        for (0..stack_size) |i| {
            try equal(i, stack.len());
            try equal(stack_size - i, stack.left());
            try equal(true, stack.push(i));
        }
        try equal(stack_size, stack.len());
        try equal(0, stack.left());

        // pop
        var i: usize = stack.len(); // 100
        while (i > 0) : (i -= 1) {
            try equal(i, stack.len());
            try equal(stack_size - stack.len(), stack.left());
            try equal(i - 1, stack.pop());
        }
        try equal(0, stack.len());
        try equal(stack_size, stack.left());
    }
}
