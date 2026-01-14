const std = @import("std");
const h = @import("test_helpers.zig");

const storage_mod = h.storage_mod;
const zc = h.zc;
const Issue = h.Issue;
const fixed_timestamp = h.fixed_timestamp;
const runDot = h.runDot;
const trimNewline = h.trimNewline;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const cleanupTestDirAndFree = h.cleanupTestDirAndFree;
const openTestStorage = h.openTestStorage;

test "cli: peer-index ordering for root issues" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    // Create issues with peer-index in reverse order to verify sorting
    const issue_c = Issue{
        .id = "task-c",
        .title = "Task C",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 2,
    };
    try ts.storage.createIssue(issue_c, null);

    const issue_a = Issue{
        .id = "task-a",
        .title = "Task A",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0,
    };
    try ts.storage.createIssue(issue_a, null);

    const issue_b = Issue{
        .id = "task-b",
        .title = "Task B",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1,
    };
    try ts.storage.createIssue(issue_b, null);

    // Get list and verify order
    const issues = try ts.storage.listIssues(.open);
    defer storage_mod.freeIssues(allocator, issues);
    ts.deinit();

    try std.testing.expectEqual(@as(usize, 3), issues.len);
    try std.testing.expectEqualStrings("task-a", issues[0].id);
    try std.testing.expectEqualStrings("task-b", issues[1].id);
    try std.testing.expectEqualStrings("task-c", issues[2].id);
}

test "cli: peer-index ordering for child issues" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    // Create parent issue
    const parent = Issue{
        .id = "parent",
        .title = "Parent Task",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0.0,
    };
    try ts.storage.createIssue(parent, null);

    // Create child issues with peer-index in reverse order
    const child_c = Issue{
        .id = "child-c",
        .title = "Child C",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 2,
    };
    try ts.storage.createIssue(child_c, "parent");

    const child_a = Issue{
        .id = "child-a",
        .title = "Child A",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0,
    };
    try ts.storage.createIssue(child_a, "parent");

    const child_b = Issue{
        .id = "child-b",
        .title = "Child B",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1,
    };
    try ts.storage.createIssue(child_b, "parent");

    // Get children and verify order
    const children = try ts.storage.getChildren("parent");
    defer storage_mod.freeChildIssues(allocator, children);
    ts.deinit();

    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expectEqualStrings("child-a", children[0].issue.id);
    try std.testing.expectEqualStrings("child-b", children[1].issue.id);
    try std.testing.expectEqualStrings("child-c", children[2].issue.id);
}

test "cli: peer-index collision falls back to priority then created_at" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    // Same peer_index, different priorities - should sort by priority
    const issue_low_pri = Issue{
        .id = "low-pri",
        .title = "Low Priority",
        .description = "",
        .status = .open,
        .priority = 3, // Lower priority (higher number)
        .issue_type = "task",
        .assignee = null,
        .created_at = "2024-01-01T00:00:00.000000+00:00",
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1,
    };
    try ts.storage.createIssue(issue_low_pri, null);

    const issue_high_pri = Issue{
        .id = "high-pri",
        .title = "High Priority",
        .description = "",
        .status = .open,
        .priority = 1, // Higher priority (lower number)
        .issue_type = "task",
        .assignee = null,
        .created_at = "2024-01-02T00:00:00.000000+00:00", // Later creation
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1, // Same peer_index
    };
    try ts.storage.createIssue(issue_high_pri, null);

    // Same peer_index and priority, different created_at - should sort by created_at
    const issue_older = Issue{
        .id = "older",
        .title = "Older",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = "2024-01-01T00:00:00.000000+00:00",
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 2,
    };
    try ts.storage.createIssue(issue_older, null);

    const issue_newer = Issue{
        .id = "newer",
        .title = "Newer",
        .description = "",
        .status = .open,
        .priority = 2, // Same priority
        .issue_type = "task",
        .assignee = null,
        .created_at = "2024-01-02T00:00:00.000000+00:00", // Later
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 2, // Same peer_index
    };
    try ts.storage.createIssue(issue_newer, null);

    // Get list and verify order
    const issues = try ts.storage.listIssues(.open);
    defer storage_mod.freeIssues(allocator, issues);
    ts.deinit();

    try std.testing.expectEqual(@as(usize, 4), issues.len);
    // peer_index 1: high-pri before low-pri (by priority)
    try std.testing.expectEqualStrings("high-pri", issues[0].id);
    try std.testing.expectEqualStrings("low-pri", issues[1].id);
    // peer_index 2: older before newer (by created_at)
    try std.testing.expectEqualStrings("older", issues[2].id);
    try std.testing.expectEqualStrings("newer", issues[3].id);
}

