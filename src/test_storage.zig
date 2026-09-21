const std = @import("std");
const h = @import("test_helpers.zig");

const storage_mod = h.storage_mod;
const Status = h.Status;
const Issue = h.Issue;
const fixed_timestamp = h.fixed_timestamp;
const makeTestIssue = h.makeTestIssue;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const cleanupTestDirAndFree = h.cleanupTestDirAndFree;
const openTestStorage = h.openTestStorage;

test "storage: dependency cycle rejected" {
    // Test cycle detection at storage level
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    // Create two issues
    const issue_a = makeTestIssue("test-a", .open);
    ts.storage.createIssue(issue_a, null) catch |err| {
        std.debug.panic("create A: {}", .{err});
    };

    const issue_b = makeTestIssue("test-b", .open);
    ts.storage.createIssue(issue_b, null) catch |err| {
        std.debug.panic("create B: {}", .{err});
    };

    // Add A depends on B (A->B)
    ts.storage.addDependency("test-a", "test-b", "blocks") catch |err| {
        std.debug.panic("add A->B: {}", .{err});
    };

    // Try to add B depends on A (B->A) - should fail with DependencyCycle
    const cycle_result = ts.storage.addDependency("test-b", "test-a", "blocks");
    try std.testing.expectError(error.DependencyCycle, cycle_result);
}

test "storage: delete cascade unblocks dependents" {
    // Test that deleting a blocker unblocks its dependents
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    // Create blocker issue
    const blocker = makeTestIssue("blocker", .open);
    ts.storage.createIssue(blocker, null) catch |err| {
        std.debug.panic("create blocker: {}", .{err});
    };

    // Create dependent issue
    const dependent = makeTestIssue("dependent", .open);
    ts.storage.createIssue(dependent, null) catch |err| {
        std.debug.panic("create dependent: {}", .{err});
    };

    // Add dependency: dependent blocked by blocker
    ts.storage.addDependency("dependent", "blocker", "blocks") catch |err| {
        std.debug.panic("add dep: {}", .{err});
    };

    // Verify dependent is NOT ready (blocked)
    const ready1 = ts.storage.getReadyIssues() catch |err| {
        std.debug.panic("ready1: {}", .{err});
    };
    defer storage_mod.freeIssues(allocator, ready1);
    try std.testing.expectEqual(@as(usize, 1), ready1.len); // Only blocker is ready

    // Delete blocker
    ts.storage.deleteIssue("blocker") catch |err| {
        std.debug.panic("delete: {}", .{err});
    };

    // Verify dependent is now ready (unblocked)
    const ready2 = ts.storage.getReadyIssues() catch |err| {
        std.debug.panic("ready2: {}", .{err});
    };
    defer storage_mod.freeIssues(allocator, ready2);
    try std.testing.expectEqual(@as(usize, 1), ready2.len);
    try std.testing.expectEqualStrings("dependent", ready2[0].id);
}

test "storage: delete parent cleans up child dependency refs" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    // Create parent with child
    const parent = makeTestIssue("parent", .open);
    try ts.storage.createIssue(parent, null);

    const child = makeTestIssue("child", .open);
    try ts.storage.createIssue(child, "parent");

    // Create external issue that depends on the child
    const external = makeTestIssue("external", .open);
    try ts.storage.createIssue(external, null);
    try ts.storage.addDependency("external", "child", "blocks");

    // Verify external is blocked
    const ready1 = try ts.storage.getReadyIssues();
    defer storage_mod.freeIssues(allocator, ready1);
    var external_ready = false;
    for (ready1) |r| {
        if (std.mem.eql(u8, r.id, "external")) external_ready = true;
    }
    try std.testing.expect(!external_ready);

    // Delete parent (which deletes child too)
    try ts.storage.deleteIssue("parent");

    // Verify external is now unblocked (child ref was cleaned up)
    const ready2 = try ts.storage.getReadyIssues();
    defer storage_mod.freeIssues(allocator, ready2);
    try std.testing.expectEqual(@as(usize, 1), ready2.len);
    try std.testing.expectEqualStrings("external", ready2[0].id);

    // Verify external's blocks array is now empty
    const ext = try ts.storage.getIssue("external") orelse return error.TestUnexpectedResult;
    defer ext.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), ext.blocks.len);
}

test "storage: ID prefix resolution" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    // Create an issue with a known ID
    const issue = Issue{
        .id = "abc123def456",
        .title = "Test",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .parent = null,
    };
    ts.storage.createIssue(issue, null) catch |err| {
        std.debug.panic("create: {}", .{err});
    };

    // Resolve by prefix
    const resolved = ts.storage.resolveId("abc123") catch |err| {
        std.debug.panic("resolve: {}", .{err});
    };
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("abc123def456", resolved);
}

