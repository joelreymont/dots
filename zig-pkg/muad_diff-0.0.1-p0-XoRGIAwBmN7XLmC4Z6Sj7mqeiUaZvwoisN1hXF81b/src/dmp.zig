// MIT License
//
// Copyright (c) 2023 diffz authors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const DiffMatchPatch = @This();

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.array_list.Managed;
pub const DiffList = ArrayListUnmanaged(Edit);
pub const Patch = ArrayListUnmanaged(Hunk);

pub const DiffError = error{
    OutOfMemory,
    BadPatchString,
};

const OutOfMemory = error.OutOfMemory;

//| Fields

/// Number of milliseconds to map a diff before giving up (0 for infinity).
diff_timeout: u64 = 1000,
/// Cost of an empty edit operation in terms of edit characters.
diff_edit_cost: u16 = 4,

/// Number of bytes in each string needed to trigger a line-based diff
diff_check_lines_over: u64 = 100,

/// At what point is no match declared (0.0 = perfection, 1.0 = very loose).
/// This defaults to 0.05, on the premise that the library will mostly be
/// used in cases where failure is better than a bad patch application.
match_threshold: f64 = 0.05,

/// How far to search for a match (0 = exact location, 1000+ = broad match).
/// A match this many characters away from the expected location will add
/// 1.0 to the score (0.0 is a perfect match).
match_distance: u32 = 1000,

/// The number of bits in a usize.
match_max_bits: u8 = @bitSizeOf(usize),

/// When deleting a large block of text (over ~64 characters), how close
/// do the contents have to be to match the expected contents. (0.0 =
/// perfection, 1.0 = very loose).  Note that Match_Threshold controls
/// how closely the end points of a delete need to match.
patch_delete_threshold: f32 = 0.5,

/// Chunk size for context length.
patch_margin: u8 = 4,

//| Allocation Management Helpers

/// Deinit an `ArrayListUnmanaged(Diff)` and the allocated slices of
/// text in each `Diff`.
pub fn deinitDiffList(allocator: Allocator, diffs: *DiffList) void {
    defer diffs.deinit(allocator);
    for (diffs.items) |d| {
        allocator.free(d.text);
    }
}

/// Free a range of Diffs inside a list.  Used during cleanups and
/// edits.
fn freeRangeDiffList(
    allocator: Allocator,
    diffs: *DiffList,
    start: usize,
    len: usize,
) void {
    const after_range = start + len;
    const range = diffs.items[start..after_range];
    for (range) |d| {
        allocator.free(d.text);
    }
}

pub fn deinitPatchList(allocator: Allocator, patches: *Patch) void {
    defer patches.deinit(allocator);
    for (patches.items) |*a_patch| {
        deinitDiffList(allocator, &a_patch.diffs);
    }
}

/// DMP with default configuration options
pub const default = DiffMatchPatch{};

/// Represents a single edit operation.
pub const Edit = struct {
    pub const Operation = enum {
        insert,
        delete,
        equal,
    };

    // TODO: The algorithm as a whole requires some text to be copied,
    // at least it does without some very heavyweight reimagination.
    // But not all.  Since this is aligned with a slice, it's three
    // usize, and our enum is tiny, so we can add a boolean recording
    // copy status 'for free' and use views for the great majority of
    // text.

    operation: Operation,
    text: []const u8,

    pub fn format(value: Edit, writer: anytype) !void {
        try writer.print("({s}, \"{s}\")", .{
            switch (value.operation) {
                .equal => "=",
                .insert => "+",
                .delete => "-",
            },
            value.text,
        });
    }

    pub fn init(operation: Operation, text: []const u8) Edit {
        return .{ .operation = operation, .text = text };
    }
    pub fn eql(a: Edit, b: Edit) bool {
        return a.operation == b.operation and std.mem.eql(u8, a.text, b.text);
    }

    pub fn clone(self: Edit, allocator: Allocator) !Edit {
        return Edit{
            .operation = self.operation,
            .text = try allocator.dupe(u8, self.text),
        };
    }
};

/// Represents a single operation in a Patch.
pub const Hunk = struct {
    /// Diff to be applied
    diffs: DiffList = .empty,
    /// Start of patch in before text
    start1: usize = 0,
    length1: usize = 0,
    /// Start of patch in after text
    start2: usize = 0,
    length2: usize = 0,

    pub const empty: Hunk = .{};

    /// Make a clone of the Hunk, including the Diff.
    pub fn clone(patch: Hunk, allocator: Allocator) !Hunk {
        var new_diffs: DiffList = .empty;
        try new_diffs.ensureTotalCapacity(allocator, patch.diffs.items.len);
        errdefer {
            deinitDiffList(allocator, &new_diffs);
        }
        for (patch.diffs.items) |a_diff| {
            new_diffs.appendAssumeCapacity(try a_diff.clone(allocator));
        }
        return Hunk{
            .diffs = new_diffs,
            .start1 = patch.start1,
            .length1 = patch.length1,
            .start2 = patch.start2,
            .length2 = patch.length2,
        };
    }

    pub fn deinit(patch: *Hunk, allocator: Allocator) void {
        deinitDiffList(allocator, &patch.diffs);
    }

    /// Emit patch hunk in Unidiff format, as specifified here:
    /// https://github.com/google/diff-match-patch/wiki/Unidiff
    /// This is similar to GNU Unidiff format, but not identical.
    /// Header: @@ -382,8 +481,9 @@
    /// Indices are printed as 1-based, not 0-based.
    /// @return The GNU diff string.
    pub fn asText(patch: Hunk, allocator: Allocator) ![]const u8 {
        var text_array = ArrayList(u8).init(allocator);
        defer text_array.deinit();
        const writer = text_array.writer();
        try patch.writeText(writer);
        return text_array.toOwnedSlice();
    }

    const format = std.fmt.format;

    /// Stream textual patch representation to Writer.  See `asText`
    /// for more information.
    pub fn writeText(patch: Hunk, writer: anytype) !void {
        // Write header.
        _ = try writer.write(PATCH_HEAD);
        // Stream coordinates
        if (patch.length1 == 0) {
            try format(writer, "{d},0", .{patch.start1});
        } else if (patch.length1 == 1) {
            try format(writer, "{d}", .{patch.start1 + 1});
        } else {
            try format(writer, "{d},{d}", .{ patch.start1 + 1, patch.length1 });
        }
        _ = try writer.write(" +");
        if (patch.length2 == 0) {
            try std.fmt.format(writer, "{d},0", .{patch.start2});
        } else if (patch.length2 == 1) {
            _ = try format(writer, "{d}", .{patch.start2 + 1});
        } else {
            try format(writer, "{d},{d}", .{ patch.start2 + 1, patch.length2 });
        }
        _ = try writer.write(PATCH_TAIL);
        // Escape the body of the patch with %xx notation.
        for (patch.diffs.items) |a_diff| {
            switch (a_diff.operation) {
                .insert => try writer.writeByte('+'),
                .delete => try writer.writeByte('-'),
                .equal => try writer.writeByte(' '),
            }
            _ = try writeUriEncoded(writer, a_diff.text);
            try writer.writeByte('\n');
        }
        return;
    }
};

const PATCH_HEAD = "@@ -";
const PATCH_TAIL = " @@\n";

/// Find the differences between two texts.
/// @param before Old string to be diffed.
/// @param after New string to be diffed.
/// @param checklines Speedup flag.  If false, then don't run a
///     line-level diff first to identify the changed areas.
///     If true, then run a faster slightly less optimal diff.
/// @return List of Diff objects.
pub fn diff(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    /// If false, then don't run a line-level diff first
    /// to identify the changed areas. If true, then run
    /// a faster slightly less optimal diff.
    check_lines: bool,
) error{OutOfMemory}!DiffList {
    const deadline = if (dmp.diff_timeout == 0)
        std.math.maxInt(u64)
    else
        @as(u64, @intCast(std.time.milliTimestamp())) + dmp.diff_timeout;
    return dmp.diffInternal(allocator, before, after, check_lines, deadline);
}

fn diffInternal(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    check_lines: bool,
    deadline: u64,
) error{OutOfMemory}!DiffList {
    // Check for equality (speedup).
    if (std.mem.eql(u8, before, after)) {
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        if (before.len != 0) {
            try diffs.ensureUnusedCapacity(allocator, 1);
            diffs.appendAssumeCapacity(Edit.init(
                .equal,
                try allocator.dupe(u8, before),
            ));
        }
        return diffs;
    }

    // Trim off common prefix (speedup).
    var common_length = diffCommonPrefix(before, after);
    const common_prefix = before[0..common_length];
    var trimmed_before = before[common_length..];
    var trimmed_after = after[common_length..];

    // Trim off common suffix (speedup).
    common_length = diffCommonSuffix(trimmed_before, trimmed_after);
    const common_suffix = trimmed_before[trimmed_before.len - common_length ..];
    trimmed_before = trimmed_before[0 .. trimmed_before.len - common_length];
    trimmed_after = trimmed_after[0 .. trimmed_after.len - common_length];

    // Compute the diff on the middle block.
    var diffs = try dmp.diffCompute(allocator, trimmed_before, trimmed_after, check_lines, deadline);
    errdefer deinitDiffList(allocator, &diffs);

    // Restore the prefix and suffix.
    if (common_prefix.len != 0) {
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.insertAssumeCapacity(0, Edit.init(
            .equal,
            try allocator.dupe(u8, common_prefix),
        ));
    }
    if (common_suffix.len != 0) {
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.appendAssumeCapacity(Edit.init(
            .equal,
            try allocator.dupe(u8, common_suffix),
        ));
    }
    try diffCleanupMerge(allocator, &diffs);
    return diffs;
}

/// Test if a byte is a UTF-8 follow byte
inline fn is_follow(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

/// Find a common prefix which respects UTF-8 code point boundaries.
fn diffCommonPrefix(before: []const u8, after: []const u8) usize {
    const n = @min(before.len, after.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const b = before[i];
        const a = after[i];
        if (a != b) {
            return fixSplitBackward(before, i);
        }
    }

    return n;
}

/// Find a common suffix which respects UTF-8 code point boundaries
fn diffCommonSuffix(before: []const u8, after: []const u8) usize {
    const n = @min(before.len, after.len);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const b = before[before.len - i];
        const a = after[after.len - i];
        if (a != b) {
            return before.len - fixSplitForward(before, before.len - i + 1);
        }
    }

    return n;
}

/// Find the differences between two texts.  Assumes that the texts do not
/// have any common prefix or suffix.
/// @param before Old string to be diffed.
/// @param after New string to be diffed.
/// @param checklines Speedup flag.  If false, then don't run a
///     line-level diff first to identify the changed areas.
///     If true, then run a faster slightly less optimal diff.
/// @param deadline Time when the diff should be complete by.
/// @return List of Diff objects.
fn diffCompute(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    check_lines: bool,
    deadline: u64,
) error{OutOfMemory}!DiffList {
    if (before.len == 0) {
        // Just add some text (speedup).
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.appendAssumeCapacity(Edit.init(
            .insert,
            try allocator.dupe(u8, after),
        ));
        return diffs;
    }

    if (after.len == 0) {
        // Just delete some text (speedup).
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.appendAssumeCapacity(Edit.init(
            .delete,
            try allocator.dupe(u8, before),
        ));
        return diffs;
    }

    const long_text = if (before.len > after.len) before else after;
    const short_text = if (before.len > after.len) after else before;

    if (std.mem.indexOf(u8, long_text, short_text)) |index| {
        // Shorter text is inside the longer text (speedup).
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        const op: Edit.Operation = if (before.len > after.len)
            .delete
        else
            .insert;
        try diffs.ensureUnusedCapacity(allocator, 3);
        diffs.appendAssumeCapacity(Edit.init(
            op,
            try allocator.dupe(u8, long_text[0..index]),
        ));
        diffs.appendAssumeCapacity(Edit.init(
            .equal,
            try allocator.dupe(u8, short_text),
        ));
        diffs.appendAssumeCapacity(Edit.init(
            op,
            try allocator.dupe(u8, long_text[index + short_text.len ..]),
        ));
        return diffs;
    }

    if (short_text.len == 1) {
        // Single character string.
        // After the previous speedup, the character can't be an equality.
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 2);
        diffs.appendAssumeCapacity(Edit.init(
            .delete,
            try allocator.dupe(u8, before),
        ));
        diffs.appendAssumeCapacity(Edit.init(
            .insert,
            try allocator.dupe(u8, after),
        ));
        return diffs;
    }

    // Check to see if the problem can be split in two.
    var maybe_half_match = try dmp.diffHalfMatch(allocator, before, after);
    defer if (maybe_half_match) |half_match| half_match.deinit(allocator);
    if (maybe_half_match) |*half_match| {
        // A half-match was found, sort out the return data.
        // Send both pairs off for separate processing.
        var diffs = try dmp.diffInternal(
            allocator,
            half_match.prefix_before,
            half_match.prefix_after,
            check_lines,
            deadline,
        );
        errdefer deinitDiffList(allocator, &diffs);
        var diffs_b = try dmp.diffInternal(
            allocator,
            half_match.suffix_before,
            half_match.suffix_after,
            check_lines,
            deadline,
        );
        defer diffs_b.deinit(allocator);
        // we have to deinit regardless, so deinitDiffList would be
        // a double free:
        errdefer {
            for (diffs_b.items) |d| {
                allocator.free(d.text);
            }
        }

        // Merge the results.
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.appendAssumeCapacity(
            Edit.init(.equal, half_match.common_middle),
        );
        half_match.common_middle = "";
        try diffs.appendSlice(allocator, diffs_b.items);
        return diffs;
    }

    if (check_lines and before.len > dmp.diff_check_lines_over and after.len > dmp.diff_check_lines_over) {
        return dmp.diffLineMode(allocator, before, after, deadline);
    }
    return dmp.diffBisect(allocator, before, after, deadline);
}

const HalfMatchResult = struct {
    prefix_before: []const u8,
    suffix_before: []const u8,
    prefix_after: []const u8,
    suffix_after: []const u8,
    common_middle: []const u8,

    // Free the HalfMatchResult's memory.
    pub fn deinit(hmr: HalfMatchResult, allocator: Allocator) void {
        allocator.free(hmr.prefix_before);
        allocator.free(hmr.suffix_before);
        allocator.free(hmr.prefix_after);
        allocator.free(hmr.suffix_after);
        allocator.free(hmr.common_middle);
    }
};

/// Do the two texts share a Substring which is at least half the length of
/// the longer text?
/// This speedup can produce non-minimal diffs.
/// @param before First string.
/// @param after Second string.
/// @return Five element String array, containing the prefix of text1, the
///     suffix of text1, the prefix of text2, the suffix of text2 and the
///     common middle.  Or null if there was no match.
fn diffHalfMatch(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
) error{OutOfMemory}!?HalfMatchResult {
    if (dmp.diff_timeout == 0) {
        // Don't risk returning a non-optimal diff if we have unlimited time.
        return null;
    }
    const long_text = if (before.len > after.len) before else after;
    const short_text = if (before.len > after.len) after else before;

    if (long_text.len < 4 or short_text.len * 2 < long_text.len) {
        return null; // Pointless.
    }

    // First check if the second quarter is the seed for a half-match.
    const half_match_1 = try dmp.diffHalfMatchInternal(allocator, long_text, short_text, (long_text.len + 3) / 4);
    errdefer {
        if (half_match_1) |h_m| h_m.deinit(allocator);
    }
    // Check again based on the third quarter.
    const half_match_2 = try dmp.diffHalfMatchInternal(allocator, long_text, short_text, (long_text.len + 1) / 2);
    errdefer {
        if (half_match_2) |h_m| h_m.deinit(allocator);
    }

    var half_match: ?HalfMatchResult = null;
    if (half_match_1 == null and half_match_2 == null) {
        return null;
    } else if (half_match_2 == null) {
        half_match = half_match_1.?;
    } else if (half_match_1 == null) {
        half_match = half_match_2.?;
    } else {
        // Both matched. Select the longest.
        half_match = half: {
            if (half_match_1.?.common_middle.len > half_match_2.?.common_middle.len) {
                half_match_2.?.deinit(allocator);
                break :half half_match_1;
            } else {
                half_match_1.?.deinit(allocator);
                break :half half_match_2;
            }
        };
    }

    // A half-match was found, sort out the return data.
    if (before.len > after.len) {
        return half_match.?;
    } else {
        // Transfers ownership of all memory to new, permuted, half_match.
        const half_match_yes = half_match.?;
        return .{
            .prefix_before = half_match_yes.prefix_after,
            .suffix_before = half_match_yes.suffix_after,
            .prefix_after = half_match_yes.prefix_before,
            .suffix_after = half_match_yes.suffix_before,
            .common_middle = half_match_yes.common_middle,
        };
    }
}

/// Does a Substring of shorttext exist within longtext such that the
/// Substring is at least half the length of longtext?
/// @param longtext Longer string.
/// @param shorttext Shorter string.
/// @param i Start index of quarter length Substring within longtext.
/// @return Five element string array, containing the prefix of longtext, the
///     suffix of longtext, the prefix of shorttext, the suffix of shorttext
///     and the common middle.  Or null if there was no match.
fn diffHalfMatchInternal(
    _: DiffMatchPatch,
    allocator: std.mem.Allocator,
    long_text: []const u8,
    short_text: []const u8,
    i: usize,
) error{OutOfMemory}!?HalfMatchResult {
    // Start with a 1/4 length Substring at position i as a seed.
    const seed = long_text[i .. i + long_text.len / 4];
    var j: isize = -1;

    // TODO: this array list is absolutely not needed
    var best_common = ArrayListUnmanaged(u8){};
    defer best_common.deinit(allocator);
    var best_long_text_a: []const u8 = "";
    var best_long_text_b: []const u8 = "";
    var best_short_text_a: []const u8 = "";
    var best_short_text_b: []const u8 = "";

    while (j < short_text.len and b: {
        j = @as(isize, @intCast(std.mem.indexOf(u8, short_text[@as(usize, @intCast(j + 1))..], seed) orelse break :b false)) + j + 1;
        break :b true;
    }) {
        const prefix_length = diffCommonPrefix(long_text[i..], short_text[@as(usize, @intCast(j))..]);
        const suffix_length = diffCommonSuffix(long_text[0..i], short_text[0..@as(usize, @intCast(j))]);
        if (best_common.items.len < suffix_length + prefix_length) {
            best_common.items.len = 0;
            // TODO: This is nuts in here, clean up.
            const a = short_text[@as(usize, @intCast(j - @as(isize, @intCast(suffix_length)))) .. @as(usize, @intCast(j - @as(isize, @intCast(suffix_length)))) + suffix_length];
            try best_common.appendSlice(allocator, a);
            const b = short_text[@as(usize, @intCast(j)) .. @as(usize, @intCast(j)) + prefix_length];
            try best_common.appendSlice(allocator, b);
            // short_text[j - suffix_length .. j + prefix_length]... right?
            assert(std.mem.eql(u8, best_common.items, short_text[@as(usize, @intCast(j - @as(isize, @intCast(suffix_length)))) .. @as(usize, @intCast(j)) + prefix_length]));
            // Looks like it ¯\_(ツ)_/¯

            best_long_text_a = long_text[0 .. i - suffix_length];
            best_long_text_b = long_text[i + prefix_length ..];
            best_short_text_a = short_text[0..@as(usize, @intCast(j - @as(isize, @intCast(suffix_length))))];
            best_short_text_b = short_text[@as(usize, @intCast(j + @as(isize, @intCast(prefix_length))))..];
        }
    }
    if (best_common.items.len * 2 >= long_text.len) {
        const prefix_before = try allocator.dupe(u8, best_long_text_a);
        errdefer allocator.free(prefix_before);
        const suffix_before = try allocator.dupe(u8, best_long_text_b);
        errdefer allocator.free(suffix_before);
        const prefix_after = try allocator.dupe(u8, best_short_text_a);
        errdefer allocator.free(prefix_after);
        const suffix_after = try allocator.dupe(u8, best_short_text_b);
        errdefer allocator.free(suffix_after);
        const best_common_text = try best_common.toOwnedSlice(allocator);
        errdefer allocator.free(best_common_text);
        return .{
            .prefix_before = prefix_before,
            .suffix_before = suffix_before,
            .prefix_after = prefix_after,
            .suffix_after = suffix_after,
            .common_middle = best_common_text,
        };
    } else {
        return null;
    }
}

/// Find the 'middle snake' of a diff, split the problem in two
/// and return the recursively constructed diff.
/// See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.
/// @param before Old string to be diffed.
/// @param after New string to be diffed.
/// @param deadline Time at which to bail if not yet complete.
/// @return List of Diff objects.
fn diffBisect(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    deadline: u64,
) error{OutOfMemory}!DiffList {
    const before_length: isize = @intCast(before.len);
    const after_length: isize = @intCast(after.len);
    const max_d: isize = @intCast((before.len + after.len + 1) / 2);
    const v_offset = max_d;
    const v_length = 2 * max_d;

    var v1 = try ArrayListUnmanaged(isize).initCapacity(allocator, @as(usize, @intCast(v_length)));
    defer v1.deinit(allocator);
    v1.items.len = @intCast(v_length);
    var v2 = try ArrayListUnmanaged(isize).initCapacity(allocator, @as(usize, @intCast(v_length)));
    defer v2.deinit(allocator);
    v2.items.len = @intCast(v_length);

    var x: usize = 0;
    while (x < v_length) : (x += 1) {
        v1.items[x] = -1;
        v2.items[x] = -1;
    }
    v1.items[@intCast(v_offset + 1)] = 0;
    v2.items[@intCast(v_offset + 1)] = 0;
    const delta = before_length - after_length;
    // If the total number of characters is odd, then the front path will
    // collide with the reverse path.
    const front = (@mod(delta, 2) != 0);
    // Offsets for start and end of k loop.
    // Prevents mapping of space beyond the grid.
    var k1start: isize = 0;
    var k1end: isize = 0;
    var k2start: isize = 0;
    var k2end: isize = 0;

    var d: isize = 0;
    while (d < max_d) : (d += 1) {
        // Bail out if deadline is reached.
        if (@as(u64, @intCast(std.time.milliTimestamp())) > deadline) {
            break;
        }

        // Walk the front path one step.
        var k1 = -d + k1start;
        while (k1 <= d - k1end) : (k1 += 2) {
            const k1_offset = v_offset + k1;
            var x1: isize = 0;
            if (k1 == -d or (k1 != d and
                v1.items[@intCast(k1_offset - 1)] < v1.items[@intCast(k1_offset + 1)]))
            {
                x1 = v1.items[@intCast(k1_offset + 1)];
            } else {
                x1 = v1.items[@intCast(k1_offset - 1)] + 1;
            }
            var y1 = x1 - k1;
            while (x1 < before_length and y1 < after_length) {
                if (before[@intCast(x1)] == after[@intCast(y1)]) {
                    x1 += 1;
                    y1 += 1;
                } else {
                    break;
                }
            }
            v1.items[@intCast(k1_offset)] = x1;
            if (x1 > before_length) {
                // Ran off the right of the graph.
                k1end += 2;
            } else if (y1 > after_length) {
                // Ran off the bottom of the graph.
                k1start += 2;
            } else if (front) {
                const k2_offset = v_offset + delta - k1;
                if (k2_offset >= 0 and k2_offset < v_length and v2.items[@intCast(k2_offset)] != -1) {
                    // Mirror x2 onto top-left coordinate system.
                    const x2 = before_length - v2.items[@intCast(k2_offset)];
                    if (x1 >= x2) {
                        // Overlap detected.
                        return dmp.diffBisectSplit(allocator, before, after, x1, y1, deadline);
                    }
                }
            }
        }

        // Walk the reverse path one step.
        var k2: isize = -d + k2start;
        while (k2 <= d - k2end) : (k2 += 2) {
            const k2_offset = v_offset + k2;
            var x2: isize = 0;
            if (k2 == -d or (k2 != d and
                v2.items[@intCast(k2_offset - 1)] < v2.items[@intCast(k2_offset + 1)]))
            {
                x2 = v2.items[@intCast(k2_offset + 1)];
            } else {
                x2 = v2.items[@intCast(k2_offset - 1)] + 1;
            }
            var y2: isize = x2 - k2;
            while (x2 < before_length and y2 < after_length) {
                if (before[@intCast(before_length - x2 - 1)] == after[@intCast(after_length - y2 - 1)]) {
                    x2 += 1;
                    y2 += 1;
                } else {
                    break;
                }
            }
            v2.items[@intCast(k2_offset)] = x2;
            if (x2 > before_length) {
                // Ran off the left of the graph.
                k2end += 2;
            } else if (y2 > after_length) {
                // Ran off the top of the graph.
                k2start += 2;
            } else if (!front) {
                const k1_offset = v_offset + delta - k2;
                if (k1_offset >= 0 and k1_offset < v_length and v1.items[@intCast(k1_offset)] != -1) {
                    const x1 = v1.items[@intCast(k1_offset)];
                    const y1 = v_offset + x1 - k1_offset;
                    // Mirror x2 onto top-left coordinate system.
                    x2 = before_length - v2.items[@intCast(k2_offset)];
                    if (x1 >= x2) {
                        // Overlap detected.
                        return dmp.diffBisectSplit(allocator, before, after, x1, y1, deadline);
                    }
                }
            }
        }
    }
    // Diff took too long and hit the deadline or
    // number of diffs equals number of characters, no commonality at all.
    var diffs: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diffs);
    try diffs.ensureUnusedCapacity(allocator, 2);
    diffs.appendAssumeCapacity(Edit.init(
        .delete,
        try allocator.dupe(u8, before),
    ));
    diffs.appendAssumeCapacity(Edit.init(
        .insert,
        try allocator.dupe(u8, after),
    ));
    return diffs;
}

