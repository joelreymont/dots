//! Main Executable of driff
const std = @import("std");
const dmp = @import("dmp.zig");

test "exe mentioned" {
    std.debug.print("hello from driff main\n", .{});
}

pub fn main() void {
    std.debug.print("driff for great justice!\n", .{});
    std.process.exit(0);
}