test "cli: peer-index determines sort order regardless of priority" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    // Issue without peer_index but high priority
    const no_index_high = Issue{
        .id = "no-index-high",
        .title = "No Index High Pri",
        .description = "",
        .status = .open,
        .priority = 0, // Highest priority
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 200.0, // High peer_index (sorts after others)
    };
    try ts.storage.createIssue(no_index_high, null);

    // Issue with peer_index but low priority
    const with_index_low = Issue{
        .id = "with-index-low",
        .title = "With Index Low Pri",
        .description = "",
        .status = .open,
        .priority = 4, // Lowest priority
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 100, // Has peer_index
    };
    try ts.storage.createIssue(with_index_low, null);

    // Another with high peer_index
    const no_index_low = Issue{
        .id = "high-index-low",
        .title = "High Index Low Pri",
        .description = "",
        .status = .open,
        .priority = 4,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 201.0, // Higher than no_index_high
    };
    try ts.storage.createIssue(no_index_low, null);

    const issues = try ts.storage.listIssues(.open);
    defer storage_mod.freeIssues(allocator, issues);
    ts.deinit();

    try std.testing.expectEqual(@as(usize, 3), issues.len);
    // Sorted by peer_index: 100 < 200 < 201
    try std.testing.expectEqualStrings("with-index-low", issues[0].id); // peer_index 100
    try std.testing.expectEqualStrings("no-index-high", issues[1].id); // peer_index 200
    try std.testing.expectEqualStrings("high-index-low", issues[2].id); // peer_index 201
}

test "cli: --after positions new task between existing tasks" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    // Initialize
    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add first task
    const add1 = runDot(allocator, &.{ "add", "Task A" }, test_dir) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);
    const id_a = trimNewline(add1.stdout);

    // Add second task (appends after first)
    const add2 = runDot(allocator, &.{ "add", "Task C" }, test_dir) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);

    // Add third task positioned after first (between A and C)
    const add3 = runDot(allocator, &.{ "add", "Task B", "--after", id_a }, test_dir) catch |err| {
        std.debug.panic("add3: {}", .{err});
    };
    defer add3.deinit(allocator);

    // List and verify order is A, B, C
    const list = runDot(allocator, &.{"list"}, test_dir) catch |err| {
        std.debug.panic("list: {}", .{err});
    };
    defer list.deinit(allocator);

    // Check that B appears between A and C in the output
    const pos_a = std.mem.indexOf(u8, list.stdout, "Task A");
    const pos_b = std.mem.indexOf(u8, list.stdout, "Task B");
    const pos_c = std.mem.indexOf(u8, list.stdout, "Task C");

    try std.testing.expect(pos_a != null);
    try std.testing.expect(pos_b != null);
    try std.testing.expect(pos_c != null);
    try std.testing.expect(pos_a.? < pos_b.?);
    try std.testing.expect(pos_b.? < pos_c.?);
}

test "cli: --before positions new task before existing task" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    // Initialize
    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add first task
    const add1 = runDot(allocator, &.{ "add", "Task B" }, test_dir) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);
    const id_b = trimNewline(add1.stdout);

    // Add second task positioned before first
    const add2 = runDot(allocator, &.{ "add", "Task A", "--before", id_b }, test_dir) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);

    // List and verify order is A, B
    const list = runDot(allocator, &.{"list"}, test_dir) catch |err| {
        std.debug.panic("list: {}", .{err});
    };
    defer list.deinit(allocator);

    const pos_a = std.mem.indexOf(u8, list.stdout, "Task A");
    const pos_b = std.mem.indexOf(u8, list.stdout, "Task B");

    try std.testing.expect(pos_a != null);
    try std.testing.expect(pos_b != null);
    try std.testing.expect(pos_a.? < pos_b.?);
}

