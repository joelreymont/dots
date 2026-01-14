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
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "no-title.md", .data = no_title });

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
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "no-created.md", .data = no_created });

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
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "bad-blocks.md", .data = bad_blocks });

    const result = ts.storage.getIssue("bad-blocks");
    try std.testing.expectError(error.InvalidFrontmatter, result);
}