/// Given the location of the 'middle snake', split the diff in two parts
/// and recurse.
/// @param text1 Old string to be diffed.
/// @param text2 New string to be diffed.
/// @param x Index of split point in text1.
/// @param y Index of split point in text2.
/// @param deadline Time at which to bail if not yet complete.
/// @return LinkedList of Diff objects.
fn diffBisectSplit(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    text1: []const u8,
    text2: []const u8,
    x: isize,
    y: isize,
    deadline: u64,
) error{OutOfMemory}!DiffList {
    const x1 = fixSplitForward(text1, @intCast(x));
    const y1 = fixSplitBackward(text2, @intCast(y));
    const text1a = text1[0..x1];
    const text2a = text2[0..y1];
    const text1b = text1[x1..];
    const text2b = text2[y1..];

    if (text1a.len == 0 and text2a.len == 0) {
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 2);
        diffs.appendAssumeCapacity(Edit.init(
            .delete,
            try allocator.dupe(
                u8,
                text1b,
            ),
        ));
        diffs.appendAssumeCapacity(Edit.init(
            .insert,
            try allocator.dupe(
                u8,
                text2b,
            ),
        ));
        return diffs;
    } else if (text1b.len == 0 and text2b.len == 0) {
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 2);
        diffs.appendAssumeCapacity(Edit.init(
            .delete,
            try allocator.dupe(
                u8,
                text2b,
            ),
        ));
        diffs.appendAssumeCapacity(Edit.init(
            .insert,
            try allocator.dupe(
                u8,
                text2a,
            ),
        ));
        return diffs;
    }

    // Compute both diffs serially.
    var diffs = try dmp.diffInternal(allocator, text1a, text2a, false, deadline);
    errdefer deinitDiffList(allocator, &diffs);
    var diffs_b = try dmp.diffInternal(allocator, text1b, text2b, false, deadline);
    // Free the list, but not the contents:
    defer diffs_b.deinit(allocator);
    errdefer {
        for (diffs_b.items) |d| {
            allocator.free(d.text);
        }
    }
    try diffs.appendSlice(allocator, diffs_b.items);
    return diffs;
}

/// Do a quick line-level diff on both strings, then rediff the parts for
/// greater accuracy.
/// This speedup can produce non-minimal diffs.
/// @param text1 Old string to be diffed.
/// @param text2 New string to be diffed.
/// @param deadline Time when the diff should be complete by.
/// @return List of Diff objects.
fn diffLineMode(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    text1_in: []const u8,
    text2_in: []const u8,
    deadline: u64,
) error{OutOfMemory}!DiffList {
    // Scan the text on a line-by-line basis first.
    var a = try diffLinesToChars(allocator, text1_in, text2_in);
    defer a.deinit(allocator);
    const text1 = a.chars_1;
    const text2 = a.chars_2;
    const line_array = a.line_array;
    var diffs: DiffList = diff_munge: {
        var char_diffs: DiffList = try dmp.diffInternal(allocator, text1, text2, false, deadline);
        defer deinitDiffList(allocator, &char_diffs);
        // Convert the diff back to original text.
        break :diff_munge try diffCharsToLines(allocator, &char_diffs, line_array.items);
    };
    errdefer deinitDiffList(allocator, &diffs);
    // Eliminate freak matches (e.g. blank lines)
    try diffCleanupSemantic(allocator, &diffs);

    // Rediff any replacement blocks, this time character-by-character.
    // Add a dummy entry at the end.
    try diffs.append(allocator, Edit.init(.equal, ""));

    var pointer: usize = 0;
    var count_delete: usize = 0;
    var count_insert: usize = 0;
    var text_delete = ArrayListUnmanaged(u8){};
    var text_insert = ArrayListUnmanaged(u8){};
    defer {
        text_delete.deinit(allocator);
        text_insert.deinit(allocator);
    }

    while (pointer < diffs.items.len) {
        switch (diffs.items[pointer].operation) {
            .insert => {
                count_insert += 1;
                try text_insert.appendSlice(allocator, diffs.items[pointer].text);
            },
            .delete => {
                count_delete += 1;
                try text_delete.appendSlice(allocator, diffs.items[pointer].text);
            },
            .equal => {
                // Upon reaching an equality, check for prior redundancies.
                if (count_delete >= 1 and count_insert >= 1) {
                    // Delete the offending records and add the merged ones.
                    freeRangeDiffList(
                        allocator,
                        &diffs,
                        pointer - count_delete - count_insert,
                        count_delete + count_insert,
                    );
                    try diffs.replaceRange(
                        allocator,
                        pointer - count_delete - count_insert,
                        count_delete + count_insert,
                        &.{},
                    );
                    pointer = pointer - count_delete - count_insert;
                    var sub_diff = try dmp.diffInternal(
                        allocator,
                        text_delete.items,
                        text_insert.items,
                        false,
                        deadline,
                    );
                    {
                        errdefer deinitDiffList(allocator, &sub_diff);
                        try diffs.ensureUnusedCapacity(allocator, sub_diff.items.len);
                    }
                    defer sub_diff.deinit(allocator);
                    const new_diff = diffs.addManyAtAssumeCapacity(pointer, sub_diff.items.len);
                    @memcpy(new_diff, sub_diff.items);
                    pointer = pointer + sub_diff.items.len;
                }
                count_insert = 0;
                count_delete = 0;
                text_delete.items.len = 0;
                text_insert.items.len = 0;
            },
        }
        pointer += 1;
    }
    diffs.items.len -= 1; // Remove the dummy entry at the end.

    return diffs;
}

// These numbers have a 32 point buffer, to avoid annoyance with
// c0 control characters.  The algorithm drops the bottom points,
// not the top, that is, it will use 0x10ffff given enough unique
// lines.
const UNICODE_MAX = 0x10ffdf;
const UNICODE_TWO_THIRDS = 742724;
const UNICODE_ONE_THIRD = 371355;
const CHAR_OFFSET = 32;

comptime {
    assert(UNICODE_TWO_THIRDS + UNICODE_ONE_THIRD == UNICODE_MAX);
    assert(UNICODE_TWO_THIRDS + UNICODE_ONE_THIRD + CHAR_OFFSET == 0x10ffff);
}

/// Split two texts into a list of strings.  Reduce the texts to a string of
/// hashes where each Unicode character represents one line.
/// @param text1 First string.
/// @param text2 Second string.
/// @return Three element Object array, containing the encoded text1, the
///     encoded text2 and the List of unique strings.  The zeroth element
///     of the List of unique strings is intentionally blank.
fn diffLinesToChars(
    allocator: std.mem.Allocator,
    text1: []const u8,
    text2: []const u8,
) error{OutOfMemory}!LinesToCharsResult {
    var line_array = ArrayListUnmanaged([]const u8){};
    errdefer line_array.deinit(allocator);
    line_array.items.len = 0;
    var line_hash = std.StringHashMapUnmanaged(u21){};
    defer line_hash.deinit(allocator);
    // e.g. line_array[4] == "Hello\n"
    // e.g. line_hash.get("Hello\n") == 4

    // Allocate 2/3rds of the space for text1, the rest for text2.
    const chars1 = try diffLinesToCharsMunge(allocator, text1, &line_array, &line_hash, UNICODE_TWO_THIRDS);
    errdefer allocator.free(chars1);
    const chars2 = try diffLinesToCharsMunge(allocator, text2, &line_array, &line_hash, UNICODE_ONE_THIRD);
    return .{ .chars_1 = chars1, .chars_2 = chars2, .line_array = line_array };
}

const LinesToCharsResult = struct {
    chars_1: []const u8,
    chars_2: []const u8,
    line_array: ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *LinesToCharsResult, allocator: Allocator) void {
        allocator.free(self.chars_1);
        allocator.free(self.chars_2);
        self.line_array.deinit(allocator);
    }
};

/// Split a text into a list of strings.  Reduce the texts to a string of
/// hashes where each Unicode character represents one line.
/// @param text String to encode.
/// @param lineArray List of unique strings.
/// @param lineHash Map of strings to indices.
/// @param maxLines Maximum length of lineArray.
/// @return Encoded string.
fn diffLinesToCharsMunge(
    allocator: std.mem.Allocator,
    text: []const u8,
    line_array: *ArrayListUnmanaged([]const u8),
    line_hash: *std.StringHashMapUnmanaged(u21),
    max_lines: usize,
) error{OutOfMemory}![]const u8 {
    var iter = LineIterator{ .text = text };
    return try diffIteratorToCharsMunge(
        allocator,
        line_array,
        line_hash,
        &iter,
        max_lines,
    );
}

/// Split a text into segments, yielded from an iterator.
/// Reduce the texts to a string of hashes where each Unicode character
/// represents one segment.
///
/// Iterators must provide: `next()`, which gives the next segment of
/// the test, and `short_circuit(usize)`, which is called when the
/// segment limit is reached, and returns the rest of the text.  The
/// parameter provided will be the length of the last segment provided
/// by `next()`, since the function will not process that segment, and
/// its text must be included in the remainder.
///
/// @param segment_array List of unique string segments.
/// @param line_hash Map of strings to indices into segment_array.
/// @param iterator Returns the next segment.  Must have functions
///        next(), returning the next segment, and short_circuit(),
///        called when max_segments is reached.
/// @param max_segments Maximum length of lineArray.  Limited to
///        0x10ffdf.
/// @return Encoded string.
fn diffIteratorToCharsMunge(
    allocator: std.mem.Allocator,
    segment_array: *ArrayListUnmanaged([]const u8),
    segment_hash: *std.StringHashMapUnmanaged(u21),
    iterator: anytype,
    max_segments: usize,
) error{OutOfMemory}![]const u8 {
    // Because we rebase the codepoint off the already counted segments,
    // this makes the unreachables in the function legitimate:
    assert(max_segments <= UNICODE_MAX);
    var chars = ArrayListUnmanaged(u8){};
    defer chars.deinit(allocator);
    var codepoint: u21 = CHAR_OFFSET + cast(u21, segment_array.items.len);
    var char_buf: [4]u8 = undefined;
    while (iterator.next()) |line| {
        if (segment_hash.get(line)) |value| {
            const nbytes = std.unicode.wtf8Encode(value, &char_buf) catch unreachable;
            try chars.appendSlice(allocator, char_buf[0..nbytes]);
        } else {
            if (codepoint - CHAR_OFFSET == max_segments) {
                // Bail out
                const final_line = iterator.short_circuit(line.len);
                try segment_array.append(allocator, final_line);
                try segment_hash.put(allocator, final_line, codepoint);
                const nbytes = std.unicode.wtf8Encode(codepoint, &char_buf) catch unreachable;
                try chars.appendSlice(allocator, char_buf[0..nbytes]);
                break;
            }
            try segment_array.append(allocator, line);
            try segment_hash.put(allocator, line, codepoint);
            const nbytes = std.unicode.wtf8Encode(codepoint, &char_buf) catch unreachable;
            try chars.appendSlice(allocator, char_buf[0..nbytes]);
            codepoint += 1;
        }
    }
    return try chars.toOwnedSlice(allocator);
}

/// Rehydrate the text in a diff from a string of line hashes to real lines
/// of text.
/// @param diffs List of Diff objects.
/// @param lineArray List of unique strings.
fn diffCharsToLines(
    allocator: Allocator,
    char_diffs: *DiffList,
    line_array: []const []const u8,
) error{OutOfMemory}!DiffList {
    var text = ArrayListUnmanaged(u8){};
    defer text.deinit(allocator);
    var diffs: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diffs);
    try diffs.ensureUnusedCapacity(allocator, char_diffs.items.len);
    for (char_diffs.items) |*d| {
        var cursor: usize = 0;
        while (cursor < d.text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(d.text[cursor]) catch {
                @panic("Internal decode error in diffsCharsToLines");
            };
            const cp = std.unicode.wtf8Decode(d.text[cursor..][0..cp_len]) catch {
                @panic("Internal decode error in diffCharsToLines");
            };
            try text.appendSlice(allocator, line_array[cp - CHAR_OFFSET]);
            cursor += cp_len;
        }
        diffs.appendAssumeCapacity(Edit.init(
            d.operation,
            try text.toOwnedSlice(allocator),
        ));
    }
    return diffs;
}

/// An iteration struct over lines, which includes the newline if present.
const LineIterator = struct {
    cursor: usize = 0,
    text: []const u8,

    /// Return the next line, including its newline, if one is present.
    pub fn next(iter: *LineIterator) ?[]const u8 {
        if (iter.cursor == iter.text.len) return null;
        const maybe_newline = std.mem.indexOfScalarPos(
            u8,
            iter.text,
            iter.cursor,
            '\n',
        );
        if (maybe_newline) |nl| {
            const line = iter.text[iter.cursor .. nl + 1];
            iter.cursor = nl + 1;
            return line;
        } else {
            const line = iter.text[iter.cursor..];
            iter.cursor = iter.text.len;
            return line;
        }
    }

    /// Terminate the iterator early by returning all remaining text.
    /// `back_out` parameter is how far before the cursor to slice from.
    pub fn short_circuit(iter: *LineIterator, back_out: usize) []const u8 {
        const from = iter.cursor - back_out;
        iter.cursor = iter.text.len;
        return iter.text[from..];
    }
};

/// Reorder and merge like edit sections.  Merge equalities.
/// Any edit section can move as long as it doesn't cross an equality.
/// @param diffs List of Diff objects.
fn diffCleanupMerge(allocator: std.mem.Allocator, diffs: *DiffList) error{OutOfMemory}!void {
    // Add a dummy entry at the end.
    try diffs.append(allocator, Edit.init(.equal, ""));
    var pointer: usize = 0;
    var count_delete: usize = 0;
    var count_insert: usize = 0;

    var text_delete = ArrayListUnmanaged(u8){};
    defer text_delete.deinit(allocator);

    var text_insert = ArrayListUnmanaged(u8){};
    defer text_insert.deinit(allocator);

    while (pointer < diffs.items.len) {
        switch (diffs.items[pointer].operation) {
            .insert => {
                count_insert += 1;
                try text_insert.appendSlice(allocator, diffs.items[pointer].text);
                pointer += 1;
            },
            .delete => {
                count_delete += 1;
                try text_delete.appendSlice(allocator, diffs.items[pointer].text);
                pointer += 1;
            },
            .equal => {
                // Upon reaching an equality, check for prior redundancies.
                if (count_delete + count_insert > 1) {
                    if (count_delete != 0 and count_insert != 0) {
                        // Factor out any common prefixes.
                        var common_length: usize = diffCommonPrefix(text_insert.items, text_delete.items);
                        if (common_length != 0) {
                            if ((pointer - count_delete - count_insert) > 0 and
                                diffs.items[pointer - count_delete - count_insert - 1].operation == .equal)
                            { // The prefix is not at the start of the diffs
                                const ii = pointer - count_delete - count_insert - 1;
                                var nt = try allocator.alloc(u8, diffs.items[ii].text.len + common_length);
                                const ot = diffs.items[ii].text;
                                @memcpy(nt[0..ot.len], ot);
                                @memcpy(nt[ot.len..], text_insert.items[0..common_length]);
                                diffs.items[ii].text = nt;
                                allocator.free(ot);
                            } else {
                                try diffs.ensureUnusedCapacity(allocator, 1);
                                const text = try allocator.dupe(u8, text_insert.items[0..common_length]);
                                diffs.insertAssumeCapacity(0, Edit.init(.equal, text));
                                pointer += 1;
                            }
                            try text_insert.replaceRange(allocator, 0, common_length, &.{});
                            try text_delete.replaceRange(allocator, 0, common_length, &.{});
                        }
                        // Factor out any common suffices.
                        // @ZigPort this seems very wrong
                        common_length = diffCommonSuffix(text_insert.items, text_delete.items);
                        if (common_length != 0) {
                            const old_text = diffs.items[pointer].text;
                            diffs.items[pointer].text = try std.mem.concat(allocator, u8, &.{
                                text_insert.items[text_insert.items.len - common_length ..],
                                old_text,
                            });
                            allocator.free(old_text);
                            text_insert.items.len -= common_length;
                            text_delete.items.len -= common_length;
                        }
                    }
                    // Delete the offending records and add the merged ones.
                    pointer -= count_delete + count_insert;
                    if (count_delete + count_insert > 0) {
                        freeRangeDiffList(allocator, diffs, pointer, count_delete + count_insert);
                        try diffs.replaceRange(allocator, pointer, count_delete + count_insert, &.{});
                    }

                    if (text_delete.items.len != 0) {
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        diffs.insertAssumeCapacity(pointer, Edit.init(
                            .delete,
                            try allocator.dupe(u8, text_delete.items),
                        ));
                        pointer += 1;
                    }
                    if (text_insert.items.len != 0) {
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        diffs.insertAssumeCapacity(pointer, Edit.init(
                            .insert,
                            try allocator.dupe(u8, text_insert.items),
                        ));
                        pointer += 1;
                    }
                    pointer += 1;
                } else if (pointer != 0 and diffs.items[pointer - 1].operation == .equal) {
                    // Merge this equality with the previous one.
                    // Diff texts are []const u8 so a realloc isn't practical here
                    var nt = try allocator.alloc(u8, diffs.items[pointer - 1].text.len + diffs.items[pointer].text.len);
                    const ot = diffs.items[pointer - 1].text;
                    defer (allocator.free(ot));
                    @memcpy(nt[0..ot.len], ot);
                    @memcpy(nt[ot.len..], diffs.items[pointer].text);
                    diffs.items[pointer - 1].text = nt;
                    const dead_diff = diffs.orderedRemove(pointer);
                    allocator.free(dead_diff.text);
                } else {
                    pointer += 1;
                }
                count_insert = 0;
                count_delete = 0;
                text_delete.items.len = 0;
                text_insert.items.len = 0;
            },
        }
    }
    if (diffs.items[diffs.items.len - 1].text.len == 0) {
        diffs.items.len -= 1;
    }
    // Second pass: look for single edits surrounded on both sides by
    // equalities which can be shifted sideways to eliminate an equality.
    // e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
    var changes = false;
    pointer = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (pointer < (diffs.items.len - 1)) {
        if (diffs.items[pointer - 1].operation == .equal and
            diffs.items[pointer + 1].operation == .equal)
        {
            // This is a single edit surrounded by equalities.
            if (std.mem.endsWith(u8, diffs.items[pointer].text, diffs.items[pointer - 1].text)) {
                const old_pt = diffs.items[pointer].text;
                const pt = try std.mem.concat(allocator, u8, &.{
                    diffs.items[pointer - 1].text,
                    diffs.items[pointer].text[0 .. diffs.items[pointer].text.len -
                        diffs.items[pointer - 1].text.len],
                });
                allocator.free(old_pt);
                diffs.items[pointer].text = pt;
                const old_pt1t = diffs.items[pointer + 1].text;
                const p1t = try std.mem.concat(allocator, u8, &.{
                    diffs.items[pointer - 1].text,
                    diffs.items[pointer + 1].text,
                });
                allocator.free(old_pt1t);
                diffs.items[pointer + 1].text = p1t;
                freeRangeDiffList(allocator, diffs, pointer - 1, 1);
                try diffs.replaceRange(allocator, pointer - 1, 1, &.{});
                changes = true;
            } else if (std.mem.startsWith(u8, diffs.items[pointer].text, diffs.items[pointer + 1].text)) {
                const old_ptm1 = diffs.items[pointer - 1].text;
                const pm1t = try std.mem.concat(allocator, u8, &.{
                    diffs.items[pointer - 1].text,
                    diffs.items[pointer + 1].text,
                });
                allocator.free(old_ptm1);
                diffs.items[pointer - 1].text = pm1t;
                const old_pt = diffs.items[pointer].text;
                const pt = try std.mem.concat(allocator, u8, &.{
                    diffs.items[pointer].text[diffs.items[pointer + 1].text.len..],
                    diffs.items[pointer + 1].text,
                });
                allocator.free(old_pt);
                diffs.items[pointer].text = pt;
                freeRangeDiffList(allocator, diffs, pointer + 1, 1);
                try diffs.replaceRange(allocator, pointer + 1, 1, &.{});
                changes = true;
            }
        }
        pointer += 1;
    }
    // If shifts were made, the diff needs reordering and another shift sweep.
    if (changes) {
        try diffCleanupMerge(allocator, diffs);
    }
}