test "cli: --after infers parent from target issue" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    // Create parent issue
    const parent = Issue{
        .id = "parent",
        .title = "Parent Task",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0.0,
    };
    try ts.storage.createIssue(parent, null);

    // Create first child
    const child1 = Issue{
        .id = "child-a",
        .title = "Child A",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0.0,
    };
    try ts.storage.createIssue(child1, "parent");
    ts.deinit();

    // Add new child using --after (should infer parent)
    const add = runDot(allocator, &.{ "add", "Child B", "--after", "child-a" }, test_dir) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    // Verify new child is under parent
    var ts2 = openTestStorage(allocator, test_dir);
    defer ts2.deinit();

    const children = try ts2.storage.getChildren("parent");
    defer storage_mod.freeChildIssues(allocator, children);

    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings("child-a", children[0].issue.id);
    try std.testing.expectEqualStrings("Child B", children[1].issue.title);
}

test "cli: new tasks always get a peer-index" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    // Initialize
    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add several tasks via CLI
    const add1 = runDot(allocator, &.{ "add", "First task" }, test_dir) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);
    const id1 = trimNewline(add1.stdout);

    const add2 = runDot(allocator, &.{ "add", "Second task" }, test_dir) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);
    const id2 = trimNewline(add2.stdout);

    const add3 = runDot(allocator, &.{ "add", "Third task" }, test_dir) catch |err| {
        std.debug.panic("add3: {}", .{err});
    };
    defer add3.deinit(allocator);
    const id3 = trimNewline(add3.stdout);

    // Open storage and verify all tasks have peer_index set
    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const issue1 = try ts.storage.getIssue(id1) orelse return error.IssueNotFound;
    defer issue1.deinit(allocator);
    const issue2 = try ts.storage.getIssue(id2) orelse return error.IssueNotFound;
    defer issue2.deinit(allocator);
    const issue3 = try ts.storage.getIssue(id3) orelse return error.IssueNotFound;
    defer issue3.deinit(allocator);

    // All should have peer_index values, and they should be in ascending order
    try std.testing.expect(issue1.peer_index < issue2.peer_index);
    try std.testing.expect(issue2.peer_index < issue3.peer_index);
}

test "cli: first task gets peer-index 0" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add first task to empty list
    const add = runDot(allocator, &.{ "add", "First task" }, test_dir) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);
    const id = trimNewline(add.stdout);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const issue = try ts.storage.getIssue(id) orelse return error.IssueNotFound;
    defer issue.deinit(allocator);

    // First task in empty list should get peer_index 0
    try std.testing.expectEqual(@as(f64, 0.0), issue.peer_index);
}

test "cli: --after last task appends at end" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add two tasks
    const add1 = runDot(allocator, &.{ "add", "Task A" }, test_dir) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);

    const add2 = runDot(allocator, &.{ "add", "Task B" }, test_dir) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);
    const id_b = trimNewline(add2.stdout);

    // Add task after the last one (B)
    const add3 = runDot(allocator, &.{ "add", "Task C", "--after", id_b }, test_dir) catch |err| {
        std.debug.panic("add3: {}", .{err});
    };
    defer add3.deinit(allocator);
    const id_c = trimNewline(add3.stdout);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const issue_b = try ts.storage.getIssue(id_b) orelse return error.IssueNotFound;
    defer issue_b.deinit(allocator);
    const issue_c = try ts.storage.getIssue(id_c) orelse return error.IssueNotFound;
    defer issue_c.deinit(allocator);

    // C should have peer_index = B + 1
    try std.testing.expectEqual(issue_b.peer_index + 1.0, issue_c.peer_index);
}

