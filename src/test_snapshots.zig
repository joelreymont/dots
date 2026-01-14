const std = @import("std");
const fs = std.fs;
const h = @import("test_helpers.zig");

const OhSnap = h.OhSnap;
const runDot = h.runDot;
const trimNewline = h.trimNewline;
const normalizeTreeOutput = h.normalizeTreeOutput;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const cleanupTestDirAndFree = h.cleanupTestDirAndFree;

test "snap: simple struct" {
    // Test basic ohsnap functionality with a simple struct
    const TestStruct = struct {
        name: []const u8,
        value: i32,
    };
    const data = TestStruct{ .name = "test", .value = 42 };
    const oh = OhSnap{};
    try oh.snap(
        @src(),
        \\test_snapshots.test.snap: simple struct.TestStruct
        \\  .name: []const u8
        \\    "test"
        \\  .value: i32 = 42
        ,
    ).expectEqual(data);
}

test "snap: markdown frontmatter format" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add a task with specific parameters
    const add = runDot(allocator, &.{
        "add", "Test snapshot task",
        "-p",  "1",
        "-d",  "This is a description",
    }, test_dir) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    const id = trimNewline(add.stdout);

    // Read the markdown file
    const md_path = std.fmt.allocPrint(allocator, "{s}/.dots/{s}.md", .{ test_dir, id }) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(md_path);

    const content = fs.cwd().readFileAlloc(allocator, md_path, 64 * 1024) catch |err| {
        std.debug.panic("read: {}", .{err});
    };
    defer allocator.free(content);

    // Normalize: replace dynamic ID and timestamp with placeholders
    var normalized = std.ArrayList(u8){};
    defer normalized.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try normalized.append(allocator, '\n');
        first = false;

        if (std.mem.startsWith(u8, line, "created-at:")) {
            try normalized.appendSlice(allocator, "created-at: <TIMESTAMP>");
        } else {
            try normalized.appendSlice(allocator, line);
        }
    }

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "---
        \\title: Test snapshot task
        \\status: open
        \\priority: 1
        \\issue-type: task
        \\created-at: <TIMESTAMP>
        \\---
        \\
        \\This is a description
        \\"
    ).expectEqual(normalized.items);
}

test "snap: json output format" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add tasks
    const add1 = runDot(allocator, &.{ "add", "First task", "-p", "0" }, test_dir) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);
    const add2 = runDot(allocator, &.{ "add", "Second task", "-p", "2" }, test_dir) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);

    // Get JSON output
    const ls = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
        std.debug.panic("ls: {}", .{err});
    };
    defer ls.deinit(allocator);

    // Parse and re-serialize with stable ordering for snapshot
    const JsonIssueSnap = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        priority: i64,
    };

    const parsed = std.json.parseFromSlice([]JsonIssueSnap, allocator, ls.stdout, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.panic("parse: {}", .{err});
    };
    defer parsed.deinit();

    // Sort by priority for stable output
    std.mem.sort(JsonIssueSnap, parsed.value, {}, struct {
        fn lessThan(_: void, a: JsonIssueSnap, b: JsonIssueSnap) bool {
            return a.priority < b.priority;
        }
    }.lessThan);

    // Build normalized output (just titles and priorities)
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    for (parsed.value) |issue| {
        const line = std.fmt.allocPrint(allocator, "{s} (p{d})\n", .{ issue.title, issue.priority }) catch |err| {
            std.debug.panic("fmt: {}", .{err});
        };
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "First task (p0)
        \\Second task (p2)
        \\"
    ).expectEqual(output.items);
}

test "snap: tree output format" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add parent
    const parent = runDot(allocator, &.{ "add", "Parent task" }, test_dir) catch |err| {
        std.debug.panic("add parent: {}", .{err});
    };
    defer parent.deinit(allocator);

    const parent_id = trimNewline(parent.stdout);

    // Add children
    const child1 = runDot(allocator, &.{ "add", "Child one", "-P", parent_id }, test_dir) catch |err| {
        std.debug.panic("add child1: {}", .{err});
    };
    defer child1.deinit(allocator);
    const child1_id = trimNewline(child1.stdout);

    const child2 = runDot(allocator, &.{ "add", "Child two", "-P", parent_id, "-a", child1_id }, test_dir) catch |err| {
        std.debug.panic("add child2: {}", .{err});
    };
    defer child2.deinit(allocator);

    // Get tree output
    const tree = runDot(allocator, &.{"tree"}, test_dir) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer tree.deinit(allocator);

    const normalized = try normalizeTreeOutput(allocator, tree.stdout);
    defer allocator.free(normalized);

    const oh = OhSnap{};
    // Tree shows parent with children indented
    try oh.snap(@src(),
        \\[]u8
        \\  "[ID] ○ Parent task
        \\  └─ [ID] ○ Child one
        \\  └─ [ID] ○ Child two (blocked)
        \\"
    ).expectEqual(normalized);
}