/// Reduce the number of edits by eliminating semantically trivial
/// equalities.
/// @param diffs List of Diff objects.
pub fn diffCleanupSemantic(allocator: std.mem.Allocator, diffs: *DiffList) error{OutOfMemory}!void {
    var changes = false;
    // Stack of indices where equalities are found.
    var equalities = ArrayListUnmanaged(usize){};
    defer equalities.deinit(allocator);
    // Always equal to equalities[equalitiesLength-1][1]
    var last_equality: ?[]const u8 = null;
    var pointer: usize = 0; // Index of current position.
    // Number of characters that changed prior to the equality.
    var length_insertions1: usize = 0;
    var length_deletions1: usize = 0;
    // Number of characters that changed after the equality.
    var length_insertions2: usize = 0;
    var length_deletions2: usize = 0;
    var reset_pointer = false;
    while (pointer < diffs.items.len) {
        if (diffs.items[pointer].operation == .equal) { // Equality found.
            try equalities.append(allocator, pointer);
            length_insertions1 = length_insertions2;
            length_deletions1 = length_deletions2;
            length_insertions2 = 0;
            length_deletions2 = 0;
            last_equality = diffs.items[pointer].text;
        } else { // an insertion or deletion
            if (diffs.items[pointer].operation == .insert) {
                length_insertions2 += diffs.items[pointer].text.len;
            } else {
                length_deletions2 += diffs.items[pointer].text.len;
            }
            // Eliminate an equality that is smaller or equal to the edits on both
            // sides of it.
            if (last_equality != null and
                (last_equality.?.len <= @max(length_insertions1, length_deletions1)) and
                (last_equality.?.len <= @max(length_insertions2, length_deletions2)))
            {
                // Duplicate record.
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.insertAssumeCapacity(
                    equalities.items[equalities.items.len - 1],
                    Edit.init(
                        .delete,
                        try allocator.dupe(u8, last_equality.?),
                    ),
                );
                // Change second copy to insert.
                diffs.items[equalities.items[equalities.items.len - 1] + 1].operation = .insert;
                // Throw away the equality we just deleted.
                _ = equalities.pop();
                if (equalities.items.len > 0) {
                    _ = equalities.pop();
                }
                if (equalities.items.len > 0) {
                    pointer = equalities.items[equalities.items.len - 1];
                } else {
                    reset_pointer = true;
                }
                length_insertions1 = 0; // Reset the counters.
                length_deletions1 = 0;
                length_insertions2 = 0;
                length_deletions2 = 0;
                last_equality = null;
                changes = true;
            }
        }
        if (reset_pointer) {
            pointer = 0;
            reset_pointer = false;
        } else {
            pointer += 1;
        }
    }

    // Normalize the diff.
    if (changes) {
        try diffCleanupMerge(allocator, diffs);
    }
    try diffCleanupSemanticLossless(allocator, diffs);

    // Find any overlaps between deletions and insertions.
    // e.g: <del>abcxxx</del><ins>xxxdef</ins>
    //   -> <del>abc</del>xxx<ins>def</ins>
    // e.g: <del>xxxabc</del><ins>defxxx</ins>
    //   -> <ins>def</ins>xxx<del>abc</del>
    // Only extract an overlap if it is as big as the edit ahead or behind it.
    pointer = 1;
    while (pointer < diffs.items.len) {
        if (diffs.items[pointer - 1].operation == .delete and
            diffs.items[pointer].operation == .insert)
        {
            const deletion = diffs.items[pointer - 1].text;
            const insertion = diffs.items[pointer].text;
            const overlap_length1: usize = diffCommonOverlap(deletion, insertion);
            const overlap_length2: usize = diffCommonOverlap(insertion, deletion);
            if (overlap_length1 >= overlap_length2) {
                if (@as(f32, @floatFromInt(overlap_length1)) >= @as(f32, @floatFromInt(deletion.len)) / 2.0 or
                    @as(f32, @floatFromInt(overlap_length1)) >= @as(f32, @floatFromInt(insertion.len)) / 2.0)
                {
                    // Overlap found.
                    // Insert an equality and trim the surrounding edits.
                    try diffs.ensureUnusedCapacity(allocator, 1);
                    diffs.insertAssumeCapacity(
                        pointer,
                        Edit.init(
                            .equal,
                            try allocator.dupe(u8, insertion[0..overlap_length1]),
                        ),
                    );
                    diffs.items[pointer - 1].text =
                        try allocator.dupe(u8, deletion[0 .. deletion.len - overlap_length1]);
                    allocator.free(deletion);
                    diffs.items[pointer + 1].text =
                        try allocator.dupe(u8, insertion[overlap_length1..]);
                    allocator.free(insertion);
                    pointer += 1;
                }
            } else {
                if (@as(f32, @floatFromInt(overlap_length2)) >= @as(f32, @floatFromInt(deletion.len)) / 2.0 or
                    @as(f32, @floatFromInt(overlap_length2)) >= @as(f32, @floatFromInt(insertion.len)) / 2.0)
                {
                    // Reverse overlap found.
                    // Insert an equality and swap and trim the surrounding edits.
                    try diffs.ensureUnusedCapacity(allocator, 1);
                    diffs.insertAssumeCapacity(
                        pointer,
                        Edit.init(
                            .equal,
                            try allocator.dupe(u8, deletion[0..overlap_length2]),
                        ),
                    );
                    const new_minus = try allocator.dupe(u8, insertion[0 .. insertion.len - overlap_length2]);
                    errdefer allocator.free(new_minus); // necessary due to swap
                    const new_plus = try allocator.dupe(u8, deletion[overlap_length2..]);
                    allocator.free(deletion);
                    allocator.free(insertion);
                    diffs.items[pointer - 1].operation = .insert;
                    diffs.items[pointer - 1].text = new_minus;
                    diffs.items[pointer + 1].operation = .delete;
                    diffs.items[pointer + 1].text = new_plus;
                    pointer += 1;
                }
            }
            pointer += 1;
        }
        pointer += 1;
    }
}

/// Look for single edits surrounded on both sides by equalities
/// which can be shifted sideways to align the edit to a word boundary.
/// e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
pub fn diffCleanupSemanticLossless(
    allocator: std.mem.Allocator,
    diffs: *DiffList,
) error{OutOfMemory}!void {
    var pointer: usize = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (pointer < @as(isize, @intCast(diffs.items.len)) - 1) {
        if (diffs.items[pointer - 1].operation == .equal and
            diffs.items[pointer + 1].operation == .equal)
        {
            // This is a single edit surrounded by equalities.
            var equality_1 = std.ArrayListUnmanaged(u8){};
            defer equality_1.deinit(allocator);
            try equality_1.appendSlice(allocator, diffs.items[pointer - 1].text);

            var edit = std.ArrayListUnmanaged(u8){};
            defer edit.deinit(allocator);
            try edit.appendSlice(allocator, diffs.items[pointer].text);

            var equality_2 = std.ArrayListUnmanaged(u8){};
            defer equality_2.deinit(allocator);
            try equality_2.appendSlice(allocator, diffs.items[pointer + 1].text);

            // First, shift the edit as far left as possible.
            const common_offset = diffCommonSuffix(equality_1.items, edit.items);
            if (common_offset > 0) {
                const common_string = try allocator.dupe(u8, edit.items[edit.items.len - common_offset ..]);
                defer allocator.free(common_string);

                equality_1.items.len = equality_1.items.len - common_offset;

                const not_common = try allocator.dupe(u8, edit.items[0 .. edit.items.len - common_offset]);
                defer allocator.free(not_common);

                edit.clearRetainingCapacity();
                try edit.appendSlice(allocator, common_string);
                try edit.appendSlice(allocator, not_common);

                try equality_2.insertSlice(allocator, 0, common_string);
            }

            // Second, step character by character right,
            // looking for the best fit.
            var best_equality_1 = ArrayListUnmanaged(u8){};
            defer best_equality_1.deinit(allocator);
            try best_equality_1.appendSlice(allocator, equality_1.items);

            var best_edit = ArrayListUnmanaged(u8){};
            defer best_edit.deinit(allocator);
            try best_edit.appendSlice(allocator, edit.items);

            var best_equality_2 = ArrayListUnmanaged(u8){};
            defer best_equality_2.deinit(allocator);
            try best_equality_2.appendSlice(allocator, equality_2.items);

            var best_score = diffCleanupSemanticScore(equality_1.items, edit.items) +
                diffCleanupSemanticScore(edit.items, equality_2.items);

            while (edit.items.len != 0 and equality_2.items.len != 0 and edit.items[0] == equality_2.items[0]) {
                try equality_1.append(allocator, edit.items[0]);

                _ = edit.orderedRemove(0);
                try edit.append(allocator, equality_2.items[0]);

                _ = equality_2.orderedRemove(0);

                const score = diffCleanupSemanticScore(equality_1.items, edit.items) +
                    diffCleanupSemanticScore(edit.items, equality_2.items);
                // The >= encourages trailing rather than leading whitespace on
                // edits.
                if (score >= best_score) {
                    best_score = score;

                    best_equality_1.items.len = 0;
                    try best_equality_1.appendSlice(allocator, equality_1.items);

                    best_edit.items.len = 0;
                    try best_edit.appendSlice(allocator, edit.items);

                    best_equality_2.items.len = 0;
                    try best_equality_2.appendSlice(allocator, equality_2.items);
                }
            }

            if (!std.mem.eql(u8, diffs.items[pointer - 1].text, best_equality_1.items)) {
                // We have an improvement, save it back to the diff.
                if (best_equality_1.items.len != 0) {
                    const old_text = diffs.items[pointer - 1].text;
                    diffs.items[pointer - 1].text = try allocator.dupe(u8, best_equality_1.items);
                    allocator.free(old_text);
                } else {
                    const old_diff = diffs.orderedRemove(pointer - 1);
                    allocator.free(old_diff.text);
                    pointer -= 1;
                }
                const old_text1 = diffs.items[pointer].text;
                diffs.items[pointer].text = try allocator.dupe(u8, best_edit.items);
                defer allocator.free(old_text1);
                if (best_equality_2.items.len != 0) {
                    const old_text2 = diffs.items[pointer + 1].text;
                    diffs.items[pointer + 1].text = try allocator.dupe(u8, best_equality_2.items);
                    allocator.free(old_text2);
                } else {
                    const old_diff = diffs.orderedRemove(pointer + 1);
                    allocator.free(old_diff.text);
                    pointer -= 1;
                }
            }
        }
        pointer += 1;
    }
}

/// Given two strings, compute a score representing whether the internal
/// boundary falls on logical boundaries.
/// Scores range from 6 (best) to 0 (worst).
/// @param one First string.
/// @param two Second string.
/// @return The score.
fn diffCleanupSemanticScore(one: []const u8, two: []const u8) usize {
    if (one.len == 0 or two.len == 0) {
        // Edges are the best.
        return 6;
    }

    // Each port of this function behaves slightly differently due to
    // subtle differences in each language's definition of things like
    // 'whitespace'.  Since this function's purpose is largely cosmetic,
    // the choice has been made to use each language's native features
    // rather than force total conformity.
    const char1 = one[one.len - 1];
    const char2 = two[0];
    const nonAlphaNumeric1 = !std.ascii.isAlphanumeric(char1);
    const nonAlphaNumeric2 = !std.ascii.isAlphanumeric(char2);
    const whitespace1 = nonAlphaNumeric1 and std.ascii.isWhitespace(char1);
    const whitespace2 = nonAlphaNumeric2 and std.ascii.isWhitespace(char2);
    const lineBreak1 = whitespace1 and std.ascii.isControl(char1);
    const lineBreak2 = whitespace2 and std.ascii.isControl(char2);
    const blankLine1 = lineBreak1 and
        (std.mem.endsWith(u8, one, "\n\n") or std.mem.endsWith(u8, one, "\n\r\n"));
    const blankLine2 = lineBreak2 and
        (std.mem.startsWith(u8, two, "\n\n") or
            std.mem.startsWith(u8, two, "\r\n\n") or
            std.mem.startsWith(u8, two, "\n\r\n") or
            std.mem.startsWith(u8, two, "\r\n\r\n"));

    if (blankLine1 or blankLine2) {
        // Five points for blank lines.
        return 5;
    } else if (lineBreak1 or lineBreak2) {
        // Four points for line breaks.
        return 4;
    } else if (nonAlphaNumeric1 and !whitespace1 and whitespace2) {
        // Three points for end of sentences.
        return 3;
    } else if (whitespace1 or whitespace2) {
        // Two points for whitespace.
        return 2;
    } else if (nonAlphaNumeric1 or nonAlphaNumeric2) {
        // One point for non-alphanumeric.
        return 1;
    }
    return 0;
}

/// Reduce the number of edits by eliminating operationally trivial
/// equalities.
pub fn diffCleanupEfficiency(
    dmp: DiffMatchPatch,
    allocator: std.mem.Allocator,
    diffs: *DiffList,
) error{OutOfMemory}!void {
    var changes = false;
    // Stack of indices where equalities are found.
    var equalities = ArrayList(usize).init(allocator);
    defer equalities.deinit();
    // Always equal to equalities[equalitiesLength-1][1]
    var last_equality: []const u8 = "";
    var ipointer: isize = 0; // Index of current position.
    // Is there an insertion operation before the last equality.
    var pre_ins = false;
    // Is there a deletion operation before the last equality.
    var pre_del = false;
    // Is there an insertion operation after the last equality.
    var post_ins = false;
    // Is there a deletion operation after the last equality.
    var post_del = false;
    while (ipointer < diffs.items.len) {
        const pointer: usize = @intCast(ipointer);
        if (diffs.items[pointer].operation == .equal) { // Equality found.
            if (diffs.items[pointer].text.len < dmp.diff_edit_cost and (post_ins or post_del)) {
                // Candidate found.
                try equalities.append(pointer);
                pre_ins = post_ins;
                pre_del = post_del;
                last_equality = diffs.items[pointer].text;
            } else {
                // Not a candidate, and can never become one.
                equalities.items.len = 0;
                last_equality = "";
            }
            post_ins = false;
            post_del = false;
        } else { // An insertion or deletion.
            if (diffs.items[pointer].operation == .delete) {
                post_del = true;
            } else {
                post_ins = true;
            }
            // Five types to be split:
            // <ins>A</ins><del>B</del>XY<ins>C</ins><del>D</del>
            // <ins>A</ins>X<ins>C</ins><del>D</del>
            // <ins>A</ins><del>B</del>X<ins>C</ins>
            // <ins>A</del>X<ins>C</ins><del>D</del>
            // <ins>A</ins><del>B</del>X<del>C</del>
            if ((last_equality.len != 0) and
                ((pre_ins and pre_del and post_ins and post_del) or
                    ((last_equality.len < dmp.diff_edit_cost / 2) and
                        (boolInt(pre_ins) + boolInt(pre_del) + boolInt(post_ins) + boolInt(post_del) == 3))))
            {
                // Duplicate record.
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.insertAssumeCapacity(
                    equalities.items[equalities.items.len - 1],
                    Edit.init(
                        .delete,
                        try allocator.dupe(u8, last_equality),
                    ),
                );
                // Change second copy to insert.
                diffs.items[equalities.items[equalities.items.len - 1] + 1].operation = .insert;
                _ = equalities.pop(); // Throw away the equality we just deleted.
                last_equality = "";
                if (pre_ins and pre_del) {
                    // No changes made which could affect previous entry, keep going.
                    post_ins = true;
                    post_del = true;
                    equalities.items.len = 0;
                } else {
                    if (equalities.items.len > 0) {
                        _ = equalities.pop();
                    }

                    ipointer = if (equalities.items.len > 0) @intCast(equalities.items[equalities.items.len - 1]) else -1;
                    post_ins = false;
                    post_del = false;
                }
                changes = true;
            }
        }
        ipointer += 1;
    }

    if (changes) {
        try diffCleanupMerge(allocator, diffs);
    }
}

/// Determine if the suffix of one string is the prefix of another.
/// @param text1 First string.
/// @param text2 Second string.
/// @return The number of characters common to the end of the first
///     string and the start of the second string.
fn diffCommonOverlap(text1_in: []const u8, text2_in: []const u8) usize {
    var text1 = text1_in;
    var text2 = text2_in;

    // Cache the text lengths to prevent multiple calls.
    const text1_length = text1.len;
    const text2_length = text2.len;
    // Eliminate the null case.
    if (text1_length == 0 or text2_length == 0) {
        return 0;
    }
    // Truncate the longer string.
    if (text1_length > text2_length) {
        text1 = text1[text1_length - text2_length ..];
    } else if (text1_length < text2_length) {
        text2 = text2[0..text1_length];
    }
    const text_length = @min(text1_length, text2_length);
    // Quick check for the worst case.
    if (std.mem.eql(u8, text1, text2)) {
        return text_length;
    }

    // Start by looking for a single character match
    // and increase length until no match is found.
    // Performance analysis: https://neil.fraser.name/news/2010/11/04/
    var best: usize = 0;
    var length: usize = 1;
    const best_idx = idx: while (true) {
        const pattern = text1[text_length - length ..];
        const found = std.mem.indexOf(u8, text2, pattern) orelse
            break :idx best;

        length += found;

        if (found == 0 or std.mem.eql(u8, text1[text_length - length ..], text2[0..length])) {
            best = length;
            length += 1;
        }
    };
    if (best_idx == 0) return best_idx;
    // This would mean a truncation: lead or follow, followed by a follow
    // which differs (or it would be included in our overlap).
    // TODO this currently appears to be dead code, keep an eye on that.
    // Reasoning: we're looking for a suffix which matches a prefix, and
    // we've already assured that edits end with a follow byte, and begin
    // with a lead byte, ASCII being both for our purposes.  So a split
    // should not be possible.
    // I'm going to add a panic just so I know if test cases of any sort
    // trigger this code path.
    // XXX Remove this before merge if it can't be triggered.
    if (is_follow(text2[best_idx])) {
        // back out
        return fixSplitBackward(text2, best_idx);
    }
    return best_idx;
}

/// loc is a location in text1, compute and return the equivalent location in
/// text2.
/// e.g. "The cat" vs "The big cat", 1->1, 5->8
/// @param diffs List of Diff objects.
/// @param loc Location within text1.
/// @return Location within text2.
///
pub fn diffIndex(diffs: DiffList, u_loc: usize) usize {
    var chars1: isize = 0;
    var chars2: isize = 0;
    var last_chars1: isize = 0;
    var last_chars2: isize = 0;
    const loc: isize = @intCast(u_loc);
    //  Dummy diff
    var last_diff: Edit = Edit{ .operation = .equal, .text = "" };
    for (diffs.items) |a_diff| {
        if (a_diff.operation != .insert) {
            // Equality or deletion.
            chars1 += @intCast(a_diff.text.len);
        }
        if (a_diff.operation != .delete) {
            // Equality or insertion.
            chars2 += @intCast(a_diff.text.len);
        }
        if (chars1 > loc) {
            // Overshot the location.
            last_diff = a_diff;
            break;
        }
    }
    last_chars1 = chars1;
    last_chars2 = chars2;

    if (last_diff.text.len != 0 and last_diff.operation == .delete) {
        // The location was deleted.
        return @intCast(last_chars2);
    }
    // Add the remaining character length.
    return @intCast(last_chars2 + (loc - last_chars1));
}

/// A struct holding bookends for `diffPrittyFormat(diffs)`.
///
/// May include a function taking an allocator and the Diff,
/// which shall return the text of the Diff, appropriately munged.
/// This allows for tasks like proper HTML escaping.  Note that if
/// the function is provided, all text returned will be freed, so
/// it should always return a copy whether or not edits are needed.
pub const DiffDecorations = struct {
    delete_start: []const u8 = "",
    delete_end: []const u8 = "",
    insert_start: []const u8 = "",
    insert_end: []const u8 = "",
    equals_start: []const u8 = "",
    equals_end: []const u8 = "",
    pre_process: ?fn (Allocator, Edit) error{OutOfMemory}![]const u8 = null,
};

/// Decorations for classic Xterm printing: red for delete and
/// green for insert.
pub const xterm_classic = DiffDecorations{
    .delete_start = "\x1b[91m",
    .delete_end = "\x1b[m",
    .insert_start = "\x1b[92m",
    .insert_end = "\x1b[m",
};

/// Return text representing a pretty-formatted `DiffList`.
/// See `DiffDecorations` for how to customize this output.
pub fn diffPrettyFormat(
    allocator: Allocator,
    diffs: DiffList,
    deco: DiffDecorations,
) ![]const u8 {
    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    const writer = out.writer();
    _ = try writeDiffPrettyFormat(allocator, writer, diffs, deco);
    return out.toOwnedSlice();
}

/// Pretty-print a diff for output to a terminal.
pub fn diffPrettyFormatXTerm(allocator: Allocator, diffs: DiffList) ![]const u8 {
    return try diffPrettyFormat(allocator, diffs, xterm_classic);
}

/// Write a pretty-formatted `DiffList` to `writer`.  The `Allocator`
/// is only used if a custom text formatter is defined for
/// `DiffDecorations`.  Returns number of bytes written.
pub fn writeDiffPrettyFormat(
    allocator: Allocator,
    writer: anytype,
    diffs: DiffList,
    deco: DiffDecorations,
) !usize {
    var written: usize = 0;
    for (diffs.items) |d| {
        const text = if (deco.pre_process) |lambda|
            try lambda(allocator, d)
        else
            d.text;
        defer {
            if (deco.pre_process) |_|
                allocator.free(text);
        }
        switch (d.operation) {
            .delete => {
                //
                written += try writer.write(deco.delete_start);
                written += try writer.write(text);
                written += try writer.write(deco.delete_end);
            },
            .insert => {
                written += try writer.write(deco.insert_start);
                written += try writer.write(text);
                written += try writer.write(deco.insert_end);
            },
            .equal => {
                written += try writer.write(deco.equals_start);
                written += try writer.write(text);
                written += try writer.write(deco.equals_end);
            },
        }
    }
    return written;
}

///
/// Compute and return the source text (all equalities and deletions).
/// @param diffs List of `Diff` objects.
/// @return Source text.
///
pub fn diffBeforeText(allocator: Allocator, diffs: DiffList) error{OutOfMemory}![]const u8 {
    var chars = ArrayListUnmanaged(u8){};
    defer chars.deinit(allocator);
    for (diffs.items) |d| {
        if (d.operation != .insert) {
            try chars.appendSlice(allocator, d.text);
        }
    }
    return chars.toOwnedSlice(allocator);
}

///
/// Compute and return the destination text (all equalities and insertions).
/// @param diffs List of `Diff` objects.
/// @return Destination text.
///
pub fn diffAfterText(allocator: Allocator, diffs: DiffList) error{OutOfMemory}![]const u8 {
    var chars = ArrayListUnmanaged(u8){};
    defer chars.deinit(allocator);
    for (diffs.items) |d| {
        if (d.operation != .delete) {
            try chars.appendSlice(allocator, d.text);
        }
    }
    return chars.toOwnedSlice(allocator);
}

// Lookup table for counting bytes fast.
const cp_weight: [4]u8 = .{ 1, 1, 0, 1 };