test "cli: --before first task prepends at start" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add first task
    const add1 = runDot(allocator, &.{ "add", "Task B" }, test_dir) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);
    const id_b = trimNewline(add1.stdout);

    // Add task before the first one (B)
    const add2 = runDot(allocator, &.{ "add", "Task A", "--before", id_b }, test_dir) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);
    const id_a = trimNewline(add2.stdout);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const issue_a = try ts.storage.getIssue(id_a) orelse return error.IssueNotFound;
    defer issue_a.deinit(allocator);
    const issue_b = try ts.storage.getIssue(id_b) orelse return error.IssueNotFound;
    defer issue_b.deinit(allocator);

    // A should have peer_index = B - 1
    try std.testing.expectEqual(issue_b.peer_index - 1.0, issue_a.peer_index);
}

test "prop: peer-index ordering invariants" {
    const PeerIndexCase = struct {
        peer_indices: [6]u4, // 0-15
        priorities: [6]u3, // 0-7
    };

    try zc.check(struct {
        fn property(args: PeerIndexCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            // Create issues with random peer_indices and priorities
            for (0..6) |i| {
                var id_buf: [16]u8 = undefined;
                const id = std.fmt.bufPrint(&id_buf, "idx-{d}", .{i}) catch return false;

                var ts_buf: [32]u8 = undefined;
                const created_at = std.fmt.bufPrint(&ts_buf, "2024-01-0{d}T00:00:00.000000+00:00", .{i + 1}) catch return false;

                const issue = Issue{
                    .id = id,
                    .title = id,
                    .description = "",
                    .status = .open,
                    .priority = args.priorities[i] % 5,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = created_at,
                    .closed_at = null,
                    .close_reason = null,
                    .blocks = &.{},
                    .peer_index = @as(f64, @floatFromInt(args.peer_indices[i])),
                };
                ts.storage.createIssue(issue, null) catch return false;
            }

            const issues = ts.storage.listIssues(.open) catch return false;
            defer storage_mod.freeIssues(allocator, issues);

            // Verify ordering invariants
            for (0..issues.len) |i| {
                if (i == 0) continue;
                const prev = issues[i - 1];
                const curr = issues[i];

                // Invariant 1: peer_index ordering (ascending)
                if (prev.peer_index > curr.peer_index) return false;

                // Invariant 2: when peer_index is equal, check priority
                if (prev.peer_index == curr.peer_index) {
                    if (prev.priority > curr.priority) return false;

                    // Invariant 3: when both equal, check created_at
                    if (prev.priority == curr.priority) {
                        if (std.mem.order(u8, prev.created_at, curr.created_at) == .gt) return false;
                    }
                }
            }

            return true;
        }
    }.property, .{ .iterations = 50, .seed = 0xBEEF });
}

test "cli: multiple sequential insertions at same position" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add first two tasks: A and Z
    const add_a = runDot(allocator, &.{ "add", "Task A" }, test_dir) catch |err| {
        std.debug.panic("add_a: {}", .{err});
    };
    defer add_a.deinit(allocator);
    const id_a = trimNewline(add_a.stdout);

    const add_z = runDot(allocator, &.{ "add", "Task Z" }, test_dir) catch |err| {
        std.debug.panic("add_z: {}", .{err});
    };
    defer add_z.deinit(allocator);

    // Insert B, C, D, E all after A (each bisects remaining space)
    const add_b = runDot(allocator, &.{ "add", "Task B", "--after", id_a }, test_dir) catch |err| {
        std.debug.panic("add_b: {}", .{err});
    };
    defer add_b.deinit(allocator);
    const id_b = trimNewline(add_b.stdout);

    const add_c = runDot(allocator, &.{ "add", "Task C", "--after", id_b }, test_dir) catch |err| {
        std.debug.panic("add_c: {}", .{err});
    };
    defer add_c.deinit(allocator);
    const id_c = trimNewline(add_c.stdout);

    const add_d = runDot(allocator, &.{ "add", "Task D", "--after", id_c }, test_dir) catch |err| {
        std.debug.panic("add_d: {}", .{err});
    };
    defer add_d.deinit(allocator);
    const id_d = trimNewline(add_d.stdout);

    const add_e = runDot(allocator, &.{ "add", "Task E", "--after", id_d }, test_dir) catch |err| {
        std.debug.panic("add_e: {}", .{err});
    };
    defer add_e.deinit(allocator);

    // Verify all tasks appear in correct order: A, B, C, D, E, Z
    const list = runDot(allocator, &.{"list"}, test_dir) catch |err| {
        std.debug.panic("list: {}", .{err});
    };
    defer list.deinit(allocator);

    const pos_a = std.mem.indexOf(u8, list.stdout, "Task A");
    const pos_b = std.mem.indexOf(u8, list.stdout, "Task B");
    const pos_c = std.mem.indexOf(u8, list.stdout, "Task C");
    const pos_d = std.mem.indexOf(u8, list.stdout, "Task D");
    const pos_e = std.mem.indexOf(u8, list.stdout, "Task E");
    const pos_z = std.mem.indexOf(u8, list.stdout, "Task Z");

    try std.testing.expect(pos_a != null);
    try std.testing.expect(pos_b != null);
    try std.testing.expect(pos_c != null);
    try std.testing.expect(pos_d != null);
    try std.testing.expect(pos_e != null);
    try std.testing.expect(pos_z != null);

    try std.testing.expect(pos_a.? < pos_b.?);
    try std.testing.expect(pos_b.? < pos_c.?);
    try std.testing.expect(pos_c.? < pos_d.?);
    try std.testing.expect(pos_d.? < pos_e.?);
    try std.testing.expect(pos_e.? < pos_z.?);
}