test "storage: ambiguous ID prefix errors" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    // Create two issues with same prefix
    const issue1 = Issue{
        .id = "abc123111111",
        .title = "Test1",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .parent = null,
    };
    ts.storage.createIssue(issue1, null) catch |err| {
        std.debug.panic("create1: {}", .{err});
    };

    const issue2 = Issue{
        .id = "abc123222222",
        .title = "Test2",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .parent = null,
    };
    ts.storage.createIssue(issue2, null) catch |err| {
        std.debug.panic("create2: {}", .{err});
    };

    // Resolve with ambiguous prefix should error
    const result = ts.storage.resolveId("abc123");
    try std.testing.expectError(error.AmbiguousId, result);
}

test "storage: resolve ignores parent folders without issue file" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const parent = makeTestIssue("parent-aaa", .open);
    ts.storage.createIssue(parent, null) catch |err| {
        std.debug.panic("create parent: {}", .{err});
    };

    const child = makeTestIssue("child-bbb", .open);
    ts.storage.createIssue(child, "parent-aaa") catch |err| {
        std.debug.panic("create child: {}", .{err});
    };

    const grandchild = makeTestIssue("grandchild-ccc", .open);
    ts.storage.createIssue(grandchild, "child-bbb") catch |err| {
        std.debug.panic("create grandchild: {}", .{err});
    };

    const resolved = ts.storage.resolveIdActive("child-bbb") catch |err| {
        std.debug.panic("resolve: {}", .{err});
    };
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("child-bbb", resolved);
}

test "storage: missing required frontmatter fields rejected" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    // Write file with missing title
    const no_title =
        \\---
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: 2024-01-01T00:00:00Z
        \\---
    ;
    try ts.storage.dots_dir.writeFile(std.Options.debug_io, .{ .sub_path = "no-title.md", .data = no_title });

    // Should fail to read
    const result1 = ts.storage.getIssue("no-title");
    try std.testing.expectError(error.InvalidFrontmatter, result1);

    // Write file with missing created-at
    const no_created =
        \\---
        \\title: Has title
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\---
    ;
    try ts.storage.dots_dir.writeFile(std.Options.debug_io, .{ .sub_path = "no-created.md", .data = no_created });

    // Should fail to read
    const result2 = ts.storage.getIssue("no-created");
    try std.testing.expectError(error.InvalidFrontmatter, result2);
}

test "storage: invalid block id rejected" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const bad_blocks =
        \\---
        \\title: Bad blocks
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: 2024-01-01T00:00:00Z
        \\blocks:
        \\  - ../nope
        \\---
    ;
    try ts.storage.dots_dir.writeFile(std.Options.debug_io, .{ .sub_path = "bad-blocks.md", .data = bad_blocks });

    const result = ts.storage.getIssue("bad-blocks");
    try std.testing.expectError(error.InvalidFrontmatter, result);
}

// Quoted scalars must round-trip: the reader strips the quotes the writer adds,
// so a status write never nests another layer (created-at grew one layer per
// write when only the title was unquoted on read).
test "storage: quoted scalars keep one level of quoting across writes" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const issue = Issue{
        .id = "quoted-scalars",
        .title = "Run library task-exit hooks beside TASK:AT-EXIT",
        .description = "desc",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .parent = null,
    };
    ts.storage.createIssue(issue, null) catch |err| {
        std.debug.panic("create: {}", .{err});
    };

    ts.storage.updateStatus("quoted-scalars", .active, null, null) catch |err| {
        std.debug.panic("activate: {}", .{err});
    };
    ts.storage.updateStatus("quoted-scalars", .closed, fixed_timestamp, "done: hooks landed") catch |err| {
        std.debug.panic("close: {}", .{err});
    };

    const content = ts.storage.dots_dir.readFileAlloc(std.Options.debug_io, "archive/quoted-scalars.md", allocator, .limited(64 * 1024)) catch |err| {
        std.debug.panic("read: {}", .{err});
    };
    defer allocator.free(content);

    const expected =
        \\---
        \\title: "Run library task-exit hooks beside TASK:AT-EXIT"
        \\status: closed
        \\priority: 2
        \\issue-type: task
        \\created-at: "2024-01-01T00:00:00.000000+00:00"
        \\closed-at: "2024-01-01T00:00:00.000000+00:00"
        \\close-reason: "done: hooks landed"
        \\---
        \\
        \\desc
        \\
    ;
    try std.testing.expectEqualStrings(expected, content);

    const read_back = ts.storage.getIssue("quoted-scalars") catch |err| {
        std.debug.panic("get: {}", .{err});
    } orelse std.debug.panic("issue missing", .{});
    defer read_back.deinit(allocator);

    try std.testing.expectEqualStrings("Run library task-exit hooks beside TASK:AT-EXIT", read_back.title);
    try std.testing.expectEqualStrings(fixed_timestamp, read_back.created_at);
    try std.testing.expectEqualStrings(fixed_timestamp, read_back.closed_at.?);
    try std.testing.expectEqualStrings("done: hooks landed", read_back.close_reason.?);
}