///
/// Compute the Levenshtein distance; the number of inserted,
/// deleted or substituted characters.
///
/// @param diffs List of Diff objects.
/// @return Number of changes.
///
pub fn diffLevenshtein(diffs: DiffList) f64 {
    // We compensate for multi-byte characters by only
    // counting the lead bytes, because we don't care
    // much what happens when this isn't even UTF-8.
    var inserts: usize = 0;
    var deletes: usize = 0;
    var levenshtein: usize = 0;
    for (diffs.items) |a_diff| {
        switch (a_diff.operation) {
            .insert => {
                for (a_diff.text) |b| {
                    inserts += cp_weight[b >> 6];
                }
            },
            .delete => {
                for (a_diff.text) |b| {
                    deletes += cp_weight[b >> 6];
                }
            },
            .equal => {
                // A deletion and an insertion is one substitution.
                levenshtein = @max(inserts, deletes);
                inserts = 0;
                deletes = 0;
            },
        }
    }

    return @floatFromInt(levenshtein + @max(inserts, deletes));
}

test diffLevenshtein {
    const allocator = testing.allocator;
    // These diffs don't get text freed
    {
        var diffs: DiffList = .empty;
        defer diffs.deinit(allocator);
        try diffs.appendSlice(allocator, &.{
            Edit.init(.delete, "abc"),
            Edit.init(.insert, "1234"),
            Edit.init(.equal, "xyz"),
        });
        try testing.expectEqual(4, diffLevenshtein(diffs));
    }
    {
        var diffs: DiffList = .empty;
        defer diffs.deinit(allocator);
        try diffs.appendSlice(allocator, &.{
            Edit.init(.equal, "xyz"),
            Edit.init(.delete, "abc"),
            Edit.init(.insert, "1234"),
        });
        try testing.expectEqual(4, diffLevenshtein(diffs));
    }
    {
        var diffs: DiffList = .empty;
        defer diffs.deinit(allocator);
        try diffs.appendSlice(allocator, &.{
            Edit.init(.delete, "abc"),
            Edit.init(.equal, "xyz"),
            Edit.init(.insert, "1234"),
        });
        try testing.expectEqual(7, diffLevenshtein(diffs));
    }
}

//| MATCH FUNCTIONS

/// Locate the best instance of 'pattern' in 'text' near 'loc'.
/// Returns -1 if no match found.
/// @param text The text to search.
/// @param pattern The pattern to search for.
/// @param loc The location to search around.
/// @return Best match index or -1.
pub fn matchMain(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    text: []const u8,
    pattern: []const u8,
    passed_loc: usize,
) error{OutOfMemory}!?usize {
    // Clamp the loc to fit within text.
    const loc = @min(passed_loc, text.len);
    if (std.mem.eql(u8, text, pattern)) {
        // Shortcut
        return 0;
    } else if (text.len == 0) {
        // Nothing to match.
        return null;
    } else if (loc + pattern.len <= text.len and std.mem.eql(u8, text[loc..][0..pattern.len], pattern)) {
        // Perfect match at the perfect spot!  (Includes case of null pattern)
        return loc;
    } else {
        // Do a fuzzy compare.
        return dmp.matchBitap(allocator, text, pattern, loc);
    }
}

const sh_one: u64 = 1;

//| TODO: There's a lot we can tweak here.  Big one: a SIMD-lane Shift-Or
//| can be a lot larger than 64 / 32 bits, when we have one.
//| ---
//| The notes about perfect match optimization are actually spurious because the
//| speedups above prevent that.  What I don't like is the 'speedups' which will
//| search the entire text without matching if there isn't a perfect fit.  We
//| should be able to use the clamp function to determine what's so far off from
//| our threshold that we don't treat it as a match even if we find it, then
//| clamp off the source text in both directions so we decline to search where
//| we don't care if there is a match.
//| ---
//| I also don't like the hash map we're using for the alphabet, it's a
//| heavyweight heap-allocated data structure, and what we do with it can be
//| done simpler.  Stack space is cheap, since we know the total call graph
//| is shallow, so we can use the sparse array trick.  Two [256]u8, and one
//| [256]usize: we index sparse with our byte, and if sparse[b] < n, the number
//| of elements, we check if dense[sparse[b]] == b.  If so, our value is at
//| val[sparse[b]].  Even for big vector match-maps, 256 bits, this is not a lot
//| of stack allocation.  Better yet, we have the option to allocate the val
//| array after building our alphabet, and we only make as many vectors as we
//| have unique letters.  But it's 'just' a 16KiB stack allocation, even then,
//| and we use it densely, not sparsely.
//| ---
//| Bonus round: making our alphabet bytes does not fit the problem domain,
//| and this matters: our result will treat drift by wider characters as more
//| expensive than narrow ones, which is contrary to intuition.  Same issue with
//| Levenshein, the value should be in terms of codepoints, not codeunits.  I
//| think both of these are amenable to a cheap 'fixup', though the details
//| escape me.  Options: make a map of the pattern with indices in increasing
//| order, where multibytes all get the same number.  Or, maybe we just adjust
//| the default match threshold by the mean of character widths, and hope for
//| the best.  That heuristic has the advantage of being very easy, at least.

/// Locate the best instance of `pattern` in `text` near `loc` using the
/// Bitap algorithm.  Returns -1 if no match found.
///
/// @param text The text to search.
/// @param pattern The pattern to search for.
/// @param loc The location to search around.
/// @return Best match index or -1.
fn matchBitap(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    text: []const u8,
    pattern: []const u8,
    loc: usize,
) error{OutOfMemory}!?usize {
    // TODO decide what to do here:
    // assert (Match_MaxBits == 0 || pattern.Length <= Match_MaxBits)
    //    : "Pattern too long for this application.";
    assert(text.len != 0 and pattern.len != 0);

    // Initialise the alphabet.
    var map = try matchAlphabet(allocator, pattern);
    defer map.deinit();
    // Highest score beyond which we give up.
    var score_threshold = dmp.match_threshold;
    // Is there a nearby exact match? (speedup)
    // TODO obviously if we want a speedup here, we do this:
    // if (threshold == 0.0) return best_loc;  #proof in comments
    // We don't have to unwrap best_loc because the retval is ?usize already
    // #proof axiom: threshold is between 0.0 and 1.0 (doc comment)
    var best_loc = std.mem.indexOfPos(u8, text, loc, pattern);
    if (best_loc) |best| { // #proof this returns 0.0 for exact match (see comments in function)
        score_threshold = @min(dmp.matchBitapScore(0, best, loc, pattern), score_threshold);
    }
    // What about in the other direction? (speedup)
    const trunc_text = text[0..@min(loc + pattern.len, text.len)];
    best_loc = std.mem.lastIndexOf(u8, trunc_text, pattern);
    if (best_loc) |best| { // #proof same here obviously
        score_threshold = @min(dmp.matchBitapScore(0, best, loc, pattern), score_threshold);
    }
    // Initialise the bit arrays.
    const shift: u6 = @intCast(pattern.len - 1);
    const matchmask = sh_one << shift;
    best_loc = null;
    // Zig is very insistent about integer width and signedness.
    const i_textlen: isize = @intCast(text.len);
    const i_patlen: isize = @intCast(pattern.len);

    const i_loc: isize = @intCast(loc);
    var bin_min: isize = undefined;
    var bin_mid: isize = undefined;
    var bin_max: isize = i_patlen + i_textlen;
    // null last_rd to simplify freeing memory
    var last_rd: []usize = try allocator.alloc(usize, 0);
    errdefer allocator.free(last_rd);
    for (0..pattern.len) |d| {
        // Scan for the best match; each iteration allows for one more error.
        // Run a binary search to determine how far from 'loc' we can stray at
        // this error level.
        bin_min = 0;
        bin_mid = bin_max;
        while (bin_min < bin_mid) {
            // #proof lemma: if threshold == 0.0, this never happens
            if (dmp.matchBitapScore(d, @intCast(i_loc + bin_mid), loc, pattern) <= score_threshold) {
                bin_min = bin_mid;
            } else {
                bin_max = bin_mid;
            }
            bin_mid = @divTrunc(bin_max - bin_min, 2) + bin_min;
        }
        // Use the result from this iteration as the maximum for the next.
        bin_max = bin_mid;
        var start: usize = @intCast(@max(1, i_loc - bin_mid + 1));
        const finish: usize = @intCast(@min(i_loc + bin_mid, i_textlen) + i_patlen);
        var rd: []usize = try allocator.alloc(usize, finish + 2);
        errdefer allocator.free(rd);
        const dshift: u6 = @intCast(d);
        rd[finish + 1] = (sh_one << dshift) - 1;
        var j = finish;
        while (j >= start) : (j -= 1) {
            const char_match: usize = if (text.len <= j - 1 or !map.contains(text[j - 1]))
                // Out of range.
                0
            else
                map.get(text[j - 1]).?;
            if (d == 0) {
                // First pass: exact match.
                rd[j] = ((rd[j + 1] << 1) | 1) & char_match;
            } else {
                // Subsequent passes: fuzzy match.
                rd[j] = ((rd[j + 1] << 1) | 1) & char_match | (((last_rd[j + 1] | last_rd[j]) << 1) | 1) | last_rd[j + 1];
            }
            if ((rd[j] & matchmask) != 0) {
                const score = dmp.matchBitapScore(d, j - 1, loc, pattern);
                // This match will almost certainly be better than any existing
                // match.  But check anyway.
                // #proof: the smoking gun. This can only be equal not less.
                if (score <= score_threshold) {
                    // Told you so.
                    score_threshold = score;
                    best_loc = j - 1;
                    if (best_loc.? > loc) {
                        // When passing loc, don't exceed our current distance from loc.
                        const i_best_loc: isize = @intCast(best_loc.?);
                        start = @max(1, 2 * i_loc - i_best_loc);
                    } else {
                        // Already passed loc, downhill from here on in.
                        break;
                    }
                }
            }
        } // #proof Anything else will do this.
        // #proof d + 1 starts at 1, so (see function) this will always break.
        if (dmp.matchBitapScore(d + 1, loc, loc, pattern) > score_threshold) {
            // No hope for a (better) match at greater error levels.
            allocator.free(rd);
            break;
        }
        allocator.free(last_rd);
        last_rd = rd;
    }
    allocator.free(last_rd);
    return best_loc;
}

/// Compute and return the score for a match with e errors and x location.
/// @param e Number of errors in match.
/// @param x Location of match.
/// @param loc Expected location of match.
/// @param pattern Pattern being sought.
/// @return Overall score for match (0.0 = good, 1.0 = bad).
fn matchBitapScore(
    dmp: DiffMatchPatch,
    e: usize,
    x: usize,
    loc: usize,
    pattern: []const u8,
) f64 {
    // shortcut? TODO, proof in comments
    if (e == 0 and x == loc) return 0.0;
    const e_float: f64 = @floatFromInt(e);
    const len_float: f64 = @floatFromInt(pattern.len);
    // if e == 0, accuracy == 0: 0/x = 0
    const accuracy = e_float / len_float;
    // if loc == x, proximity == 0
    const proximity = if (loc >= x) loc - x else x - loc;
    if (dmp.match_distance == 0) {
        // Dodge divide by zero
        if (proximity == 0) // therefore this returns 0
            return accuracy
        else
            return 1.0;
    }
    const float_match: f64 = @floatFromInt(dmp.match_distance);
    const float_proximity: f64 = @floatFromInt(proximity);
    // or this is 0 + 0/f_m aka 0
    return accuracy + (float_proximity / float_match);
}

/// Initialise the alphabet for the Bitap algorithm.
/// @param pattern The text to encode.
/// @return Hash of character locations.
fn matchAlphabet(allocator: Allocator, pattern: []const u8) error{OutOfMemory}!std.AutoHashMap(u8, usize) {
    var map = std.AutoHashMap(u8, usize).init(allocator);
    errdefer map.deinit();
    for (pattern) |c| {
        if (!map.contains(c)) {
            try map.put(c, 0);
        }
    }
    for (pattern, 0..) |c, i| {
        const shift: u6 = @intCast(pattern.len - i - 1);
        const value: usize = map.get(c).? | (@as(usize, 1) << shift);
        try map.put(c, value);
    }
    return map;
}

//|  PATCH FUNCTIONS

/// Increase the context until it is unique, but don't let the pattern
/// expand beyond DiffMatchPatch.match_max_bits.
///
/// @param patch The patch to grow.
/// @param text Source text.
fn patchAddContext(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    patch: *Hunk,
    text: []const u8,
) error{OutOfMemory}!void {
    if (text.len == 0) return;
    // TODO the fixup logic here might make patterns too large?
    // It should be ok, because big patches get broken up.  Hmm.
    // Also, the SimpleNote maintained branch does it this way.
    var padding: usize = 0;
    { // Grow the pattern around the patch until unique, to set padding amount.
        var pattern = text[patch.start2 .. patch.start2 + patch.length1];
        const max_width: usize = dmp.match_max_bits - (2 * dmp.patch_margin);
        while (std.mem.indexOf(u8, text, pattern) != std.mem.lastIndexOf(u8, text, pattern) and pattern.len < max_width) {
            padding += dmp.patch_margin;
            const pat_start = if (padding > patch.start2) 0 else patch.start2 - padding;
            const pat_end = @min(text.len, patch.start2 + patch.length1 + padding);
            pattern = text[pat_start..pat_end];
        }
    }
    // Add one chunk for good luck.
    padding += dmp.patch_margin;
    // Add the prefix.
    const prefix = pre: {
        var pre_start = if (padding > patch.start2) 0 else patch.start2 - padding;
        // Make sure we're not breaking a codepoint.
        pre_start = fixSplitBackward(text, pre_start);
        // Assuming we did everything else right, pre_end should be
        // properly placed.
        break :pre text[pre_start..patch.start2];
    };
    if (prefix.len != 0) {
        try patch.diffs.ensureUnusedCapacity(allocator, 1);
        patch.diffs.insertAssumeCapacity(0, Edit.init(
            .equal,
            try allocator.dupe(u8, prefix),
        ));
    }
    // Add the suffix.
    const suffix = post: {
        const post_start = patch.start2 + patch.length1;
        var post_end = @min(text.len, patch.start2 + patch.length1 + padding);
        // Prevent broken codepoints here as well
        post_end = fixSplitForward(text, post_end);
        break :post text[post_start..post_end];
    };
    if (suffix.len != 0) {
        try patch.diffs.ensureUnusedCapacity(allocator, 1);
        patch.diffs.appendAssumeCapacity(
            Edit.init(
                .equal,
                try allocator.dupe(u8, suffix),
            ),
        );
    }
    // Roll back the start points.
    patch.start1 -= prefix.len;
    patch.start2 -= prefix.len;
    // Extend the lengths.
    patch.length1 += prefix.len + suffix.len;
    patch.length2 += prefix.len + suffix.len;
}

/// Determines how to handle Diffs in a patch.  Functions which create
/// the diffs internally can use `.own`: the Diffs will be copied to
/// the patch list, new ones allocated, and old ones freed.  Then call
/// `deinit` on the DiffList, but not `deinitDiffList`.  This *must not*
/// be used if the DiffList is not immediately freed, because some of
/// the diffs will contain spuriously empty text.
///
/// Functions which operate on an existing DiffList should use `.copy`:
/// as the name indicates, copies of the Diffs will be made, and the
/// original memory must be freed separately.
const DiffHandling = enum {
    copy,
    own,
};

pub fn diffAndMakePatch(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    text1: []const u8,
    text2: []const u8,
) error{OutOfMemory}!Patch {
    var diffs = try dmp.diff(allocator, text1, text2, true);
    defer deinitDiffList(allocator, &diffs);
    if (diffs.items.len > 2) {
        try diffCleanupSemantic(allocator, &diffs);
        try dmp.diffCleanupEfficiency(allocator, &diffs);
    }
    return try dmp.makePatchInternal(allocator, text1, diffs, .own);
}

/// @return List of Patch objects.
fn makePatchInternal(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    text: []const u8,
    diffs: DiffList,
    diff_act: DiffHandling,
) error{OutOfMemory}!Patch {
    var patches = Patch{};
    errdefer deinitPatchList(allocator, &patches);
    if (diffs.items.len == 0) {
        return patches; // Empty diff means empty patchlist
    }

    var char_count1: usize = 0;
    var char_count2: usize = 0;
    // This avoids freeing the original copy of the text:
    var first_patch = true;
    var prepatch_text = text;
    defer {
        if (!first_patch)
            allocator.free(prepatch_text);
    }
    // Calculate amount of extra bytes needed.
    // This should let the allocator reuse freed space.
    var extra: isize = 0;
    for (diffs.items) |a_diff| {
        switch (a_diff.operation) {
            .insert => {
                extra += @intCast(a_diff.text.len);
            },
            .delete => {
                extra -= @intCast(a_diff.text.len);
            },
            .equal => continue,
        }
    }
    const extra_u: usize = if (extra > 0) @intCast(extra) else 0;
    const dummy_diff = Edit{ .operation = .equal, .text = "" };
    var postpatch = try ArrayList(u8).initCapacity(allocator, text.len + extra_u);
    defer postpatch.deinit();
    postpatch.appendSliceAssumeCapacity(text);
    var patch = Hunk{};
    errdefer patch.deinit(allocator);
    for (diffs.items, 0..) |a_diff, i| {
        if (patch.diffs.items.len == 0 and a_diff.operation != .equal) {
            patch.start1 = char_count1;
            patch.start2 = char_count2;
        }
        switch (a_diff.operation) {
            .insert => {
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                const d = the_diff: {
                    if (diff_act == .copy) {
                        const new = try a_diff.clone(allocator);
                        break :the_diff new;
                    } else {
                        assert(a_diff.eql(diffs.items[i]));
                        diffs.items[i] = dummy_diff;
                        break :the_diff a_diff;
                    }
                };
                patch.diffs.appendAssumeCapacity(d);
                patch.length2 += a_diff.text.len;
                try postpatch.insertSlice(char_count2, a_diff.text);
            },
            .delete => {
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                const d = the_diff: {
                    if (diff_act == .copy) {
                        const new = try a_diff.clone(allocator);
                        break :the_diff new;
                    } else {
                        assert(a_diff.eql(diffs.items[i]));
                        diffs.items[i] = dummy_diff;
                        break :the_diff a_diff;
                    }
                };
                patch.diffs.appendAssumeCapacity(d);
                patch.length1 += a_diff.text.len;
                try postpatch.replaceRange(char_count2, a_diff.text.len, "");
            },
            .equal => {
                //
                if (a_diff.text.len <= 2 * dmp.patch_margin and patch.diffs.items.len != 0 and !a_diff.eql(diffs.getLast())) {
                    // Small equality inside a patch.
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    const d = the_diff: {
                        if (diff_act == .copy) {
                            const new = try a_diff.clone(allocator);
                            break :the_diff new;
                        } else {
                            assert(a_diff.eql(diffs.items[i]));
                            diffs.items[i] = dummy_diff;
                            break :the_diff a_diff;
                        }
                    };
                    patch.diffs.appendAssumeCapacity(d);
                    patch.length1 += a_diff.text.len;
                    patch.length2 += a_diff.text.len;
                }
                if (a_diff.text.len >= 2 * dmp.patch_margin) {
                    // Time for a new patch.
                    if (patch.diffs.items.len != 0) {
                        // Free the Diff if we own it.
                        if (diff_act == .own) {
                            assert(a_diff.eql(diffs.items[i]));
                            allocator.free(a_diff.text);
                            diffs.items[i] = dummy_diff;
                        }
                        try dmp.patchAddContext(allocator, &patch, prepatch_text);
                        try patches.ensureUnusedCapacity(allocator, 1);
                        patches.appendAssumeCapacity(patch);
                        patch = Hunk{};
                        // Unlike Unidiff, our patch lists have a rolling context.
                        // https://github.com/google/diff-match-patch/wiki/Unidiff
                        // Update prepatch text & pos to reflect the application of the
                        // just completed patch.
                        const free_patch_text = prepatch_text;
                        prepatch_text = try allocator.dupe(u8, postpatch.items);
                        if (first_patch) {
                            // no free on first, we don't own the original text
                            first_patch = false;
                        } else {
                            allocator.free(free_patch_text);
                        }
                        char_count1 = char_count2;
                    }
                }
            },
        }
        // Update the current character count.
        if (a_diff.operation != .insert) {
            char_count1 += a_diff.text.len;
        }
        if (a_diff.operation != .delete) {
            char_count2 += a_diff.text.len;
        }
    } // end for loop
    // Pick up the leftover patch if not empty.
    if (patch.diffs.items.len != 0) {
        try dmp.patchAddContext(allocator, &patch, prepatch_text);
        try patches.ensureUnusedCapacity(allocator, 1);
        patches.appendAssumeCapacity(patch);
    }
    return patches;
}

/// Compute a list of patches to turn text1 into text2.
/// text2 is not provided, diffs are the delta between text1 and text2.
///
/// @param text1 Old text.
/// @param diffs Array of Diff objects for text1 to text2.
pub fn makePatch(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    text: []const u8,
    diffs: DiffList,
) error{OutOfMemory}!Patch {
    return try dmp.makePatchInternal(allocator, text, diffs, .copy);
}

pub fn makePatchFromDiffs(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    diffs: DiffList,
) error{OutOfMemory}!Patch {
    const text1 = try diffBeforeText(allocator, diffs);
    defer allocator.free(text1);
    return try dmp.makePatch(allocator, text1, diffs);
}