test "storage: bisection with close float values maintains uniqueness" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    // Create two issues with very close peer_index values
    const issue_a = Issue{
        .id = "task-a",
        .title = "Task A",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1.0,
    };
    try ts.storage.createIssue(issue_a, null);

    const issue_b = Issue{
        .id = "task-b",
        .title = "Task B",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1.0000001, // Very close to A
    };
    try ts.storage.createIssue(issue_b, null);

    // Calculate peer_index between A and B
    const between_index = try ts.storage.calculatePeerIndex(null, "task-a", null);

    // Verify it's strictly between A and B (the key invariant)
    try std.testing.expect(between_index > 1.0);
    try std.testing.expect(between_index < 1.0000001);

    // Verify it's approximately the midpoint (allowing for floating point precision)
    const expected_midpoint = (1.0 + 1.0000001) / 2.0;
    try std.testing.expectApproxEqAbs(expected_midpoint, between_index, 1e-15);
}

test "cli: tree output maintains peer-index order in nested hierarchy" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    // Create parent issues with specific peer_index ordering
    const parent_b = Issue{
        .id = "parent-b",
        .title = "Parent B",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1.0, // Second
    };
    try ts.storage.createIssue(parent_b, null);

    const parent_a = Issue{
        .id = "parent-a",
        .title = "Parent A",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0.0, // First
    };
    try ts.storage.createIssue(parent_a, null);

    // Create children under parent-a with reverse peer_index order
    const child_a2 = Issue{
        .id = "child-a2",
        .title = "Child A2",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1.0, // Second child
    };
    try ts.storage.createIssue(child_a2, "parent-a");

    const child_a1 = Issue{
        .id = "child-a1",
        .title = "Child A1",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0.0, // First child
    };
    try ts.storage.createIssue(child_a1, "parent-a");

    // Create children under parent-b
    const child_b1 = Issue{
        .id = "child-b1",
        .title = "Child B1",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0.0,
    };
    try ts.storage.createIssue(child_b1, "parent-b");

    ts.deinit();

    // Run tree command and verify order
    const tree = runDot(allocator, &.{"tree"}, test_dir) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer tree.deinit(allocator);

    // Verify parent order: A before B
    const pos_parent_a = std.mem.indexOf(u8, tree.stdout, "Parent A");
    const pos_parent_b = std.mem.indexOf(u8, tree.stdout, "Parent B");
    try std.testing.expect(pos_parent_a != null);
    try std.testing.expect(pos_parent_b != null);
    try std.testing.expect(pos_parent_a.? < pos_parent_b.?);

    // Verify child order under parent A: A1 before A2
    const pos_child_a1 = std.mem.indexOf(u8, tree.stdout, "Child A1");
    const pos_child_a2 = std.mem.indexOf(u8, tree.stdout, "Child A2");
    try std.testing.expect(pos_child_a1 != null);
    try std.testing.expect(pos_child_a2 != null);
    try std.testing.expect(pos_child_a1.? < pos_child_a2.?);

    // Verify A's children appear before B and its children
    const pos_child_b1 = std.mem.indexOf(u8, tree.stdout, "Child B1");
    try std.testing.expect(pos_child_b1 != null);
    try std.testing.expect(pos_child_a2.? < pos_parent_b.?);
    try std.testing.expect(pos_parent_b.? < pos_child_b1.?);
}