test "storage: hand-written quoted scalars read back bare" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const quoted =
        \\---
        \\title: "Title with: colon"
        \\status: closed
        \\priority: 2
        \\issue-type: "task"
        \\assignee: "agent: hazel"
        \\created-at: "2024-01-01T00:00:00.000000+00:00"
        \\closed-at: "2024-02-02T00:00:00.000000+00:00"
        \\close-reason: "done: shipped"
        \\---
    ;
    try ts.storage.dots_dir.writeFile(std.Options.debug_io, .{ .sub_path = "quoted.md", .data = quoted });

    const issue = ts.storage.getIssue("quoted") catch |err| {
        std.debug.panic("get: {}", .{err});
    } orelse std.debug.panic("issue missing", .{});
    defer issue.deinit(allocator);

    try std.testing.expectEqualStrings("Title with: colon", issue.title);
    try std.testing.expectEqualStrings("task", issue.issue_type);
    try std.testing.expectEqualStrings("agent: hazel", issue.assignee.?);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.000000+00:00", issue.created_at);
    try std.testing.expectEqualStrings("2024-02-02T00:00:00.000000+00:00", issue.closed_at.?);
    try std.testing.expectEqualStrings("done: shipped", issue.close_reason.?);
}

// A timestamp the old writer nested three times (each layer escaped by the
// writer) reads back bare, and the next write normalizes the file to one layer.
test "storage: nested timestamp reads back bare and normalizes on write" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const nested =
        \\---
        \\title: Nested
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: "\"\\\"2024-01-01T00:00:00.000000+00:00\\\"\""
        \\---
    ;
    try ts.storage.dots_dir.writeFile(std.Options.debug_io, .{ .sub_path = "nested.md", .data = nested });

    const issue = ts.storage.getIssue("nested") catch |err| {
        std.debug.panic("get: {}", .{err});
    } orelse std.debug.panic("issue missing", .{});
    defer issue.deinit(allocator);

    try std.testing.expectEqualStrings("2024-01-01T00:00:00.000000+00:00", issue.created_at);

    ts.storage.updateStatus("nested", .active, null, null) catch |err| {
        std.debug.panic("activate: {}", .{err});
    };

    const content = ts.storage.dots_dir.readFileAlloc(std.Options.debug_io, "nested.md", allocator, .limited(64 * 1024)) catch |err| {
        std.debug.panic("read: {}", .{err});
    };
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\ncreated-at: \"2024-01-01T00:00:00.000000+00:00\"\n") != null);
}

// A title that genuinely holds quotes unwraps exactly once and writes back
// the same bytes; only timestamps unwrap nested layers.
test "storage: quoted title unwraps one level and round-trips" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const quoted_title =
        \\---
        \\title: "\"Quoted\""
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: 2024-01-01T00:00:00.000000+00:00
        \\---
    ;
    try ts.storage.dots_dir.writeFile(std.Options.debug_io, .{ .sub_path = "quoted-title.md", .data = quoted_title });

    const issue = ts.storage.getIssue("quoted-title") catch |err| {
        std.debug.panic("get: {}", .{err});
    } orelse std.debug.panic("issue missing", .{});
    defer issue.deinit(allocator);

    try std.testing.expectEqualStrings("\"Quoted\"", issue.title);

    ts.storage.updateStatus("quoted-title", .active, null, null) catch |err| {
        std.debug.panic("activate: {}", .{err});
    };

    const content = ts.storage.dots_dir.readFileAlloc(std.Options.debug_io, "quoted-title.md", allocator, .limited(64 * 1024)) catch |err| {
        std.debug.panic("read: {}", .{err});
    };
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\ntitle: \"\\\"Quoted\\\"\"\n") != null);
}

test "storage: block ids stay unquoted across status writes" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const blocker = makeTestIssue("blocker-id", .open);
    try ts.storage.createIssue(blocker, null);

    const dependent = makeTestIssue("dependent-id", .open);
    try ts.storage.createIssue(dependent, null);

    try ts.storage.addDependency("dependent-id", "blocker-id", "blocks");
    try ts.storage.updateStatus("dependent-id", .active, null, null);

    const content = ts.storage.dots_dir.readFileAlloc(std.Options.debug_io, "dependent-id.md", allocator, .limited(64 * 1024)) catch |err| {
        std.debug.panic("read: {}", .{err});
    };
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "blocks:\n  - blocker-id\n") != null);

    const issue = ts.storage.getIssue("dependent-id") catch |err| {
        std.debug.panic("get: {}", .{err});
    } orelse std.debug.panic("issue missing", .{});
    defer issue.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), issue.blocks.len);
    try std.testing.expectEqualStrings("blocker-id", issue.blocks[0]);
}