/// Merge a set of patches onto the text.  Returns a tuple: the first of which
/// is the patched text, the second of which is...
///
/// TODO I'm just going to return a boolean saying whether all patches
/// were successful.  Rethink this at some point.  Possibility: build up a
/// patch string with all unsuccessful patches, it's a legible plain-text
/// format containing the failed edits, which could be converted into a patch
/// again, or used directly in an error message, or the slop turned up on the
/// dmp object and the patch reattempted. The delta allows us to adjust any
/// failed patches so they "fit" the next text.
///
/// @param patches Array of Patch objects
/// @param text Old text.
/// @return Two element Object array, containing the new text and an array of
///      bool values.
pub fn patchApply(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    og_patches: *Patch,
    og_text: []const u8,
) error{OutOfMemory}!struct { []const u8, bool } {
    if (og_patches.items.len == 0) {
        // As silly as this is, we dupe the text, because something
        // passing an empty patchset isn't going to check, and will
        // end up double-freeing if we don't.  Going with 'true' as
        // the null patchset was successfully 'applied' here.
        return .{ try allocator.dupe(u8, og_text), true };
    }
    // So we can report if all patches were applied:
    var all_applied = true;
    // Deep copy the patches so that no changes are made to originals.
    var patches = try patchListClone(allocator, og_patches);
    defer deinitPatchList(allocator, &patches);
    const null_padding = try dmp.patchAddPadding(allocator, &patches);
    defer allocator.free(null_padding);
    var text = try ArrayList(u8).initCapacity(allocator, og_text.len + 2 * null_padding.len);
    defer text.deinit();
    text.appendSliceAssumeCapacity(null_padding);
    text.appendSliceAssumeCapacity(og_text);
    text.appendSliceAssumeCapacity(null_padding);
    try dmp.patchSplitMax(allocator, &patches);
    // delta keeps track of the offset between the expected and actual
    // location of the previous patch.  If there are patches expected at
    // positions 10 and 20, but the first patch was found at 12, delta is 2
    // and the second patch has an effective expected position of 22.
    var delta: isize = 0;
    for (patches.items) |a_patch| {
        const expected_loc = cast(usize, (cast(isize, a_patch.start2) + delta));
        const text1 = try diffBeforeText(allocator, a_patch.diffs);
        defer allocator.free(text1);
        var maybe_start: ?usize = null;
        var maybe_end: ?usize = null;
        const m_max_b = dmp.match_max_bits;
        if (text1.len > m_max_b) {
            // patchSplitMax will only provide an oversized pattern
            // in the case of a monster delete.
            maybe_start = try dmp.matchMain(
                allocator,
                text.items,
                text1[0..m_max_b],
                expected_loc,
            );
            if (maybe_start) |start| {
                // Ok because we tested and text1.len is larger.
                const e_start = text1.len - m_max_b;
                maybe_end = try dmp.matchMain(
                    allocator,
                    text.items,
                    text1[e_start..],
                    e_start + expected_loc,
                );
                // No match if a) no end_loc or b) the matches cross each other.
                if (maybe_end) |end| {
                    if (start >= end) {
                        maybe_start = null;
                    }
                } else {
                    maybe_start = null;
                }
            }
        } else {
            maybe_start = try dmp.matchMain(allocator, text.items, text1, expected_loc);
        }
        if (maybe_start) |start| {
            // Found a match.  :)
            delta = cast(isize, start) - cast(isize, expected_loc);
            // results[x] = true;
            const text2 = t2: {
                if (maybe_end) |end| {
                    break :t2 text.items[start..@min(end + m_max_b, text.items.len)];
                } else {
                    break :t2 text.items[start..@min(start + text1.len, text.items.len)];
                }
            };
            if (std.mem.eql(u8, text1, text2)) {
                // Perfect match, just shove the replacement text in.
                const diff_text = try diffAfterText(allocator, a_patch.diffs);
                defer allocator.free(diff_text);
                try text.replaceRange(start, text1.len, diff_text);
            } else {
                // Imperfect match.  Run a diff to get a framework of equivalent
                // indices.
                var diffs = try dmp.diff(
                    allocator,
                    text1,
                    text2,
                    false,
                );
                defer deinitDiffList(allocator, &diffs);
                const t1_l_float: f64 = @floatFromInt(text1.len);
                const levenshtein: f64 = diffLevenshtein(diffs);
                const bad_match = levenshtein / t1_l_float > dmp.patch_delete_threshold;
                if (text1.len > m_max_b and bad_match) {
                    // The end points match, but the content is unacceptably bad.
                    // results[x] = false;
                    all_applied = false;
                } else {
                    try diffCleanupSemanticLossless(allocator, &diffs);
                    var index1: usize = 0;
                    for (a_patch.diffs.items) |a_diff| {
                        if (a_diff.operation != .equal) {
                            const index2 = diffIndex(diffs, index1);
                            if (a_diff.operation == .insert) {
                                // Insertion
                                try text.insertSlice(start + index2, a_diff.text);
                            } else if (a_diff.operation == .delete) {
                                // Deletion
                                const delete_at = diffIndex(diffs, index1 + a_diff.text.len) - index2;
                                text.replaceRangeAssumeCapacity(
                                    start + index2,
                                    delete_at,
                                    &.{},
                                );
                            }
                        }
                        if (a_diff.operation != .delete) {
                            index1 += a_diff.text.len;
                        }
                    }
                }
            }
        } else {
            // No match found.  :(
            all_applied = false;
            // Subtract the delta for this failed patch from subsequent patches.
            delta -= cast(isize, a_patch.length2) - cast(isize, a_patch.length1);
        }
    }
    // strip padding
    text.replaceRangeAssumeCapacity(0, null_padding.len, &.{});
    text.items.len -= null_padding.len;
    return .{ try text.toOwnedSlice(), all_applied };
}

// Look through the patches and break up any which are longer than the
// maximum limit of the match algorithm.
// Intended to be called only from within patchApply.
// @param patches List of Patch objects.
fn patchSplitMax(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    patches: *Patch,
) error{OutOfMemory}!void {
    const patch_size = dmp.match_max_bits;
    const patch_margin = dmp.patch_margin;
    const max_patch_len = patch_size - patch_margin;
    // Mutating an array while iterating it? Sure, lets!
    var x_i: isize = 0;
    while (x_i < patches.items.len) : (x_i += 1) {
        const x: usize = @intCast(x_i);
        if (patches.items[x].length1 <= patch_size) continue;

        // We have a big ol' patch.
        var bigpatch = patches.orderedRemove(x);
        defer bigpatch.deinit(allocator);
        // Prevent incrementing past the next patch:
        x_i -= 1;
        var start1 = bigpatch.start1;
        var start2 = bigpatch.start2;
        // start with an empty precontext so that we can deinit consistently
        var precontext: []const u8 = try allocator.alloc(u8, 0);
        while (bigpatch.diffs.items.len != 0) {
            var guard_precontext = true;
            errdefer {
                if (guard_precontext) {
                    allocator.free(precontext);
                }
            }
            // Create one of several smaller patches.
            var patch = Hunk{};
            errdefer patch.deinit(allocator);
            var empty = true;
            patch.start1 = start1 - precontext.len;
            patch.start2 = start2 - precontext.len;
            if (precontext.len != 0) {
                patch.length2 = precontext.len;
                patch.length1 = precontext.len;
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                guard_precontext = false;
                patch.diffs.appendAssumeCapacity(
                    Edit{
                        .operation = .equal,
                        .text = precontext,
                    },
                );
            }
            while (bigpatch.diffs.items.len != 0 and patch.length1 < max_patch_len) {
                const diff_type = bigpatch.diffs.items[0].operation;
                const diff_text = bigpatch.diffs.items[0].text;
                if (diff_type == .insert) {
                    // Insertions are harmless.
                    patch.length2 += diff_text.len;
                    start2 += diff_text.len;
                    // Move the patch (transfers ownership)
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    patch.diffs.appendAssumeCapacity(bigpatch.diffs.orderedRemove(0));
                    empty = false;
                } else if (patch.diffs.items.len == 1 and
                    diff_type == .delete and
                    patch.diffs.items[0].operation == .equal and
                    diff_text.len > 2 * patch_size)
                {
                    // This is a large deletion.  Let it pass in one chunk.
                    patch.length1 += diff_text.len;
                    start1 += diff_text.len;
                    empty = false;
                    // Transfer to patch:
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    patch.diffs.appendAssumeCapacity(bigpatch.diffs.orderedRemove(0));
                } else {
                    // Deletion or equality.  Only take as much as we can stomach.
                    // Note: because this is an internal function, we don't care
                    // about codepoint splitting, which won't affect the final
                    // result.
                    const text_end = @min(diff_text.len, patch_size - patch.length1 - patch_margin);
                    const new_diff_text = diff_text[0..text_end];
                    patch.length1 += new_diff_text.len;
                    start1 += new_diff_text.len;
                    if (diff_type == .equal) {
                        patch.length2 += new_diff_text.len;
                        start2 += new_diff_text.len;
                    } else {
                        empty = false;
                    }
                    // Now check if we did anything.
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    if (new_diff_text.len == diff_text.len) {
                        // We can reuse the diff.
                        patch.diffs.appendAssumeCapacity(bigpatch.diffs.orderedRemove(0));
                    } else {
                        // Free and dupe
                        patch.diffs.appendAssumeCapacity(Edit{
                            .operation = diff_type,
                            .text = try allocator.dupe(u8, new_diff_text),
                        });
                        const old_diff = bigpatch.diffs.items[0];
                        bigpatch.diffs.items[0] = Edit{
                            .operation = diff_type,
                            .text = try allocator.dupe(u8, diff_text[new_diff_text.len..]),
                        };
                        allocator.free(old_diff.text);
                    }
                }
            }
            // Append the end context for this patch.
            const post_text = try diffBeforeText(allocator, bigpatch.diffs);
            const postcontext = post: {
                if (post_text.len > patch_margin) {
                    defer allocator.free(post_text);
                    const truncated = try allocator.dupe(u8, post_text[0..patch_margin]);
                    break :post truncated;
                } else {
                    break :post post_text;
                }
            };
            var guard_postcontext = true;
            errdefer {
                if (guard_postcontext) {
                    allocator.free(postcontext);
                }
            }
            // Compute the head context for the next patch, if we're going to
            // need it.
            if (bigpatch.diffs.items.len != 0) {
                const after_text = try diffAfterText(allocator, patch.diffs);
                if (patch_margin > after_text.len) {
                    precontext = after_text;
                } else {
                    defer allocator.free(after_text);
                    precontext = try allocator.dupe(u8, after_text[after_text.len - patch_margin ..]);
                }
                guard_precontext = true;
            }
            if (postcontext.len != 0) {
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                patch.length1 += postcontext.len;
                patch.length2 += postcontext.len;
                const last_diff = patch.diffs.getLastOrNull();
                if (last_diff != null and last_diff.?.operation == .equal) {
                    // Free this diff and swap in a new one.
                    defer {
                        allocator.free(last_diff.?.text);
                        allocator.free(postcontext);
                        guard_postcontext = false;
                    }
                    patch.diffs.items.len -= 1;
                    const new_diff_text = try std.mem.concat(
                        allocator,
                        u8,
                        &.{
                            last_diff.?.text,
                            postcontext,
                        },
                    );
                    patch.diffs.appendAssumeCapacity(
                        Edit{ .operation = .equal, .text = new_diff_text },
                    );
                } else {
                    // New diff from postcontext.
                    patch.diffs.appendAssumeCapacity(
                        Edit{ .operation = .equal, .text = postcontext },
                    );
                }
                guard_postcontext = false;
            }
            if (!empty) {
                // Insert the next patch
                // Goes after x, and we need increment to skip:
                x_i += 1;
                try patches.insert(allocator, @intCast(x_i), patch);
            } else {
                patch.deinit(allocator);
            }
        } // We don't use the last precontext
        // allocator.free(precontext);
    }
}

/// Add some padding on text start and end so that edges can match something.
/// Intended to be called only from within patchApply.
/// @param patches Array of Patch objects.
/// @return The padding string added to each side.
fn patchAddPadding(
    dmp: DiffMatchPatch,
    allocator: Allocator,
    patches: *Patch,
) error{OutOfMemory}![]const u8 {
    if (patches.items.len == 0) return "";
    const pad_len = dmp.patch_margin;
    var paddingcodes = try ArrayList(u8).initCapacity(allocator, pad_len);
    defer paddingcodes.deinit();

    {
        var control_code: u8 = 1;
        while (control_code <= pad_len) : (control_code += 1) {
            paddingcodes.appendAssumeCapacity(control_code);
        }
    }
    // Bump all the patches forward.
    for (patches.items) |*a_patch| {
        a_patch.*.start1 += pad_len;
        a_patch.*.start2 += pad_len;
    }
    // Add some padding on start of first diff.
    var patch_start = &patches.items[0];
    var diffs_start = &patch_start.diffs;
    if (diffs_start.items.len == 0 or diffs_start.items[0].operation != .equal) {
        // Add nullPadding equality.
        try diffs_start.ensureUnusedCapacity(allocator, 1);
        diffs_start.insertAssumeCapacity(
            0,
            Edit{
                .operation = .equal,
                .text = try allocator.dupe(u8, paddingcodes.items),
            },
        );
        // Should be 0 due to prior patch bump
        patch_start.start1 -= pad_len;
        assert(patch_start.start1 == 0);
        patch_start.start2 -= pad_len;
        assert(patch_start.start2 == 0);
        patch_start.length1 += pad_len;
        patch_start.length2 += pad_len;
        // patches.items[0].diffs = diffs_start;
    } else if (pad_len > diffs_start.items[0].text.len) {
        // Grow first equality.
        var diff1 = &diffs_start.items[0];
        const old_diff_text = diff1.text;
        const extra_len = pad_len - diff1.text.len;
        diff1.text = try std.mem.concat(
            allocator,
            u8,
            &.{ paddingcodes.items[diff1.text.len..], diff1.text },
        );
        allocator.free(old_diff_text);
        patch_start.start1 -= extra_len;
        patch_start.start2 -= extra_len;
        patch_start.length1 += extra_len;
        patch_start.length2 += extra_len;
    }
    // Add some padding on end of last diff.
    var patch_end = &patches.items[patches.items.len - 1];
    var diffs_end = &patch_end.diffs;
    if ((diffs_end.items.len == 0) or (diffs_end.getLast().operation != .equal)) {
        // Add nullPadding equality.
        try diffs_end.ensureUnusedCapacity(allocator, 1);
        diffs_end.appendAssumeCapacity(
            Edit{
                .operation = .equal,
                .text = try allocator.dupe(u8, paddingcodes.items),
            },
        );
        patch_end.length1 += pad_len;
        patch_end.length2 += pad_len;
    } else if (pad_len > diffs_end.getLast().text.len) {
        // Grow last equality.
        var last_diff = &diffs_end.items[diffs_end.items.len - 1];
        const old_diff_text = last_diff.text;
        const extra_len = pad_len - last_diff.text.len;
        last_diff.text = try std.mem.concat(
            allocator,
            u8,
            &.{ last_diff.text, paddingcodes.items[0..extra_len] },
        );
        allocator.free(old_diff_text);
        patch_end.length2 += extra_len;
        patch_end.length1 += extra_len;
    }
    return paddingcodes.toOwnedSlice();
}

/// Given an array of patches, return another array that is identical.
/// @param patches Array of Patch objects.
/// @return Array of Patch objects.
fn patchListClone(allocator: Allocator, patches: *Patch) error{OutOfMemory}!Patch {
    var new_patches = Patch{};
    errdefer deinitPatchList(allocator, &new_patches);
    try new_patches.ensureTotalCapacity(allocator, patches.items.len);
    for (patches.items) |patch| {
        new_patches.appendAssumeCapacity(try patch.clone(allocator));
    }
    return new_patches;
}

/// Take a list of patches and return a textual representation.
/// @param patches List of Patch objects.
/// @return Text representation of patches.
pub fn patchToText(allocator: Allocator, patches: Patch) error{OutOfMemory}![]const u8 {
    var text_array = ArrayList(u8).init(allocator);
    defer text_array.deinit();
    const writer = text_array.writer();
    try writePatch(writer, patches);
    return text_array.toOwnedSlice();
}

/// Stream a `PatchList` to the provided Writer.
pub fn writePatch(writer: anytype, patches: Patch) !void {
    for (patches.items) |a_patch| {
        try a_patch.writeText(writer);
    }
}

/// Parse a textual representation of patches and return a List of Patch
/// objects.
/// @param textline Text representation of patches.
/// @return List of Patch objects.
/// @throws ArgumentException If invalid input.
pub fn patchFromText(allocator: Allocator, text: []const u8) DiffError!Patch {
    if (text.len == 0) return Patch{};
    var patches = Patch{};
    errdefer deinitPatchList(allocator, &patches);
    var cursor: usize = 0;
    while (cursor < text.len) {
        // TODO catch BadPatchString here and print diagnostic
        try patches.ensureUnusedCapacity(allocator, 1);
        const cursor_delta, const patch = try patchFromHeader(allocator, text[cursor..]);
        cursor += cursor_delta;
        patches.appendAssumeCapacity(patch);
    }
    return patches;
}

fn patchFromHeader(allocator: Allocator, text: []const u8) DiffError!struct { usize, Hunk } {
    var patch = Hunk{ .diffs = .empty };
    errdefer patch.deinit(allocator);
    var cursor: usize = undefined;
    if (std.mem.eql(u8, text[0..4], PATCH_HEAD)) {
        // Parse location and length in before text
        const count = 4 + countDigits(text[4..]);
        if (count == 4) return error.BadPatchString;
        patch.start1 = std.fmt.parseInt(
            usize,
            text[4..count],
            10,
        ) catch return error.BadPatchString;
        cursor = count;
        if (text[cursor] != ',') {
            patch.start1 -= 1;
            patch.length1 = 1;
        } else {
            cursor += 1;
            const delta = countDigits(text[cursor..]);
            patch.length1 = std.fmt.parseInt(
                usize,
                text[cursor .. cursor + delta],
                10,
            ) catch return error.BadPatchString;
            if (delta == 0) return error.BadPatchString;
            cursor += delta;
            if (patch.length1 != 0) {
                patch.start1 -= 1;
            }
        }
    } else return error.BadPatchString;
    // Parse location and length in after text.
    if (text[cursor] == ' ' and text[cursor + 1] == '+') {
        cursor += 2;
        const delta1 = countDigits(text[cursor..]);
        if (delta1 == 0) return error.BadPatchString;
        patch.start2 = std.fmt.parseInt(
            usize,
            text[cursor .. cursor + delta1],
            10,
        ) catch return error.BadPatchString;
        cursor += delta1;
        if (text[cursor] != ',') {
            patch.start2 -= 1;
            patch.length2 = 1;
        } else {
            cursor += 1;
            const delta2 = countDigits(text[cursor..]);
            if (delta2 == 0) return error.BadPatchString;
            patch.length2 = std.fmt.parseInt(
                usize,
                text[cursor .. cursor + delta2],
                10,
            ) catch return error.BadPatchString;
            cursor += delta2;
            if (patch.length2 != 0) {
                patch.start2 -= 1;
            }
        }
    } else return error.BadPatchString;
    if (cursor + 4 <= text.len and std.mem.eql(u8, text[cursor .. cursor + 4], PATCH_TAIL)) {
        cursor += 4;
    } else return error.BadPatchString;
    // Eat the diffs
    var patch_lines = std.mem.splitScalar(
        u8,
        text[cursor..],
        '\n',
    );
    // `splitScalar` means blank lines, but we need that to
    // track the cursor.
    patch_loop: while (patch_lines.next()) |line| {
        cursor += line.len + 1;
        if (line.len == 0) continue;
        // Microsoft encodes spaces as +, we don't, so we don't need this:
        // line = line.Replace("+", "%2b");
        const diff_line = decodeUri(allocator, line[1..]) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => return error.BadPatchString,
            }
        };
        errdefer allocator.free(diff_line);
        switch (line[0]) {
            '+' => { // Insertion
                try patch.diffs.append(
                    allocator,
                    Edit{
                        .operation = .insert,
                        .text = diff_line,
                    },
                );
            },
            '-' => { // Deletion
                try patch.diffs.append(
                    allocator,
                    Edit{
                        .operation = .delete,
                        .text = diff_line,
                    },
                );
            },
            ' ' => { // Minor equality
                try patch.diffs.append(
                    allocator,
                    Edit{
                        .operation = .equal,
                        .text = diff_line,
                    },
                );
            },
            '@' => { // Start of next patch
                // back out cursor
                allocator.free(diff_line);
                cursor -= line.len + 1;
                break :patch_loop;
            },
            else => return error.BadPatchString,
        }
    } // end while
    return .{ cursor, patch };
}

/// Decode our URI-esque escaping
fn decodeUri(allocator: Allocator, line: []const u8) DiffError![]const u8 {
    if (std.mem.indexOf(u8, line, "%")) |first| {
        // Text to decode.
        // Result will always be shorter than line:
        var new_line = try ArrayList(u8).initCapacity(allocator, line.len);
        defer new_line.deinit();
        try new_line.appendSlice(line[0..first]);
        var out_buf: [1]u8 = .{0};
        var codeunit = std.fmt.hexToBytes(
            &out_buf,
            line[first + 1 .. first + 3],
        ) catch return error.BadPatchString;
        try new_line.append(codeunit[0]);
        var cursor = first + 3;
        while (std.mem.indexOfScalarPos(u8, line, cursor, '%')) |next| {
            codeunit = std.fmt.hexToBytes(
                &out_buf,
                line[next + 1 .. next + 3],
            ) catch return error.BadPatchString;
            try new_line.append(codeunit[0]);
            cursor = next + 3;
        } else {
            try new_line.appendSlice(line[cursor..]);
        }
        return new_line.toOwnedSlice();
    } else {
        return allocator.dupe(u8, line);
    }
}

///
/// Borrowed from https://github.com/elerch/aws-sdk-for-zig/blob/master/src/aws_http.zig
/// under the MIT license. Thanks!
///
/// Modified to implement Unidiff escaping, documented here:
/// https://github.com/google/diff-match-patch/wiki/Unidiff
///
/// The documentation reads:
///
/// > Special characters are encoded using %xx notation. The set of
/// > characters which are encoded matches JavaScript's `encodeURI()`
/// > function, with the exception of spaces which are not encoded.
///
/// So we encode everything but the characters defined by Moz:
/// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/encodeURI
///
/// These:  !#$&'()*+,-./:;=?@_~  (and alphanumeric ASCII)
///
/// There is a nice contiguous run of 10 symbols between `&` and `/`, which we
/// can test in two comparisons, leaving these assorted:
///
///     !#$:;=?@_~
///
/// Each URI encoded byte is formed by a '%' and the two-digit
/// hexadecimal value of the byte.
///
/// Letters in the hexadecimal value must be uppercase, for example "%1A".
///
fn writeUriEncoded(writer: anytype, text: []const u8) !usize {
    const remaining_characters = "!#$:;=?@_~";
    var written: usize = 0;
    for (text) |c| {
        const should_encode = should: {
            if (c == ' ' or std.ascii.isAlphanumeric(c)) {
                break :should false;
            }
            if ('&' <= c and c <= '/') {
                break :should false;
            }
            for (remaining_characters) |r| {
                if (r == c) {
                    break :should false;
                }
            }
            break :should true;
        };

        if (!should_encode) {
            try writer.writeByte(c);
            written += 1;
            continue;
        }
        // Whatever remains, encode it
        try writer.writeByte('%');
        written += 1;
        const hexen = std.fmt.bytesToHex(&[_]u8{c}, .upper);
        written += try writer.write(&hexen);
    }
    return written;
}

fn encodeUri(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var charlist = try ArrayList(u8).initCapacity(allocator, text.len);
    defer charlist.deinit();
    const writer = charlist.writer();
    _ = try writeUriEncoded(writer, text);
    return charlist.toOwnedSlice();
}

//|
//| UTILITIES
//|

inline fn boolInt(b: bool) u8 {
    return @intFromBool(b);
}

inline fn fixSplitForward(text: []const u8, i: usize) usize {
    var idx = i;
    while (idx < text.len and is_follow(text[idx])) : (idx += 1) {}
    return idx;
}

inline fn fixSplitBackward(text: []const u8, i: usize) usize {
    var idx = i;
    if (idx < text.len) while (idx != 0 and is_follow(text[idx])) : (idx -= 1) {};
    return idx;
}

inline fn cast(as: type, val: anytype) as {
    return @intCast(val);
}

fn countDigits(text: []const u8) usize {
    var idx: usize = 0;
    while (std.ascii.isDigit(text[idx])) : (idx += 1) {}
    return idx;
}

//|
//| TESTS
//|

test "encodeUri" {
    const allocator = std.testing.allocator;
    const special_chars = "!#$&'()*+,-./:;=?@_~";
    const special_encoded = try encodeUri(allocator, special_chars);
    defer allocator.free(special_encoded);
    try testing.expectEqualStrings(special_chars, special_encoded);
    const alphaspace = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    const alpha_encoded = try encodeUri(allocator, alphaspace);
    defer allocator.free(alpha_encoded);
    try testing.expectEqualStrings(alphaspace, alpha_encoded);
    const to_encode = "\"%<>[\\]^`{|}δ";
    const encoded = try encodeUri(allocator, to_encode);
    defer allocator.free(encoded);
    try testing.expectEqualStrings("%22%25%3C%3E%5B%5C%5D%5E%60%7B%7C%7D%CE%B4", encoded);
    const decoded = try decodeUri(allocator, encoded);
    defer allocator.free(decoded);
    try testing.expectEqualStrings(to_encode, decoded);
}