test "cli: --before infers parent from target issue" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    // Create parent issue
    const parent = Issue{
        .id = "parent",
        .title = "Parent Task",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 0.0,
    };
    try ts.storage.createIssue(parent, null);

    // Create first child
    const child1 = Issue{
        .id = "child-b",
        .title = "Child B",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .peer_index = 1.0,
    };
    try ts.storage.createIssue(child1, "parent");
    ts.deinit();

    // Add new child using --before (should infer parent)
    const add = runDot(allocator, &.{ "add", "Child A", "--before", "child-b" }, test_dir) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    // Verify new child is under parent
    var ts2 = openTestStorage(allocator, test_dir);
    defer ts2.deinit();

    const children = try ts2.storage.getChildren("parent");
    defer storage_mod.freeChildIssues(allocator, children);

    try std.testing.expectEqual(@as(usize, 2), children.len);
    // Children should be ordered by peer_index: A (0.0) before B (1.0)
    try std.testing.expectEqualStrings("Child A", children[0].issue.title);
    try std.testing.expectEqualStrings("child-b", children[1].issue.id);
}

test "prop: repeated bisection produces unique indices" {
    const BisectionCase = struct {
        insertions: [8]u3, // 0-7 indicates "insert after position N" in current list
    };

    try zc.check(struct {
        fn property(args: BisectionCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            // Initialize
            const init = runDot(allocator, &.{"init"}, test_dir) catch return false;
            init.deinit(allocator);

            // Add first task
            const add_first = runDot(allocator, &.{ "add", "Task-0" }, test_dir) catch return false;
            add_first.deinit(allocator);

            // Track task IDs in insertion order
            var task_ids: [9][64]u8 = undefined;
            var task_id_lens: [9]usize = undefined;

            // Get first task ID
            var ts = openTestStorage(allocator, test_dir);
            const first_issues = ts.storage.listIssues(.open) catch {
                ts.deinit();
                return false;
            };
            if (first_issues.len != 1) {
                storage_mod.freeIssues(allocator, first_issues);
                ts.deinit();
                return false;
            }
            const first_id = first_issues[0].id;
            @memcpy(task_ids[0][0..first_id.len], first_id);
            task_id_lens[0] = first_id.len;
            storage_mod.freeIssues(allocator, first_issues);
            ts.deinit();

            var num_tasks: usize = 1;

            // Perform insertions
            for (args.insertions) |insert_pos| {
                // Insert after position (mod current list size)
                const pos = insert_pos % @as(u3, @intCast(@min(7, num_tasks)));
                const after_id = task_ids[pos][0..task_id_lens[pos]];

                var title_buf: [16]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "Task-{d}", .{num_tasks}) catch return false;

                const add = runDot(allocator, &.{ "add", title, "--after", after_id }, test_dir) catch return false;
                defer add.deinit(allocator);

                const new_id = trimNewline(add.stdout);
                @memcpy(task_ids[num_tasks][0..new_id.len], new_id);
                task_id_lens[num_tasks] = new_id.len;
                num_tasks += 1;
            }

            // Verify all peer_indices are unique
            var ts2 = openTestStorage(allocator, test_dir);
            defer ts2.deinit();

            const issues = ts2.storage.listIssues(.open) catch return false;
            defer storage_mod.freeIssues(allocator, issues);

            // Check for duplicates
            for (0..issues.len) |i| {
                for (i + 1..issues.len) |j| {
                    if (issues[i].peer_index == issues[j].peer_index) {
                        return false; // Duplicate found!
                    }
                }
            }

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0xCAFE });
}
