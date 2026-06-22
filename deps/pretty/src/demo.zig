const std = @import("std");
// Step 0: Import pretty
const pretty = @import("pretty.zig");
const alloc = std.heap.c_allocator;

// Step 1: Define a structure
const NodePtr = *const Node;
const Node = struct {
    value: []const u8,
    // List of nullable node pointers
    next: []const ?NodePtr = &.{null},
};

pub fn main() !void {
    // Step 2: Initialize it
    const leaf = Node{ .value = "leaf" };
    var tree = Node{ .value = "root" };
    tree.next = &.{ &leaf, &leaf };

    // Step 3: Print!
    try pretty.print(alloc, tree, .{
        // To nicely stack up several prints
        .print_extra_empty_line = true,
    });

    // Step 4: Try options (eg. to reduce the output)
    try pretty.print(alloc, tree, .{
        .print_extra_empty_line = true,

        // Interpret pointers as address values
        .ptr_deref = false,
        // Do not show item indices
        .array_show_item_idx = false,
        // Do not show types
        .show_type_names = false,
        // Exclude some fields from the output
        .filter_field_names = .{ .exclude = &.{"value"} },
        // Treat optionals as primitives to inline .next items
        .prim_type_tags = .{ .include = &.{.optional} },
    });

    // Step 5: Do not print, use it as string!
    var out = try pretty.dump(alloc, tree, .{});
    defer alloc.free(out);
    std.debug.print("pretty {s}!\n", .{out[0..4]});

    // Bonus: Try the default printer instead
    // std.debug.print("\n{any}\n", .{tree});
}