test diffCommonPrefix {
    // Detect any common suffix.
    try testing.expectEqual(@as(usize, 0), diffCommonPrefix("abc", "xyz")); // Null case
    try testing.expectEqual(@as(usize, 4), diffCommonPrefix("1234abcdef", "1234xyz")); // Non-null case
    try testing.expectEqual(@as(usize, 4), diffCommonPrefix("1234", "1234xyz")); // Whole case
}

test diffCommonSuffix {
    // Detect any common suffix.
    try testing.expectEqual(@as(usize, 0), diffCommonSuffix("abc", "xyz")); // Null case
    try testing.expectEqual(@as(usize, 4), diffCommonSuffix("abcdef1234", "xyz1234")); // Non-null case
    try testing.expectEqual(@as(usize, 4), diffCommonSuffix("1234", "xyz1234")); // Whole case
}

test diffCommonOverlap {
    // Detect any suffix/prefix overlap.
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("", "abcd")); // Null case
    try testing.expectEqual(@as(usize, 3), diffCommonOverlap("abc", "abcd")); // Whole case
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("123456", "abcd")); // No overlap
    try testing.expectEqual(@as(usize, 3), diffCommonOverlap("123456xxx", "xxxabcd")); // Overlap

    // Some overly clever languages (C#) may treat ligatures as equal to their
    // component letters.  E.g. U+FB01 == 'fi'
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("fi", "\u{fb01}")); // Unicode
}

const TestHalfMatch = struct {
    dmp: DiffMatchPatch,
    before: []const u8,
    after: []const u8,
    expected: ?HalfMatchResult,
};

fn testDiffHalfMatch(
    allocator: std.mem.Allocator,
    params: TestHalfMatch,
) !void {
    const maybe_result = try params.dmp.diffHalfMatch(allocator, params.before, params.after);
    defer if (maybe_result) |result| result.deinit(allocator);
    try testing.expectEqualDeep(params.expected, maybe_result);
}

fn testdiffHalfMatchLeak(allocator: Allocator) !void {
    const dmp = DiffMatchPatch{};
    const text1 = "The quick brown fox jumps over the lazy dog.";
    const text2 = "That quick brown fox jumped over a lazy dog.";
    var diffs = try dmp.diff(allocator, text2, text1, true);
    deinitDiffList(allocator, &diffs);
}

test "diffHalfMatch leak regression test" {
    try testing.checkAllAllocationFailures(testing.allocator, testdiffHalfMatchLeak, .{});
}

test diffHalfMatch {
    const one_timeout: DiffMatchPatch = .{ .diff_timeout = 1 };

    // No match #1
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "1234567890",
        .after = "abcdef",
        .expected = null,
    }});

    // No match #2
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "12345",
        .after = "23",
        .expected = null,
    }});

    // Single matches
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "1234567890",
        .after = "a345678z",
        .expected = .{
            .prefix_before = "12",
            .suffix_before = "90",
            .prefix_after = "a",
            .suffix_after = "z",
            .common_middle = "345678",
        },
    }});

    // Single Match #2
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "a345678z",
        .after = "1234567890",
        .expected = .{
            .prefix_before = "a",
            .suffix_before = "z",
            .prefix_after = "12",
            .suffix_after = "90",
            .common_middle = "345678",
        },
    }});

    // Single Match #3
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "abc56789z",
        .after = "1234567890",
        .expected = .{
            .prefix_before = "abc",
            .suffix_before = "z",
            .prefix_after = "1234",
            .suffix_after = "0",
            .common_middle = "56789",
        },
    }});

    // Single Match #4
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "a23456xyz",
        .after = "1234567890",
        .expected = .{
            .prefix_before = "a",
            .suffix_before = "xyz",
            .prefix_after = "1",
            .suffix_after = "7890",
            .common_middle = "23456",
        },
    }});

    // Multiple matches #1
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "121231234123451234123121",
        .after = "a1234123451234z",
        .expected = .{
            .prefix_before = "12123",
            .suffix_before = "123121",
            .prefix_after = "a",
            .suffix_after = "z",
            .common_middle = "1234123451234",
        },
    }});

    // Multiple Matches #2
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "x-=-=-=-=-=-=-=-=-=-=-=-=",
        .after = "xx-=-=-=-=-=-=-=",
        .expected = .{
            .prefix_before = "",
            .suffix_before = "-=-=-=-=-=",
            .prefix_after = "x",
            .suffix_after = "",
            .common_middle = "x-=-=-=-=-=-=-=",
        },
    }});

    // Multiple Matches #3
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "-=-=-=-=-=-=-=-=-=-=-=-=y",
        .after = "-=-=-=-=-=-=-=yy",
        .expected = .{
            .prefix_before = "-=-=-=-=-=",
            .suffix_before = "",
            .prefix_after = "",
            .suffix_after = "y",
            .common_middle = "-=-=-=-=-=-=-=y",
        },
    }});

    // Other cases

    // Optimal diff would be -q+x=H-i+e=lloHe+Hu=llo-Hew+y not -qHillo+x=HelloHe-w+Hulloy
    // Non-optimal halfmatch
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = one_timeout,
        .before = "qHilloHelloHew",
        .after = "xHelloHeHulloy",
        .expected = .{
            .prefix_before = "qHillo",
            .suffix_before = "w",
            .prefix_after = "x",
            .suffix_after = "Hulloy",
            .common_middle = "HelloHe",
        },
    }});

    // Non-optimal halfmatch
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .dmp = .{ .diff_timeout = 0 },
        .before = "qHilloHelloHew",
        .after = "xHelloHeHulloy",
        .expected = null,
    }});
}

test diffLinesToChars {
    const allocator = testing.allocator;
    // Convert lines down to characters.
    var tmp_array_list = ArrayList([]const u8).init(allocator);
    defer tmp_array_list.deinit();
    try tmp_array_list.append("alpha\n");
    try tmp_array_list.append("beta\n");

    var result = try diffLinesToChars(allocator, "alpha\nbeta\nalpha\n", "beta\nalpha\nbeta\n");
    try testing.expectEqualStrings(" ! ", result.chars_1); // Shared lines #1
    try testing.expectEqualStrings("! !", result.chars_2); // Shared lines #2
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items); // Shared lines #3
    result.deinit(allocator);

    tmp_array_list.items.len = 0;
    try tmp_array_list.append("alpha\r\n");
    try tmp_array_list.append("beta\r\n");
    try tmp_array_list.append("\r\n");

    result = try diffLinesToChars(allocator, "", "alpha\r\nbeta\r\n\r\n\r\n");
    try testing.expectEqualStrings("", result.chars_1); // Empty string and blank lines #1
    try testing.expectEqualStrings(" !\"\"", result.chars_2); // Empty string and blank lines #2
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items); // Empty string and blank lines #3
    result.deinit(allocator);
    tmp_array_list.items.len = 0;
    try tmp_array_list.append("a");
    try tmp_array_list.append("b");

    result = try diffLinesToChars(allocator, "a", "b");
    try testing.expectEqualStrings(" ", result.chars_1); // No linebreaks #1.
    try testing.expectEqualStrings("!", result.chars_2); // No linebreaks #2.
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items); // No linebreaks #3.
    result.deinit(allocator);

    {
        const n: u21 = 1024;

        var line_list = ArrayList(u8).init(allocator);
        defer line_list.deinit();
        var char_list = ArrayList(u8).init(allocator);
        defer char_list.deinit();

        var i: u21 = CHAR_OFFSET;
        var char_buf: [4]u8 = undefined;
        while (i < n) : (i += 1) {
            const nbytes = std.unicode.wtf8Encode(i, &char_buf) catch unreachable;
            try line_list.appendSlice(char_buf[0..nbytes]);
            try line_list.append('\n');
            try char_list.appendSlice(char_buf[0..nbytes]);
        }
        const codepoint_len = std.unicode.utf8CountCodepoints(char_list.items) catch unreachable;
        try testing.expectEqual(@as(usize, n - CHAR_OFFSET), codepoint_len);
        result = try diffLinesToChars(allocator, line_list.items, "");
        try testing.expectEqual(char_list.items.len, result.chars_1.len);
        try testing.expectEqualSlices(u8, char_list.items, result.chars_1);
        try testing.expectEqualStrings("", result.chars_2);
        result.deinit(allocator);

        // Test iterator stop
        // TODO this isn't a complete test, it verifies that iteration
        // stops, but not that it does so correctly.
        var line_array = ArrayListUnmanaged([]const u8){};
        defer line_array.deinit(allocator);
        line_array.items.len = 0;
        var line_hash = std.StringHashMapUnmanaged(u21){};
        defer line_hash.deinit(allocator);
        const char_out = try diffLinesToCharsMunge(allocator, line_list.items, &line_array, &line_hash, 950);
        defer allocator.free(char_out);
        try testing.expectEqualStrings(
            "ϖ\nϗ\nϘ\nϙ\nϚ\nϛ\nϜ\nϝ\nϞ\nϟ\nϠ\nϡ\nϢ\nϣ\nϤ\nϥ\nϦ\nϧ\nϨ\nϩ\nϪ\nϫ\nϬ\nϭ\nϮ\nϯ\nϰ\nϱ\nϲ\nϳ\nϴ\nϵ\n϶\nϷ\nϸ\nϹ\nϺ\nϻ\nϼ\nϽ\nϾ\nϿ\n",
            line_array.getLast(),
        );
    }
}

const TCharLines = struct {
    diffs: []const Edit,
    line_array: []const []const u8,
    expected: []const Edit,
};

fn testDiffCharsToLines(
    allocator: std.mem.Allocator,
    params: TCharLines,
) !void {
    var char_diffs = try DiffList.initCapacity(allocator, params.diffs.len);
    defer deinitDiffList(allocator, &char_diffs);

    for (params.diffs) |item| {
        char_diffs.appendAssumeCapacity(.{ .operation = item.operation, .text = try allocator.dupe(u8, item.text) });
    }

    var diffs = try diffCharsToLines(allocator, &char_diffs, params.line_array);
    defer deinitDiffList(allocator, &diffs);

    try testing.expectEqualDeep(params.expected, diffs.items);
}

test diffCharsToLines {
    // Convert chars up to lines.
    var diff_list: DiffList = .empty;
    defer deinitDiffList(testing.allocator, &diff_list);
    try diff_list.ensureTotalCapacity(testing.allocator, 2);
    diff_list.appendSliceAssumeCapacity(&.{
        Edit.init(.equal, try testing.allocator.dupe(u8, " ! ")),
        Edit.init(.insert, try testing.allocator.dupe(u8, "! !")),
    });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDiffCharsToLines,
        .{TCharLines{
            .diffs = diff_list.items,
            .line_array = &[_][]const u8{
                "alpha\n",
                "beta\n",
            },
            .expected = &.{
                .{ .operation = .equal, .text = "alpha\nbeta\nalpha\n" },
                .{ .operation = .insert, .text = "beta\nalpha\nbeta\n" },
            },
        }},
    );
}

fn testDiffCleanupMerge(
    allocator: std.mem.Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .text = try allocator.dupe(u8, item.text) });
    }

    try diffCleanupMerge(allocator, &diffs);

    try testing.expectEqualDeep(params.expected, diffs.items);
}

test diffCleanupMerge {
    // Cleanup a messy diff.

    // No change case
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "b" },
            .{ .operation = .insert, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "b" },
            .{ .operation = .insert, .text = "c" },
        },
    }});

    // Merge equalities
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .equal, .text = "b" },
            .{ .operation = .equal, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "abc" },
        },
    }});

    // Merge deletions
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .delete, .text = "b" },
            .{ .operation = .delete, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abc" },
        },
    }});

    // Merge insertions
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .insert, .text = "a" },
            .{ .operation = .insert, .text = "b" },
            .{ .operation = .insert, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .insert, .text = "abc" },
        },
    }});

    // Merge interweave
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .insert, .text = "b" },
            .{ .operation = .delete, .text = "c" },
            .{ .operation = .insert, .text = "d" },
            .{ .operation = .equal, .text = "e" },
            .{ .operation = .equal, .text = "f" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "ac" },
            .{ .operation = .insert, .text = "bd" },
            .{ .operation = .equal, .text = "ef" },
        },
    }});

    // Prefix and suffix detection
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .insert, .text = "abc" },
            .{ .operation = .delete, .text = "dc" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "d" },
            .{ .operation = .insert, .text = "b" },
            .{ .operation = .equal, .text = "c" },
        },
    }});

    // Prefix and suffix detection with equalities
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "x" },
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .insert, .text = "abc" },
            .{ .operation = .delete, .text = "dc" },
            .{ .operation = .equal, .text = "y" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "xa" },
            .{ .operation = .delete, .text = "d" },
            .{ .operation = .insert, .text = "b" },
            .{ .operation = .equal, .text = "cy" },
        },
    }});

    // Slide edit left
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .insert, .text = "ba" },
            .{ .operation = .equal, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .insert, .text = "ab" },
            .{ .operation = .equal, .text = "ac" },
        },
    }});

    // Slide edit right
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "c" },
            .{ .operation = .insert, .text = "ab" },
            .{ .operation = .equal, .text = "a" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "ca" },
            .{ .operation = .insert, .text = "ba" },
        },
    }});

    // Slide edit left recursive
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "b" },
            .{ .operation = .equal, .text = "c" },
            .{ .operation = .delete, .text = "ac" },
            .{ .operation = .equal, .text = "x" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abc" },
            .{ .operation = .equal, .text = "acx" },
        },
    }});

    // Slide edit right recursive
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "x" },
            .{ .operation = .delete, .text = "ca" },
            .{ .operation = .equal, .text = "c" },
            .{ .operation = .delete, .text = "b" },
            .{ .operation = .equal, .text = "a" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "xca" },
            .{ .operation = .delete, .text = "cba" },
        },
    }});

    // Empty merge
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "b" },
            .{ .operation = .insert, .text = "ab" },
            .{ .operation = .equal, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .insert, .text = "a" },
            .{ .operation = .equal, .text = "bc" },
        },
    }});

    // Empty equality
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "" },
            .{ .operation = .insert, .text = "a" },
            .{ .operation = .equal, .text = "b" },
        },
        .expected = &.{
            .{ .operation = .insert, .text = "a" },
            .{ .operation = .equal, .text = "b" },
        },
    }});
}

fn testDiffCleanupSemanticLossless(
    allocator: std.mem.Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .text = try allocator.dupe(u8, item.text) });
    }

    try diffCleanupSemanticLossless(allocator, &diffs);

    try testing.expectEqualDeep(params.expected, diffs.items);
}

fn sliceToDiffList(allocator: Allocator, diff_slice: []const Edit) !DiffList {
    var diff_list: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diff_list);
    try diff_list.ensureTotalCapacity(allocator, diff_slice.len);
    for (diff_slice) |d| {
        diff_list.appendAssumeCapacity(Edit.init(
            d.operation,
            try allocator.dupe(u8, d.text),
        ));
    }
    return diff_list;
}

test diffCleanupSemanticLossless {
    // Null case
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &[_]Edit{},
        .expected = &[_]Edit{},
    }});

    //defer deinitDiffList(allocator, &diffs);
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "AAA\r\n\r\nBBB" },
            .{ .operation = .insert, .text = "\r\nDDD\r\n\r\nBBB" },
            .{ .operation = .equal, .text = "\r\nEEE" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "AAA\r\n\r\n" },
            .{ .operation = .insert, .text = "BBB\r\nDDD\r\n\r\n" },
            .{ .operation = .equal, .text = "BBB\r\nEEE" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "AAA\r\nBBB" },
            .{ .operation = .insert, .text = " DDD\r\nBBB" },
            .{ .operation = .equal, .text = " EEE" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "AAA\r\n" },
            .{ .operation = .insert, .text = "BBB DDD\r\n" },
            .{ .operation = .equal, .text = "BBB EEE" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "The c" },
            .{ .operation = .insert, .text = "ow and the c" },
            .{ .operation = .equal, .text = "at." },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "The " },
            .{ .operation = .insert, .text = "cow and the " },
            .{ .operation = .equal, .text = "cat." },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "The-c" },
            .{ .operation = .insert, .text = "ow-and-the-c" },
            .{ .operation = .equal, .text = "at." },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "The-" },
            .{ .operation = .insert, .text = "cow-and-the-" },
            .{ .operation = .equal, .text = "cat." },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .equal, .text = "ax" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .equal, .text = "aax" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "xa" },
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .equal, .text = "a" },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "xaa" },
            .{ .operation = .delete, .text = "a" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "The xxx. The " },
            .{ .operation = .insert, .text = "zzz. The " },
            .{ .operation = .equal, .text = "yyy." },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "The xxx." },
            .{ .operation = .insert, .text = " The zzz." },
            .{ .operation = .equal, .text = " The yyy." },
        },
    }});
}

fn rebuildtexts(allocator: std.mem.Allocator, diffs: DiffList) ![2][]const u8 {
    var text = [2]ArrayList(u8){
        ArrayList(u8).init(allocator),
        ArrayList(u8).init(allocator),
    };
    errdefer {
        text[0].deinit();
        text[1].deinit();
    }

    for (diffs.items) |myDiff| {
        if (myDiff.operation != .insert) {
            try text[0].appendSlice(myDiff.text);
        }
        if (myDiff.operation != .delete) {
            try text[1].appendSlice(myDiff.text);
        }
    }
    const t0_owned = try text[0].toOwnedSlice();
    errdefer allocator.free(t0_owned);
    return .{
        t0_owned,
        try text[1].toOwnedSlice(),
    };
}

const TRebuild = struct {
    before: []const u8,
    after: []const u8,
};

fn testRebuildTexts(allocator: Allocator, diffs: DiffList, params: TRebuild) !void {
    const texts = try rebuildtexts(allocator, diffs);
    defer {
        allocator.free(texts[0]);
        allocator.free(texts[1]);
    }
    try testing.expectEqualStrings(params.before, texts[0]);
    try testing.expectEqualStrings(params.after, texts[1]);
}

test rebuildtexts {
    {
        var diffs = try sliceToDiffList(testing.allocator, &.{
            .{ .operation = .insert, .text = "abcabc" },
            .{ .operation = .equal, .text = "defdef" },
            .{ .operation = .delete, .text = "ghighi" },
        });
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.checkAllAllocationFailures(testing.allocator, testRebuildTexts, .{
            diffs,
            TRebuild{
                .before = "defdefghighi",
                .after = "abcabcdefdef",
            },
        });
    }
    {
        var diffs = try sliceToDiffList(testing.allocator, &.{
            .{ .operation = .insert, .text = "xxx" },
            .{ .operation = .delete, .text = "yyy" },
        });
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.checkAllAllocationFailures(testing.allocator, testRebuildTexts, .{
            diffs,
            TRebuild{
                .before = "yyy",
                .after = "xxx",
            },
        });
    }
    {
        var diffs = try sliceToDiffList(testing.allocator, &.{
            .{ .operation = .equal, .text = "xyz" },
            .{ .operation = .equal, .text = "pdq" },
        });
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.checkAllAllocationFailures(testing.allocator, testRebuildTexts, .{
            diffs,
            TRebuild{
                .before = "xyzpdq",
                .after = "xyzpdq",
            },
        });
    }
}

const TBisect = struct {
    dmp: DiffMatchPatch,
    before: []const u8,
    after: []const u8,
    deadline: u64,
    expected: []const Edit,
};

fn testDiffBisect(
    allocator: std.mem.Allocator,
    params: TBisect,
) !void {
    var diffs = try params.dmp.diffBisect(allocator, params.before, params.after, params.deadline);
    defer deinitDiffList(allocator, &diffs);
    try testing.expectEqualDeep(params.expected, diffs.items);
}

test diffBisect {
    const this: DiffMatchPatch = .{ .diff_timeout = 0 };

    const a = "cat";
    const b = "map";

    // Normal
    try testing.checkAllAllocationFailures(testing.allocator, testDiffBisect, .{TBisect{
        .dmp = this,
        .before = a,
        .after = b,
        // std.time returns an i64
        .deadline = std.math.maxInt(i64),
        .expected = &.{
            .{ .operation = .delete, .text = "c" },
            .{ .operation = .insert, .text = "m" },
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "t" },
            .{ .operation = .insert, .text = "p" },
        },
    }});

    // Timeout
    try testing.checkAllAllocationFailures(testing.allocator, testDiffBisect, .{TBisect{
        .dmp = this,
        .before = a,
        .after = b,
        .deadline = 0, // Do not run prior to 1970
        .expected = &.{
            .{ .operation = .delete, .text = "cat" },
            .{ .operation = .insert, .text = "map" },
        },
    }});
}

const TDiff = struct {
    dmp: DiffMatchPatch,
    before: []const u8,
    after: []const u8,
    check_lines: bool,
    expected: []const Edit,
};

fn testDiff(
    allocator: std.mem.Allocator,
    params: TDiff,
) !void {
    var diffs = try params.dmp.diff(allocator, params.before, params.after, params.check_lines);
    defer deinitDiffList(allocator, &diffs);
    try testing.expectEqualDeep(params.expected, diffs.items);
}

test diff {
    const dmp: DiffMatchPatch = .{ .diff_timeout = 0 };

    //  Null case.
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "",
        .after = "",
        .check_lines = false,
        .expected = &[_]Edit{},
    }});

    //  Equality.
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "abc",
        .after = "abc",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .equal, .text = "abc" },
        },
    }});

    // Simple insertion.
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "abc",
        .after = "ab123c",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .equal, .text = "ab" },
            .{ .operation = .insert, .text = "123" },
            .{ .operation = .equal, .text = "c" },
        },
    }});

    // Simple deletion.
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "a123bc",
        .after = "abc",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "123" },
            .{ .operation = .equal, .text = "bc" },
        },
    }});

    // Two insertions.
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "abc",
        .after = "a123b456c",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .insert, .text = "123" },
            .{ .operation = .equal, .text = "b" },
            .{ .operation = .insert, .text = "456" },
            .{ .operation = .equal, .text = "c" },
        },
    }});

    // Two deletions.
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "a123b456c",
        .after = "abc",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "123" },
            .{ .operation = .equal, .text = "b" },
            .{ .operation = .delete, .text = "456" },
            .{ .operation = .equal, .text = "c" },
        },
    }});

    // Simple case #1
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "a",
        .after = "b",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .insert, .text = "b" },
        },
    }});

    // Simple case #2
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "Apples are a fruit.",
        .after = "Bananas are also fruit.",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .delete, .text = "Apple" },
            .{ .operation = .insert, .text = "Banana" },
            .{ .operation = .equal, .text = "s are a" },
            .{ .operation = .insert, .text = "lso" },
            .{ .operation = .equal, .text = " fruit." },
        },
    }});

    // Simple case #3
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "ax\t",
        .after = "\u{0680}x\x00",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .insert, .text = "\u{0680}" },
            .{ .operation = .equal, .text = "x" },
            .{ .operation = .delete, .text = "\t" },
            .{ .operation = .insert, .text = "\x00" },
        },
    }});

    // Overlap #1
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "1ayb2",
        .after = "abxab",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .delete, .text = "1" },
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "y" },
            .{ .operation = .equal, .text = "b" },
            .{ .operation = .delete, .text = "2" },
            .{ .operation = .insert, .text = "xab" },
        },
    }});

    // Overlap #2
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "abcy",
        .after = "xaxcxabc",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .insert, .text = "xaxcx" },
            .{ .operation = .equal, .text = "abc" },
            .{ .operation = .delete, .text = "y" },
        },
    }});

    // Overlap #3
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "ABCDa=bcd=efghijklmnopqrsEFGHIJKLMNOefg",
        .after = "a-bcd-efghijklmnopqrs",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .delete, .text = "ABCD" },
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .delete, .text = "=" },
            .{ .operation = .insert, .text = "-" },
            .{ .operation = .equal, .text = "bcd" },
            .{ .operation = .delete, .text = "=" },
            .{ .operation = .insert, .text = "-" },
            .{ .operation = .equal, .text = "efghijklmnopqrs" },
            .{ .operation = .delete, .text = "EFGHIJKLMNOefg" },
        },
    }});

    // Large equality
    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .dmp = dmp,
        .before = "a [[Pennsylvania]] and [[New",
        .after = " and [[Pennsylvania]]",
        .check_lines = false,
        .expected = &.{
            .{ .operation = .insert, .text = " " },
            .{ .operation = .equal, .text = "a" },
            .{ .operation = .insert, .text = "nd" },
            .{ .operation = .equal, .text = " [[Pennsylvania]]" },
            .{ .operation = .delete, .text = " and [[New" },
        },
    }});

    const allocator = testing.allocator;
    // TODO these tests should be checked for allocation failure

    // Increase the text lengths by 1024 times to ensure a timeout.
    {
        const a = "`Twas brillig, and the slithy toves\nDid gyre and gimble in the wabe:\nAll mimsy were the borogoves,\nAnd the mome raths outgrabe.\n" ** 1024;
        const b = "I am the very model of a modern major general,\nI've information vegetable, animal, and mineral,\nI know the kings of England, and I quote the fights historical,\nFrom Marathon to Waterloo, in order categorical.\n" ** 1024;

        const with_timout: DiffMatchPatch = .{
            .diff_timeout = 100, // 100ms
        };

        const start_time = std.time.milliTimestamp();
        {
            var time_diff = try with_timout.diff(allocator, a, b, false);
            defer deinitDiffList(allocator, &time_diff);
        }
        const end_time = std.time.milliTimestamp();

        // Test that we took at least the timeout period.
        try testing.expect(with_timout.diff_timeout <= end_time - start_time); // diff: Timeout min.
        // Test that we didn't take forever (be forgiving).
        // Theoretically this test could fail very occasionally if the
        // OS task swaps or locks up for a second at the wrong moment.
        try testing.expect((with_timout.diff_timeout) * 10000 * 2 > end_time - start_time); // diff: Timeout max.
    }
}

fn testDiffLineMode(
    allocator: Allocator,
    dmp: *DiffMatchPatch,
    before: []const u8,
    after: []const u8,
) !void {
    dmp.diff_check_lines_over = 20;
    var diff_checked = try dmp.diff(allocator, before, after, true);
    defer deinitDiffList(allocator, &diff_checked);

    var diff_unchecked = try dmp.diff(allocator, before, after, false);
    defer deinitDiffList(allocator, &diff_unchecked);

    try testing.expectEqualDeep(diff_checked.items, diff_unchecked.items); // diff: Simple line-mode.
    dmp.diff_check_lines_over = 100;
}

test "diffLineMode" {
    var dmp: DiffMatchPatch = .{ .diff_timeout = 0 };
    const allocator = testing.allocator;
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDiffLineMode,
        .{
            &dmp,
            "1234567890\n1234567890\n1234567890",
            "abcdefghij\nabcdefghij\nabcdefghij",
        },
    );

    {
        const a = "1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890";
        const b = "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij";

        var diff_checked = try dmp.diff(allocator, a, b, true);
        defer deinitDiffList(allocator, &diff_checked);

        var diff_unchecked = try dmp.diff(allocator, a, b, false);
        defer deinitDiffList(allocator, &diff_unchecked);

        try testing.expectEqualDeep(diff_checked.items, diff_unchecked.items); // diff: Single line-mode.
    }

    {
        // diff: Overlap line-mode.
        const a = "1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n1234567890\n";
        const b = "abcdefghij\n1234567890\n1234567890\n1234567890\nabcdefghij\n1234567890\n1234567890\n1234567890\nabcdefghij\n1234567890\n1234567890\n1234567890\nabcdefghij\n";

        var diffs_linemode = try dmp.diff(allocator, a, b, true);
        defer deinitDiffList(allocator, &diffs_linemode);

        const texts_linemode = try rebuildtexts(allocator, diffs_linemode);
        defer {
            allocator.free(texts_linemode[0]);
            allocator.free(texts_linemode[1]);
        }

        var diffs_textmode = try dmp.diff(allocator, a, b, false);
        defer deinitDiffList(allocator, &diffs_textmode);

        const texts_textmode = try rebuildtexts(allocator, diffs_textmode);
        defer {
            allocator.free(texts_textmode[0]);
            allocator.free(texts_textmode[1]);
        }

        try testing.expectEqualStrings(texts_textmode[0], texts_linemode[0]);
        try testing.expectEqualStrings(texts_textmode[1], texts_linemode[1]);
    }
}

/// Round-trip a diff, confirming that the result matches the original.
fn diffRoundTrip(allocator: Allocator, dmp: DiffMatchPatch, diff_slice: []const Edit) !void {
    var diffs_before = try DiffList.initCapacity(allocator, diff_slice.len);
    defer deinitDiffList(allocator, &diffs_before);
    for (diff_slice) |item| {
        diffs_before.appendAssumeCapacity(.{ .operation = item.operation, .text = try allocator.dupe(u8, item.text) });
    }
    const text_before = try diffBeforeText(allocator, diffs_before);
    defer allocator.free(text_before);
    const text_after = try diffAfterText(allocator, diffs_before);
    defer allocator.free(text_after);
    var diffs_after = try dmp.diff(allocator, text_before, text_after, false);
    defer deinitDiffList(allocator, &diffs_after);
    // Should change nothing:
    try diffCleanupSemantic(allocator, &diffs_after);
    try testing.expectEqualDeep(diffs_before.items, diffs_after.items);
}

test "Unicode diffs" {
    const allocator = std.testing.allocator;
    var dmp = DiffMatchPatch{};
    dmp.diff_timeout = 0;
    {
        var greek_diff = try dmp.diff(
            allocator,
            "αβγ",
            "αβδ",
            false,
        );
        defer deinitDiffList(allocator, &greek_diff);
        try testing.expectEqualDeep(@as([]const Edit, &.{
            Edit.init(.equal, "αβ"),
            Edit.init(.delete, "γ"),
            Edit.init(.insert, "δ"),
        }), greek_diff.items);
    }
    {
        // ө is 0xd3, 0xa9, թ is 0xd6, 0xa9
        var prefix_diff = try dmp.diff(
            allocator,
            "abө",
            "abթ",
            false,
        );
        defer deinitDiffList(allocator, &prefix_diff);
        try testing.expectEqualDeep(@as([]const Edit, &.{
            Edit.init(.equal, "ab"),
            Edit.init(.delete, "ө"),
            Edit.init(.insert, "թ"),
        }), prefix_diff.items);
    }
    {
        var mid_diff = try dmp.diff(
            allocator,
            "αөβ",
            "αթβ",
            false,
        );
        defer deinitDiffList(allocator, &mid_diff);
        try testing.expectEqualDeep(@as([]const Edit, &.{
            Edit.init(.equal, "α"),
            Edit.init(.delete, "ө"),
            Edit.init(.insert, "թ"),
            Edit.init(.equal, "β"),
        }), mid_diff.items);
    }
    {
        var mid_prefix = try dmp.diff(
            allocator,
            "αβλ",
            "αδλ",
            false,
        );
        defer deinitDiffList(allocator, &mid_prefix);
        try testing.expectEqualDeep(@as([]const Edit, &.{
            Edit.init(.equal, "α"),
            Edit.init(.delete, "β"),
            Edit.init(.insert, "δ"),
            Edit.init(.equal, "λ"),
        }), mid_prefix.items);
    }
    { // "三亥临" Three-byte, one different suffix
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "三亥" },
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "临" },
                },
            },
        );
    }
    { // "三亥乤" Three-byte, one middle difference in suffix
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "三亥" },
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "乤" },
                },
            },
        );
    }
    { // "三亥帤" Three-byte, one prefix difference in suffix
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "三亥" },
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "帤" },
                },
            },
        );
    }
    { // "三帤亥" Three-byte, one prefix difference in middle
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "三" },
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "帤" },
                    Edit{ .operation = .equal, .text = "亥" },
                },
            },
        );
    }
    { // "三乤亥" Three-byte, one middle difference in middle
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "三" },
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "乤" },
                    Edit{ .operation = .equal, .text = "亥" },
                },
            },
        );
    }
    { // "三临亥" Three-byte, one suffix difference in middle
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "三" },
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "临" },
                    Edit{ .operation = .equal, .text = "亥" },
                },
            },
        );
    }
    { // "临三亥" Three-byte, one suffix difference in prefix
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "临" },
                    Edit{ .operation = .equal, .text = "三亥" },
                },
            },
        );
    }
    { // "乤三亥" Three-byte, one middle difference in prefix
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "乤" },
                    Edit{ .operation = .equal, .text = "三亥" },
                },
            },
        );
    }
    { // "乤三亥" Three-byte, one prefix difference in prefix
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .delete, .text = "两" },
                    Edit{ .operation = .insert, .text = "帤" },
                    Edit{ .operation = .equal, .text = "三亥" },
                },
            },
        );
    }
    { // "三临亥" → "三丿亥" Three-byte, one suffix difference
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "三" },
                    Edit{ .operation = .delete, .text = "临" },
                    Edit{ .operation = .insert, .text = "丿" },
                    Edit{ .operation = .equal, .text = "亥" },
                },
            },
        );
    }
    { // Four-byte permutation #1
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "😹💋" },
                    Edit{ .operation = .delete, .text = "\xf0\x9f\xa5\xb9" },
                    Edit{ .operation = .insert, .text = "丿" },
                    Edit{ .operation = .equal, .text = "👀🫵" },
                },
            },
        );
    }
    { // Four-byte permutation #1
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "😹💋" },
                    Edit{ .operation = .delete, .text = "\xf0\x9f\xa5\xb9" },
                    Edit{ .operation = .insert, .text = "\xf1\x9f\xa5\xb9" },
                    Edit{ .operation = .equal, .text = "👀🫵" },
                },
            },
        );
    }
    { // Four-byte permutation #2
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "😹💋" },
                    Edit{ .operation = .delete, .text = "\xf0\x9f\xa5\xb9" },
                    Edit{ .operation = .insert, .text = "\xf0\xa0\xa5\xb9" },
                    Edit{ .operation = .equal, .text = "👀🫵" },
                },
            },
        );
    }
    { // Four-byte permutation #3
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "😹💋" },
                    Edit{ .operation = .delete, .text = "\xf0\x9f\xa5\xb9" },
                    Edit{ .operation = .insert, .text = "\xf0\x9f\xa4\xb9" },
                    Edit{ .operation = .equal, .text = "👀🫵" },
                },
            },
        );
    }
    { // Four-byte permutation #4
        try testing.checkAllAllocationFailures(
            allocator,
            diffRoundTrip,
            .{
                dmp, &.{
                    Edit{ .operation = .equal, .text = "😹💋" },
                    Edit{ .operation = .delete, .text = "\xf0\x9f\xa5\xb9" },
                    Edit{ .operation = .insert, .text = "\xf0\x9f\xa5\xb4" },
                    Edit{ .operation = .equal, .text = "👀🫵" },
                },
            },
        );
    }
    {
        const before = "<r>red</r> <t></t><b>blue</b><t> </t><g>green</g><t></t> <y>yellow</y>";
        const after = "<r>red</r>♦︎ <b>blue</b>♦︎<t>∅ </t><g>green</g>♦︎<t>∅</t>♦︎ <y>yellow</y>";
        var diffs = try dmp.diff(allocator, before, after, false);
        defer deinitDiffList(allocator, &diffs);
        const before_2 = try diffBeforeText(allocator, diffs);
        defer allocator.free(before_2);
        try testing.expectEqualStrings(before, before_2);
        const after_2 = try diffAfterText(allocator, diffs);
        defer allocator.free(after_2);
        try testing.expectEqualStrings(after, after_2);
    }
}

test "Diff format" {
    const a_diff = Edit{ .operation = .insert, .text = "add me" };
    const expect = "(+, \"add me\")";
    var out_buf: [13]u8 = undefined;
    const out_string = try std.fmt.bufPrint(&out_buf, "{f}", .{a_diff});
    try testing.expectEqualStrings(expect, out_string);
}

const TestIO = struct {
    input: []const Edit,
    expected: []const Edit,
};

fn testDiffCleanupSemantic(
    allocator: std.mem.Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .text = try allocator.dupe(u8, item.text) });
    }

    try diffCleanupSemantic(allocator, &diffs);

    try testing.expectEqualDeep(params.expected, diffs.items);
}

test diffCleanupSemantic {
    // Null case.
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &[_]Edit{},
        .expected = &[_]Edit{},
    }});

    // No elimination #1
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "ab" },
            .{ .operation = .insert, .text = "cd" },
            .{ .operation = .equal, .text = "12" },
            .{ .operation = .delete, .text = "e" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "ab" },
            .{ .operation = .insert, .text = "cd" },
            .{ .operation = .equal, .text = "12" },
            .{ .operation = .delete, .text = "e" },
        },
    }});

    // No elimination #2
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "abc" },
            .{ .operation = .insert, .text = "ABC" },
            .{ .operation = .equal, .text = "1234" },
            .{ .operation = .delete, .text = "wxyz" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abc" },
            .{ .operation = .insert, .text = "ABC" },
            .{ .operation = .equal, .text = "1234" },
            .{ .operation = .delete, .text = "wxyz" },
        },
    }});

    // Simple elimination
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "a" },
            .{ .operation = .equal, .text = "b" },
            .{ .operation = .delete, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abc" },
            .{ .operation = .insert, .text = "b" },
        },
    }});

    // Backpass elimination
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "ab" },
            .{ .operation = .equal, .text = "cd" },
            .{ .operation = .delete, .text = "e" },
            .{ .operation = .equal, .text = "f" },
            .{ .operation = .insert, .text = "g" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abcdef" },
            .{ .operation = .insert, .text = "cdfg" },
        },
    }});

    // Multiple elimination
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .insert, .text = "1" },
            .{ .operation = .equal, .text = "A" },
            .{ .operation = .delete, .text = "B" },
            .{ .operation = .insert, .text = "2" },
            .{ .operation = .equal, .text = "_" },
            .{ .operation = .insert, .text = "1" },
            .{ .operation = .equal, .text = "A" },
            .{ .operation = .delete, .text = "B" },
            .{ .operation = .insert, .text = "2" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "AB_AB" },
            .{ .operation = .insert, .text = "1A2_1A2" },
        },
    }});

    // Word boundaries
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .text = "The c" },
            .{ .operation = .delete, .text = "ow and the c" },
            .{ .operation = .equal, .text = "at." },
        },
        .expected = &.{
            .{ .operation = .equal, .text = "The " },
            .{ .operation = .delete, .text = "cow and the " },
            .{ .operation = .equal, .text = "cat." },
        },
    }});

    // No overlap elimination
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "abcxx" },
            .{ .operation = .insert, .text = "xxdef" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abcxx" },
            .{ .operation = .insert, .text = "xxdef" },
        },
    }});

    // Overlap elimination
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "abcxxx" },
            .{ .operation = .insert, .text = "xxxdef" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abc" },
            .{ .operation = .equal, .text = "xxx" },
            .{ .operation = .insert, .text = "def" },
        },
    }});

    // Reverse overlap elimination
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "xxxabc" },
            .{ .operation = .insert, .text = "defxxx" },
        },
        .expected = &.{
            .{ .operation = .insert, .text = "def" },
            .{ .operation = .equal, .text = "xxx" },
            .{ .operation = .delete, .text = "abc" },
        },
    }});

    // Two overlap eliminations
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .text = "abcd1212" },
            .{ .operation = .insert, .text = "1212efghi" },
            .{ .operation = .equal, .text = "----" },
            .{ .operation = .delete, .text = "A3" },
            .{ .operation = .insert, .text = "3BC" },
        },
        .expected = &.{
            .{ .operation = .delete, .text = "abcd" },
            .{ .operation = .equal, .text = "1212" },
            .{ .operation = .insert, .text = "efghi" },
            .{ .operation = .equal, .text = "----" },
            .{ .operation = .delete, .text = "A" },
            .{ .operation = .equal, .text = "3" },
            .{ .operation = .insert, .text = "BC" },
        },
    }});
}

fn testDiffCleanupEfficiency(
    allocator: Allocator,
    dmp: DiffMatchPatch,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .text = try allocator.dupe(u8, item.text) });
    }
    try dmp.diffCleanupEfficiency(allocator, &diffs);

    try testing.expectEqualDeep(params.expected, diffs.items);
}

test diffCleanupEfficiency {
    const allocator = testing.allocator;
    var dmp = DiffMatchPatch{};
    dmp.diff_edit_cost = 4;
    { // Null case.
        var diffs: DiffList = .empty;
        try dmp.diffCleanupEfficiency(allocator, &diffs);
        try testing.expectEqualDeep(DiffList.empty, diffs);
    }
    { // No elimination.
        const dslice: []const Edit = &.{
            .{ .operation = .delete, .text = "ab" },
            .{ .operation = .insert, .text = "12" },
            .{ .operation = .equal, .text = "wxyz" },
            .{ .operation = .delete, .text = "cd" },
            .{ .operation = .insert, .text = "34" },
        };
        try testing.checkAllAllocationFailures(
            testing.allocator,
            testDiffCleanupEfficiency,
            .{
                dmp,
                TestIO{ .input = dslice, .expected = dslice },
            },
        );
    }
    { // Four-edit elimination.
        const dslice: []const Edit = &.{
            .{ .operation = .delete, .text = "ab" },
            .{ .operation = .insert, .text = "12" },
            .{ .operation = .equal, .text = "xyz" },
            .{ .operation = .delete, .text = "cd" },
            .{ .operation = .insert, .text = "34" },
        };
        const d_after: []const Edit = &.{
            .{ .operation = .delete, .text = "abxyzcd" },
            .{ .operation = .insert, .text = "12xyz34" },
        };
        try testing.checkAllAllocationFailures(
            testing.allocator,
            testDiffCleanupEfficiency,
            .{
                dmp,
                TestIO{ .input = dslice, .expected = d_after },
            },
        );
    }
    { // Three-edit elimination.
        const dslice: []const Edit = &.{
            .{ .operation = .insert, .text = "12" },
            .{ .operation = .equal, .text = "x" },
            .{ .operation = .delete, .text = "cd" },
            .{ .operation = .insert, .text = "34" },
        };
        const d_after: []const Edit = &.{
            .{ .operation = .delete, .text = "xcd" },
            .{ .operation = .insert, .text = "12x34" },
        };
        try testing.checkAllAllocationFailures(
            testing.allocator,
            testDiffCleanupEfficiency,
            .{
                dmp,
                TestIO{ .input = dslice, .expected = d_after },
            },
        );
    }
    { // Backpass elimination.
        const dslice: []const Edit = &.{
            .{ .operation = .delete, .text = "ab" },
            .{ .operation = .insert, .text = "12" },
            .{ .operation = .equal, .text = "xy" },
            .{ .operation = .insert, .text = "34" },
            .{ .operation = .equal, .text = "z" },
            .{ .operation = .delete, .text = "cd" },
            .{ .operation = .insert, .text = "56" },
        };
        const d_after: []const Edit = &.{
            .{ .operation = .delete, .text = "abxyzcd" },
            .{ .operation = .insert, .text = "12xy34z56" },
        };
        try testing.checkAllAllocationFailures(
            testing.allocator,
            testDiffCleanupEfficiency,
            .{
                dmp,
                TestIO{ .input = dslice, .expected = d_after },
            },
        );
    }
    { // High cost elimination.
        dmp.diff_edit_cost = 5;
        const dslice: []const Edit = &.{
            .{ .operation = .delete, .text = "ab" },
            .{ .operation = .insert, .text = "12" },
            .{ .operation = .equal, .text = "wxyz" },
            .{ .operation = .delete, .text = "cd" },
            .{ .operation = .insert, .text = "34" },
        };
        const d_after: []const Edit = &.{
            .{ .operation = .delete, .text = "abwxyzcd" },
            .{ .operation = .insert, .text = "12wxyz34" },
        };
        try testing.checkAllAllocationFailures(
            testing.allocator,
            testDiffCleanupEfficiency,
            .{
                dmp,
                TestIO{ .input = dslice, .expected = d_after },
            },
        );
        dmp.diff_edit_cost = 4;
    }
}

test "diff before and after text" {
    const dmp = DiffMatchPatch{};
    const allocator = testing.allocator;
    const before = "The cat in the hat.";
    const after = "The bat in the belfry.";
    var diffs = try dmp.diff(allocator, before, after, false);
    defer deinitDiffList(allocator, &diffs);
    const before1 = try diffBeforeText(allocator, diffs);
    defer allocator.free(before1);
    const after1 = try diffAfterText(allocator, diffs);
    defer allocator.free(after1);
    try testing.expectEqualStrings(before, before1);
    try testing.expectEqualStrings(after, after1);
}

test diffIndex {
    const dmp = DiffMatchPatch{};
    {
        var diffs = try dmp.diff(
            testing.allocator,
            "The midnight train",
            "The blue midnight train",
            false,
        );
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.expectEqual(0, diffIndex(diffs, 0));
        try testing.expectEqual(9, diffIndex(diffs, 4));
    }
    {
        var diffs = try dmp.diff(
            testing.allocator,
            "Better still to live and learn",
            "Better yet to learn and live",
            false,
        );
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.expectEqual(11, diffIndex(diffs, 13));
        try testing.expectEqual(20, diffIndex(diffs, 21));
    }
}

test diffPrettyFormat {
    const test_deco = DiffDecorations{
        .delete_start = "<+>",
        .delete_end = "</+>",
        .insert_start = "<->",
        .insert_end = "</->",
        .equals_start = "<=>",
        .equals_end = "</=>",
    };
    const dmp = DiffMatchPatch{};
    const allocator = std.testing.allocator;
    var diffs = try dmp.diff(
        allocator,
        "A thing of beauty is a joy forever",
        "Singular beauty is enjoyed forever",
        false,
    );
    defer deinitDiffList(allocator, &diffs);
    try diffCleanupSemantic(allocator, &diffs);
    const out_text = try diffPrettyFormat(allocator, diffs, test_deco);
    defer allocator.free(out_text);
    try testing.expectEqualStrings(
        "<+>A thing of</+><->Singular</-><=> beauty is </=><+>a </+><->en</-><=>joy</=><->ed</-><=> forever</=>",
        out_text,
    );
}

fn testMapSubsetEquality(left: anytype, right: anytype) !void {
    var map_iter = left.iterator();
    while (map_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        try testing.expectEqual(value, right.get(key));
    }
}
test "matchAlphabet" {
    var map = std.AutoHashMap(u8, usize).init(testing.allocator);
    defer map.deinit();
    try map.put('a', 4);
    try map.put('b', 2);
    try map.put('c', 1);
    var bitap_map = try matchAlphabet(testing.allocator, "abc");
    defer bitap_map.deinit();
    try testMapSubsetEquality(map, bitap_map);
    map.clearRetainingCapacity();
    try map.put('a', 37);
    try map.put('b', 18);
    try map.put('c', 8);
    var bitap_map2 = try matchAlphabet(testing.allocator, "abcaba");
    defer bitap_map2.deinit();
    try testMapSubsetEquality(map, bitap_map2);
}

const TBitap = struct {
    text: []const u8,
    pattern: []const u8,
    loc: usize,
    expect: ?usize,
};

fn testMatchBitap(
    allocator: Allocator,
    dmp: DiffMatchPatch,
    params: TBitap,
) !void {
    const best_loc = try dmp.matchBitap(
        allocator,
        params.text,
        params.pattern,
        params.loc,
    );
    try testing.expectEqual(params.expect, best_loc);
}

test matchBitap {
    var dmp = DiffMatchPatch{};
    dmp.match_distance = 500;
    dmp.match_threshold = 0.5;
    // Exact match #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "fgh",
                .loc = 5,
                .expect = 5,
            },
        },
    );
    // Exact match #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "fgh",
                .loc = 0,
                .expect = 5,
            },
        },
    );
    // Fuzzy match #1
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "efxhi",
                .loc = 0,
                .expect = 4,
            },
        },
    );
    // Fuzzy match #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "cdefxyhijk",
                .loc = 5,
                .expect = 2,
            },
        },
    );
    // Fuzzy match #3.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "bxy",
                .loc = 1,
                .expect = null,
            },
        },
    );
    // Overflow.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "123456789xx0",
                .pattern = "3456789x0",
                .loc = 2,
                .expect = 2,
            },
        },
    );
    //Before start match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdef",
                .pattern = "xxabc",
                .loc = 4,
                .expect = 0,
            },
        },
    );
    //
    // Beyond end match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdef",
                .pattern = "defyy",
                .loc = 4,
                .expect = 3,
            },
        },
    );
    //  Oversized pattern.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdef",
                .pattern = "xabcdefy",
                .loc = 0,
                .expect = 0,
            },
        },
    );
    dmp.match_threshold = 0.4;
    // Threshold #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "efxyhi",
                .loc = 1,
                .expect = 4,
            },
        },
    );
    dmp.match_threshold = 0.3;
    //  Threshold #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "efxyhi",
                .loc = 1,
                .expect = null,
            },
        },
    );
    dmp.match_threshold = 0.0;
    //  Threshold #3.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "bcdef",
                .loc = 1,
                .expect = 1,
            },
        },
    );
    dmp.match_threshold = 0.5;
    //  Multiple select #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdexyzabcde",
                .pattern = "abccde",
                .loc = 5,
                .expect = 8,
            },
        },
    );
    dmp.match_distance = 10; // Strict location.
    //  Distance test #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijklmnopqrstuvwxyz",
                .pattern = "abcdefg",
                .loc = 1,
                .expect = 0,
            },
        },
    );
    // Distance test #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijklmnopqrstuvwxyz",
                .pattern = "abcdxxefg",
                .loc = 1,
                .expect = 0,
            },
        },
    );
    dmp.match_distance = 1000; // Loose location.
    //  Distance test #3.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            dmp,
            TBitap{
                .text = "abcdefghijklmnopqrstuvwxyz",
                .pattern = "abcdefg",
                .loc = 24,
                .expect = 0,
            },
        },
    );
}

test matchMain {
    var dmp = DiffMatchPatch{};
    dmp.match_threshold = 0.5;
    dmp.match_distance = 100;
    const allocator = testing.allocator;
    // Equality.
    try testing.expectEqual(0, dmp.matchMain(
        allocator,
        "abcdefg",
        "abcdefg",
        1000,
    ));
    // Null text
    try testing.expectEqual(null, dmp.matchMain(
        allocator,
        "",
        "abcdefg",
        1,
    ));
    // Null pattern.
    try testing.expectEqual(3, dmp.matchMain(
        allocator,
        "abcdefg",
        "",
        3,
    ));
    // Exact match.
    try testing.expectEqual(3, dmp.matchMain(
        allocator,
        "abcdefg",
        "de",
        3,
    ));
    // Beyond end match.
    try testing.expectEqual(3, dmp.matchMain(
        allocator,
        "abcdef",
        "defy",
        4,
    ));

    // Oversized pattern.
    try testing.expectEqual(0, dmp.matchMain(
        allocator,
        "abcdef",
        "abcdefy",
        0,
    ));
    dmp.match_threshold = 0.7;
    // Complex match.
    try testing.expectEqual(4, dmp.matchMain(
        allocator,
        "I am the very model of a modern major general.",
        " that berry ",
        5,
    ));
    dmp.match_threshold = 0.5;
}

fn testPatchToText(allocator: Allocator) !void {
    //
    var p: Hunk = Hunk{
        .start1 = 20,
        .start2 = 21,
        .length1 = 18,
        .length2 = 17,
        .diffs = try sliceToDiffList(allocator, &.{
            .{ .operation = .equal, .text = "jump" },
            .{ .operation = .delete, .text = "s" },
            .{ .operation = .insert, .text = "ed" },
            .{ .operation = .equal, .text = " over " },
            .{ .operation = .delete, .text = "the" },
            .{ .operation = .insert, .text = "a" },
            .{ .operation = .equal, .text = "\nlaz" },
        }),
    };
    defer p.deinit(allocator);
    const strp = "@@ -21,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n %0Alaz\n";
    const patch_str = try p.asText(allocator);
    defer allocator.free(patch_str);
    try testing.expectEqualStrings(strp, patch_str);
}

test "patch to text" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchToText,
        .{},
    );
}

fn testPatchRoundTrip(allocator: Allocator, patch_in: []const u8) !void {
    var patches = try patchFromText(allocator, patch_in);
    defer deinitPatchList(allocator, &patches);
    const patch_out = try patchToText(allocator, patches);
    defer allocator.free(patch_out);
    try testing.expectEqualStrings(patch_in, patch_out);
}

test "workshop" {
    try testPatchRoundTrip(
        testing.allocator,
        "@@ -0,0 +1,3 @@\n+abc\n@@ -0,0 +1,3 @@\n+abc\n",
    );
}

test "patch from text" {
    const allocator = testing.allocator;
    var p0 = try patchFromText(allocator, "");
    defer deinitPatchList(allocator, &p0);
    try testing.expectEqual(0, p0.items.len);
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -21,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n %0Alaz\n"},
    );
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchRoundTrip,
        .{"@@ -1 +1 @@\n-a\n+b\n"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -1,3 +0,0 @@\n-abc\n"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -0,0 +1,3 @@\n+abc\n"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -0,0 +1,3 @@\n+abc\n@@ -0,0 +1,3 @@\n+abc\n"},
    );
}

fn testBadPatchString(allocator: Allocator, patch: []const u8) !void {
    _ = patchFromText(allocator, patch) catch |e| {
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try testing.expectEqual(error.BadPatchString, e);
            },
        }
    };
}

test "error.BadPatchString" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"Bad\nPatch\nString\n"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ foo"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ +no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ !1,no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,3 +???"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,3 +4,5 ##"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,10??"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,10 ?"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@@ -1,3 +4,5 @!"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@@ -1,3 +4,5 +add\n@!"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -0,0 +1,3 @@\n+abc\n@@ -0,0 +1,3 @@\n+abc\n!!!"},
    );
}

fn testPatchAddContext(
    allocator: Allocator,
    dmp: DiffMatchPatch,
    patch_text: []const u8,
    text: []const u8,
    expect: []const u8,
) !void {
    _, var patch = try patchFromHeader(allocator, patch_text);
    defer patch.deinit(allocator);
    const patch_og = try patch.asText(allocator);
    defer allocator.free(patch_og);
    try testing.expectEqualStrings(patch_text, patch_og);
    try dmp.patchAddContext(allocator, &patch, text);
    const patch_out = try patch.asText(allocator);
    defer allocator.free(patch_out);
    try testing.expectEqualStrings(expect, patch_out);
}

test "testPatchAddContext" {
    const allocator = testing.allocator;
    var dmp = DiffMatchPatch{};
    dmp.patch_margin = 4;
    // Simple case.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            dmp,
            "@@ -21,4 +21,10 @@\n-jump\n+somersault\n",
            "The quick brown fox jumps over the lazy dog.",
            "@@ -17,12 +17,18 @@\n fox \n-jump\n+somersault\n s ov\n",
        },
    );
    // Not enough trailing context.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            dmp,
            "@@ -21,4 +21,10 @@\n-jump\n+somersault\n",
            "The quick brown fox jumps.",
            "@@ -17,10 +17,16 @@\n fox \n-jump\n+somersault\n s.\n",
        },
    );
    // Not enough leading context.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            dmp,
            "@@ -3 +3,2 @@\n-e\n+at\n",
            "The quick brown fox jumps.",
            "@@ -1,7 +1,8 @@\n Th\n-e\n+at\n  qui\n",
        },
    );
    // Ambiguity.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            dmp,
            "@@ -3 +3,2 @@\n-e\n+at\n",
            "The quick brown fox jumps.  The quick brown fox crashes.",
            "@@ -1,27 +1,28 @@\n Th\n-e\n+at\n  quick brown fox jumps. \n",
        },
    );
    // Unicode
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            dmp,
            "@@ -9,6 +10,3 @@\n-remove\n+add\n",
            "⊗⊘⊙remove⊙⊘⊗",
            \\@@ -3,18 +4,15 @@
            \\ %E2%8A%98%E2%8A%99
            \\-remove
            \\+add
            \\ %E2%8A%99%E2%8A%98
            \\
        },
    );
}

fn testMakePatch(allocator: Allocator) !void {
    var dmp = DiffMatchPatch{};
    dmp.match_max_bits = 32; // Need this for compat with translated tests
    var null_patch = try dmp.diffAndMakePatch(allocator, "", "");
    defer deinitPatchList(allocator, &null_patch);
    const null_patch_text = try patchToText(allocator, null_patch);
    defer allocator.free(null_patch_text);
    try testing.expectEqualStrings("", null_patch_text);
    const text1 = "The quick brown fox jumps over the lazy dog.";
    const text2 = "That quick brown fox jumped over a lazy dog.";
    { // The second patch must be "-21,17 +21,18", not "-22,17 +21,18" due to rolling context.
        const expectedPatch = "@@ -1,8 +1,7 @@\n Th\n-at\n+e\n  qui\n@@ -21,17 +21,18 @@\n jump\n-ed\n+s\n  over \n-a\n+the\n  laz\n";
        var patches = try dmp.diffAndMakePatch(allocator, text2, text1);
        defer deinitPatchList(allocator, &patches);
        const patch_text = try patchToText(allocator, patches);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expectedPatch, patch_text);
    }
    {
        const expectedPatch = "@@ -1,11 +1,12 @@\n Th\n-e\n+at\n  quick b\n@@ -22,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n  laz\n";
        var patches = try dmp.diffAndMakePatch(allocator, text1, text2);
        defer deinitPatchList(allocator, &patches);
        const patch_text = try patchToText(allocator, patches);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expectedPatch, patch_text);
        var diffs = try dmp.diff(allocator, text1, text2, false);
        defer deinitDiffList(allocator, &diffs);
        var patches2 = try dmp.makePatch(allocator, text1, diffs);
        defer deinitPatchList(allocator, &patches2);
        const patch_text_2 = try patchToText(allocator, patches);
        defer allocator.free(patch_text_2);
        try testing.expectEqualStrings(expectedPatch, patch_text_2);
    }
    const expectedPatch2 = "@@ -1,21 +1,21 @@\n-%601234567890-=%5B%5D%5C;',./\n+~!@#$%25%5E&*()_+%7B%7D%7C:%22%3C%3E?\n";
    {
        var patches = try dmp.diffAndMakePatch(
            allocator,
            "`1234567890-=[]\\;',./",
            "~!@#$%^&*()_+{}|:\"<>?",
        );
        defer deinitPatchList(allocator, &patches);
        const patch_text = try patchToText(allocator, patches);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expectedPatch2, patch_text);
    }
    {
        var diffs = try sliceToDiffList(allocator, &.{
            .{ .operation = .delete, .text = "`1234567890-=[]\\;',./" },
            .{ .operation = .insert, .text = "~!@#$%^&*()_+{}|:\"<>?" },
        });
        defer deinitDiffList(allocator, &diffs);
        var patches = try dmp.makePatchFromDiffs(allocator, diffs);
        defer deinitPatchList(allocator, &patches);
        for (patches.items[0].diffs.items, 0..) |a_diff, idx| {
            try testing.expect(a_diff.eql(diffs.items[idx]));
        }
    }
    {
        const text1a = "abcdef" ** 100;
        const text2a = text1a ++ "123";
        const expected_patch = "@@ -573,28 +573,31 @@\n cdefabcdefabcdefabcdefabcdef\n+123\n";
        var patches = try dmp.diffAndMakePatch(allocator, text1a, text2a);
        defer deinitPatchList(allocator, &patches);
        const patch_text = try patchToText(allocator, patches);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expected_patch, patch_text);
    }
}

test makePatch {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMakePatch,
        .{},
    );
}

fn testPatchSplitMax(allocator: Allocator) !void {
    var dmp = DiffMatchPatch{};
    // TODO get some tests which cover the max split we actually use: bitsize(usize)
    dmp.match_max_bits = 32;
    {
        var patches = try dmp.diffAndMakePatch(
            allocator,
            "abcdefghijklmnopqrstuvwxyz01234567890",
            "XabXcdXefXghXijXklXmnXopXqrXstXuvXwxXyzX01X23X45X67X89X0",
        );
        defer deinitPatchList(allocator, &patches);
        const expected_patch = "@@ -1,32 +1,46 @@\n+X\n ab\n+X\n cd\n+X\n ef\n+X\n gh\n+X\n ij\n+X\n kl\n+X\n mn\n+X\n op\n+X\n qr\n+X\n st\n+X\n uv\n+X\n wx\n+X\n yz\n+X\n 012345\n@@ -25,13 +39,18 @@\n zX01\n+X\n 23\n+X\n 45\n+X\n 67\n+X\n 89\n+X\n 0\n";
        try dmp.patchSplitMax(allocator, &patches);
        const patch_text = try patchToText(allocator, patches);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expected_patch, patch_text);
    }
    {
        var patches = try dmp.diffAndMakePatch(
            allocator,
            "abcdef1234567890123456789012345678901234567890123456789012345678901234567890uvwxyz",
            "abcdefuvwxyz",
        );
        defer deinitPatchList(allocator, &patches);
        const text_before = try patchToText(allocator, patches);
        defer allocator.free(text_before);
        try dmp.patchSplitMax(allocator, &patches);
        const text_after = try patchToText(allocator, patches);
        defer allocator.free(text_after);
        try testing.expectEqualStrings(text_before, text_after);
    }
    {
        var patches = try dmp.diffAndMakePatch(
            allocator,
            "1234567890123456789012345678901234567890123456789012345678901234567890",
            "abc",
        );
        defer deinitPatchList(allocator, &patches);
        const pre_patch_text = try patchToText(allocator, patches);
        defer allocator.free(pre_patch_text);
        try dmp.patchSplitMax(allocator, &patches);
        const patch_text = try patchToText(allocator, patches);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(
            "@@ -1,32 +1,4 @@\n-1234567890123456789012345678\n 9012\n@@ -29,32 +1,4 @@\n-9012345678901234567890123456\n 7890\n@@ -57,14 +1,3 @@\n-78901234567890\n+abc\n",
            patch_text,
        );
    }
    {
        var patches = try dmp.diffAndMakePatch(
            allocator,
            "abcdefghij , h : 0 , t : 1 abcdefghij , h : 0 , t : 1 abcdefghij , h : 0 , t : 1",
            "abcdefghij , h : 1 , t : 1 abcdefghij , h : 1 , t : 1 abcdefghij , h : 0 , t : 1",
        );
        defer deinitPatchList(allocator, &patches);
        try dmp.patchSplitMax(allocator, &patches);
        const patch_text = try patchToText(allocator, patches);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(
            "@@ -2,32 +2,32 @@\n bcdefghij , h : \n-0\n+1\n  , t : 1 abcdef\n@@ -29,32 +29,32 @@\n bcdefghij , h : \n-0\n+1\n  , t : 1 abcdef\n",
            patch_text,
        );
    }
}

test patchSplitMax {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchSplitMax,
        .{},
    );
    try testPatchSplitMax(testing.allocator);
}

fn testPatchAddPadding(
    allocator: Allocator,
    before: []const u8,
    after: []const u8,
    expect_before: []const u8,
    expect_after: []const u8,
) !void {
    const dmp = DiffMatchPatch{};
    var patches = try dmp.diffAndMakePatch(allocator, before, after);
    defer deinitPatchList(allocator, &patches);
    const patch_text_before = try patchToText(allocator, patches);
    defer allocator.free(patch_text_before);
    try testing.expectEqualStrings(expect_before, patch_text_before);
    const codes = try dmp.patchAddPadding(allocator, &patches);
    allocator.free(codes);
    const patch_text_after = try patchToText(allocator, patches);
    defer allocator.free(patch_text_after);
    try testing.expectEqualStrings(expect_after, patch_text_after);
}
test patchAddPadding {
    // Both edges full.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchAddPadding,
        .{
            "",
            "test",
            "@@ -0,0 +1,4 @@\n+test\n",
            "@@ -1,8 +1,12 @@\n %01%02%03%04\n+test\n %01%02%03%04\n",
        },
    );
    // Both edges partial.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchAddPadding,
        .{
            "XY",
            "XtestY",
            "@@ -1,2 +1,6 @@\n X\n+test\n Y\n",
            "@@ -2,8 +2,12 @@\n %02%03%04X\n+test\n Y%01%02%03\n",
        },
    );
    // Both edges none.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchAddPadding,
        .{
            "XXXXYYYY",
            "XXXXtestYYYY",
            "@@ -1,8 +1,12 @@\n XXXX\n+test\n YYYY\n",
            "@@ -5,8 +5,12 @@\n XXXX\n+test\n YYYY\n",
        },
    );
}

fn testPatchApply(
    allocator: Allocator,
    dmp: DiffMatchPatch,
    before: []const u8,
    after: []const u8,
    apply_to: []const u8,
    expect: []const u8,
    all_applied: bool,
) !void {
    var patches = try dmp.diffAndMakePatch(allocator, before, after);
    defer deinitPatchList(allocator, &patches);
    const result, const success = try dmp.patchApply(allocator, &patches, apply_to);
    defer allocator.free(result);
    try testing.expectEqual(all_applied, success);
    try testing.expectEqualStrings(expect, result);
}

test "testPatchApply" {
    // These tests differ from the source, because we just return one
    // bool for if all patches were successfully applied or not.
    var dmp = DiffMatchPatch{};
    dmp.match_distance = 1000;
    dmp.match_threshold = 0.5;
    dmp.patch_delete_threshold = 0.5;
    dmp.match_max_bits = 32; // Necessary to get the correct legacy behavior
    // Null case.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "",
            "",
            "Hello World",
            "Hello World",
            true,
        },
    );
    // Exact match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            true,
        },
    );
    // Partial match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            "The quick red rabbit jumps over the tired tiger.",
            "That quick red rabbit jumped over a tired tiger.",
            true,
        },
    );
    // Failed match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            "I am the very model of a modern major general.",
            "I am the very model of a modern major general.",
            false,
        },
    );
    // Big delete, small change.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "x1234567890123456789012345678901234567890123456789012345678901234567890y",
            "xabcy",
            "x123456789012345678901234567890-----++++++++++-----123456789012345678901234567890y",
            "xabcy",
            true,
        },
    );
    // Big delete, big change 1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "x1234567890123456789012345678901234567890123456789012345678901234567890y",
            "xabcy",
            "x12345678901234567890---------------++++++++++---------------12345678901234567890y",
            "xabc12345678901234567890---------------++++++++++---------------12345678901234567890y",
            false,
        },
    );
    dmp.patch_delete_threshold = 0.6;
    // Big delete, big change 2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "x1234567890123456789012345678901234567890123456789012345678901234567890y",
            "xabcy",
            "x12345678901234567890---------------++++++++++---------------12345678901234567890y",
            "xabcy",
            true,
        },
    );
    dmp.patch_delete_threshold = 0.6;
    dmp.match_threshold = 0.0;
    dmp.match_distance = 0;
    // Compensate for failed patch.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "abcdefghijklmnopqrstuvwxyz--------------------1234567890",
            "abcXXXXXXXXXXdefghijklmnopqrstuvwxyz--------------------1234567YYYYYYYYYY890",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567890",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567YYYYYYYYYY890",
            false,
        },
    );
    dmp.match_threshold = 0.5;
    dmp.match_distance = 1000;
    // Edge exact match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "",
            "test",
            "",
            "test",
            true,
        },
    );
    // Near edge exact match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "XY",
            "XtestY",
            "XY",
            "XtestY",
            true,
        },
    );
    // Edge partial match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            dmp,
            "y",
            "y123",
            "x",
            "x123",
            true,
        },
    );
}

test "patching does not affect patches" {
    const allocator = std.testing.allocator;
    var dmp = DiffMatchPatch{};
    dmp.match_distance = 1000;
    dmp.match_threshold = 0.5;
    dmp.patch_delete_threshold = 0.5;
    dmp.match_max_bits = 32; // Need this so test #2 splits
    var patches1 = try dmp.diffAndMakePatch(allocator, "", "test");
    defer deinitPatchList(allocator, &patches1);
    const patch1_str = try patchToText(allocator, patches1);
    defer allocator.free(patch1_str);
    const result1, _ = try dmp.patchApply(allocator, &patches1, "");
    allocator.free(result1);
    const patch1_str_after = try patchToText(allocator, patches1);
    defer allocator.free(patch1_str_after);
    try testing.expectEqualStrings(patch1_str, patch1_str_after);
    var patches2 = try dmp.diffAndMakePatch(
        allocator,
        "The quick brown fox jumps over the lazy dog.",
        "Woof",
    );
    defer deinitPatchList(allocator, &patches2);
    const patch2_str = try patchToText(allocator, patches2);
    defer allocator.free(patch2_str);
    const result2, _ = try dmp.patchApply(
        allocator,
        &patches2,
        "The quick brown fox jumps over the lazy dog.",
    );
    allocator.free(result2);
    const patch2_str_after = try patchToText(allocator, patches2);
    defer allocator.free(patch2_str_after);
    try testing.expectEqualStrings(patch2_str, patch2_str_after);
}
