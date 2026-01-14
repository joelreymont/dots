const std = @import("std");
const h = @import("test_helpers.zig");

const storage_mod = h.storage_mod;
const zc = h.zc;
const Status = h.Status;
const Issue = h.Issue;
const LifecycleOracle = h.LifecycleOracle;
const OpType = h.OpType;
const JsonIssue = h.JsonIssue;
const fixed_timestamp = h.fixed_timestamp;
const makeTestIssue = h.makeTestIssue;
const runDot = h.runDot;
const isExitCode = h.isExitCode;
const trimNewline = h.trimNewline;
const oracleReady = h.oracleReady;
const oracleListCount = h.oracleListCount;
const oracleChildBlocked = h.oracleChildBlocked;
const oracleUpdateClosed = h.oracleUpdateClosed;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const cleanupTestDirAndFree = h.cleanupTestDirAndFree;
const openTestStorage = h.openTestStorage;

test "prop: ready issues match oracle" {
    const ReadyCase = struct {
        statuses: [4]Status,
        deps: [4][4]bool,
    };

    try zc.check(struct {
        fn property(args: ReadyCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            var id_bufs: [4][16]u8 = undefined;
            var ids: [4][]const u8 = undefined;

            for (0..4) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "t{d}", .{i}) catch |err| {
                    std.debug.panic("id format: {}", .{err});
                };

                const issue = makeTestIssue(ids[i], args.statuses[i]);
                ts.storage.createIssue(issue, null) catch |err| {
                    std.debug.panic("create issue: {}", .{err});
                };
            }

            for (0..4) |i| {
                for (0..4) |j| {
                    if (args.deps[i][j]) {
                        ts.storage.addDependency(ids[i], ids[j], "blocks") catch |err| switch (err) {
                            error.DependencyCycle => {}, // Skip cycles
                            else => std.debug.panic("add dependency: {}", .{err}),
                        };
                    }
                }
            }

            const issues = ts.storage.getReadyIssues() catch |err| {
                std.debug.panic("get ready: {}", .{err});
            };
            defer storage_mod.freeIssues(allocator, issues);

            const expected = oracleReady(args.statuses, args.deps);
            var found = [_]bool{ false, false, false, false };

            for (issues) |issue| {
                var matched = false;
                for (0..4) |i| {
                    if (std.mem.eql(u8, issue.id, ids[i])) {
                        matched = true;
                        found[i] = true;
                        break;
                    }
                }
                if (!matched) return false;
            }

            for (0..4) |i| {
                if (expected[i] != found[i]) return false;
            }

            return true;
        }
    }.property, .{ .iterations = 40, .seed = 0xD07D07 });
}

test "prop: listIssues filter matches oracle" {
    const ListCase = struct {
        statuses: [6]Status,
    };

    try zc.check(struct {
        fn property(args: ListCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            var id_bufs: [6][16]u8 = undefined;
            var ids: [6][]const u8 = undefined;

            for (0..6) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "i{d}", .{i}) catch |err| {
                    std.debug.panic("id format: {}", .{err});
                };

                const issue = makeTestIssue(ids[i], args.statuses[i]);
                ts.storage.createIssue(issue, null) catch |err| {
                    std.debug.panic("create issue: {}", .{err});
                };
            }

            const filters = [_]Status{ .open, .active, .closed };
            for (filters) |filter| {
                const issues = ts.storage.listIssues(filter) catch |err| {
                    std.debug.panic("list issues: {}", .{err});
                };
                defer storage_mod.freeIssues(allocator, issues);

                const expected_count = oracleListCount(args.statuses, filter);
                if (issues.len != expected_count) return false;

                for (issues) |issue| {
                    if (issue.status != filter) return false;
                }
            }

            return true;
        }
    }.property, .{ .iterations = 40, .seed = 0xC0FFEE });
}

test "prop: tree children blocked flag matches oracle" {
    const TreeCase = struct {
        child_statuses: [3]Status,
        blocker_statuses: [3]Status,
        child_blocks: [3][3]bool,
    };

    try zc.check(struct {
        fn property(args: TreeCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            var parent_buf: [16]u8 = undefined;
            const parent_id = std.fmt.bufPrint(&parent_buf, "parent", .{}) catch |err| {
                std.debug.panic("parent id: {}", .{err});
            };

            const parent_issue = makeTestIssue(parent_id, .open);
            ts.storage.createIssue(parent_issue, null) catch |err| {
                std.debug.panic("create parent: {}", .{err});
            };

            var child_bufs: [3][16]u8 = undefined;
            var child_ids: [3][]const u8 = undefined;
            for (0..3) |i| {
                child_ids[i] = std.fmt.bufPrint(&child_bufs[i], "c{d}", .{i}) catch |err| {
                    std.debug.panic("child id: {}", .{err});
                };

                const issue = makeTestIssue(child_ids[i], args.child_statuses[i]);
                ts.storage.createIssue(issue, parent_id) catch |err| {
                    std.debug.panic("create child: {}", .{err});
                };
            }

            var blocker_bufs: [3][16]u8 = undefined;
            var blocker_ids: [3][]const u8 = undefined;
            for (0..3) |i| {
                blocker_ids[i] = std.fmt.bufPrint(&blocker_bufs[i], "b{d}", .{i}) catch |err| {
                    std.debug.panic("blocker id: {}", .{err});
                };

                const issue = makeTestIssue(blocker_ids[i], args.blocker_statuses[i]);
                ts.storage.createIssue(issue, null) catch |err| {
                    std.debug.panic("create blocker: {}", .{err});
                };
            }

            for (0..3) |i| {
                for (0..3) |j| {
                    if (args.child_blocks[i][j]) {
                        ts.storage.addDependency(child_ids[i], blocker_ids[j], "blocks") catch |err| {
                            std.debug.panic("add block dep: {}", .{err});
                        };
                    }
                }
            }

            const children = ts.storage.getChildren(parent_id) catch |err| {
                std.debug.panic("get children: {}", .{err});
            };
            defer storage_mod.freeChildIssues(allocator, children);

            if (children.len != 3) return false;

            const expected = oracleChildBlocked(args.child_blocks, args.blocker_statuses);
            var seen = [_]bool{ false, false, false };

            for (children) |child| {
                var matched = false;
                for (0..3) |i| {
                    if (std.mem.eql(u8, child.issue.id, child_ids[i])) {
                        matched = true;
                        seen[i] = true;
                        if (child.blocked != expected[i]) return false;
                        break;
                    }
                }
                if (!matched) return false;
            }

            for (seen) |was_seen| {
                if (!was_seen) return false;
            }

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0xB10C });
}

test "prop: update done sets closed_at" {
    const UpdateCase = struct {
        done: bool,
    };

    try zc.check(struct {
        fn property(args: UpdateCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };
            defer init.deinit(allocator);

            const add = runDot(allocator, &.{ "add", "Update done test" }, test_dir) catch |err| {
                std.debug.panic("add: {}", .{err});
            };
            defer add.deinit(allocator);

            const id = trimNewline(add.stdout);
            if (id.len == 0) return false;

            const status = if (args.done) "done" else "open";
            const update = runDot(allocator, &.{ "update", id, "--status", status }, test_dir) catch |err| {
                std.debug.panic("update: {}", .{err});
            };
            defer update.deinit(allocator);
            if (!isExitCode(update.term, 0)) return false;

            const show = runDot(allocator, &.{ "show", id }, test_dir) catch |err| {
                std.debug.panic("show: {}", .{err});
            };
            defer show.deinit(allocator);
            if (!isExitCode(show.term, 0)) return false;

            const expects_closed = oracleUpdateClosed(args.done);
            if (expects_closed) {
                if (std.mem.indexOf(u8, show.stdout, "Closed:") == null) return false;
                if (std.mem.indexOf(u8, show.stdout, "Status:   done") == null) return false;
            } else {
                if (std.mem.indexOf(u8, show.stdout, "Closed:") != null) return false;
                if (std.mem.indexOf(u8, show.stdout, "Status:   open") == null) return false;
            }

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0xD0DE });
}

test "prop: unknown id errors" {
    const UnknownCase = struct {
        raw: [8]u8,
    };

    try zc.check(struct {
        fn property(args: UnknownCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };
            defer init.deinit(allocator);

            var id_buf: [8]u8 = undefined;
            for (args.raw, 0..) |byte, i| {
                id_buf[i] = @as(u8, 'a') + (byte % 26);
            }
            const id = id_buf[0..];

            const on_result = runDot(allocator, &.{ "on", id }, test_dir) catch |err| {
                std.debug.panic("on: {}", .{err});
            };
            defer on_result.deinit(allocator);
            if (!isExitCode(on_result.term, 1)) return false;
            if (std.mem.indexOf(u8, on_result.stderr, "Issue not found") == null) return false;

            const rm_result = runDot(allocator, &.{ "rm", id }, test_dir) catch |err| {
                std.debug.panic("rm: {}", .{err});
            };
            defer rm_result.deinit(allocator);
            if (!isExitCode(rm_result.term, 1)) return false;
            if (std.mem.indexOf(u8, rm_result.stderr, "Issue not found") == null) return false;

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0xBAD1D });
}

test "prop: invalid dependency rejected" {
    const DepCase = struct {
        raw: [8]u8,
        use_parent: bool,
    };

    try zc.check(struct {
        fn property(args: DepCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };
            defer init.deinit(allocator);

            // Generate random non-existent ID
            var id_buf: [8]u8 = undefined;
            for (args.raw, 0..) |byte, i| {
                id_buf[i] = @as(u8, 'a') + (byte % 26);
            }
            const fake_id = id_buf[0..];

            // Try to create with invalid dependency
            const flag: []const u8 = if (args.use_parent) "-P" else "-a";
            const result = runDot(allocator, &.{ "add", "Test task", flag, fake_id }, test_dir) catch |err| {
                std.debug.panic("add: {}", .{err});
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            // Should fail with appropriate error
            if (!isExitCode(result.term, 1)) return false;
            if (std.mem.indexOf(u8, result.stderr, "not found") == null) return false;

            // No issue should be created
            const list = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
                std.debug.panic("ls: {}", .{err});
            };
            defer allocator.free(list.stdout);
            defer allocator.free(list.stderr);

            const parsed = std.json.parseFromSlice([]JsonIssue, allocator, list.stdout, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.debug.panic("parse: {}", .{err});
            };
            defer parsed.deinit();

            // Oracle: no issues should exist
            return parsed.value.len == 0;
        }
    }.property, .{ .iterations = 20, .seed = 0xDEADBEEF });
}

test "prop: lifecycle simulation maintains invariants" {
    // Simulate random sequences of operations and verify state consistency
    const LifecycleCase = struct {
        // Sequence of operations: each is (op_type, target_idx, secondary_idx, priority)
        ops: [12]struct { op: u3, target: u3, secondary: u3, priority: u3 },
    };

    try zc.check(struct {
        fn property(args: LifecycleCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            var oracle = LifecycleOracle{};
            var ids: [LifecycleOracle.MAX_ISSUES]?[]const u8 = [_]?[]const u8{null} ** LifecycleOracle.MAX_ISSUES;
            var id_storage: [LifecycleOracle.MAX_ISSUES][32]u8 = undefined;

            // Execute operations
            for (args.ops) |op_data| {
                const idx = @as(usize, op_data.target) % LifecycleOracle.MAX_ISSUES;
                const secondary = @as(usize, op_data.secondary) % LifecycleOracle.MAX_ISSUES;
                const op: OpType = switch (op_data.op % 6) {
                    0 => .create,
                    1 => .delete,
                    2 => .set_open,
                    3 => .set_active,
                    4 => .set_closed,
                    5 => .add_dep,
                    else => unreachable,
                };

                switch (op) {
                    .create => {
                        if (!oracle.exists[idx]) {
                            const id = std.fmt.bufPrint(&id_storage[idx], "issue-{d}", .{idx}) catch continue;
                            ids[idx] = id;
                            const issue = Issue{
                                .id = id,
                                .title = id,
                                .description = "",
                                .status = .open,
                                .priority = op_data.priority % 5,
                                .issue_type = "task",
                                .assignee = null,
                                .created_at = fixed_timestamp,
                                .closed_at = null,
                                .close_reason = null,
                                .blocks = &.{},
                                .parent = null,
                            };
                            ts.storage.createIssue(issue, null) catch continue;
                            oracle.create(idx, op_data.priority % 5, null);
                        }
                    },
                    .delete => {
                        if (oracle.exists[idx]) {
                            ts.storage.deleteIssue(ids[idx].?) catch continue;
                            oracle.delete(idx);
                        }
                    },
                    .set_open => {
                        if (oracle.exists[idx]) {
                            ts.storage.updateStatus(ids[idx].?, .open, null, null) catch continue;
                            oracle.setStatus(idx, .open);
                        }
                    },
                    .set_active => {
                        if (oracle.exists[idx]) {
                            ts.storage.updateStatus(ids[idx].?, .active, null, null) catch continue;
                            oracle.setStatus(idx, .active);
                        }
                    },
                    .set_closed => {
                        if (oracle.exists[idx] and oracle.canClose(idx)) {
                            ts.storage.updateStatus(ids[idx].?, .closed, fixed_timestamp, null) catch continue;
                            oracle.setStatus(idx, .closed);
                        }
                    },
                    .add_dep => {
                        if (oracle.exists[idx] and oracle.exists[secondary] and idx != secondary) {
                            if (ts.storage.addDependency(ids[idx].?, ids[secondary].?, "blocks")) {
                                _ = oracle.addDep(idx, secondary);
                            } else |err| switch (err) {
                                error.DependencyCycle => {},
                                else => continue,
                            }
                        }
                    },
                }
            }

            // Verify invariants

            // 1. Ready count matches oracle
            const ready_issues = ts.storage.getReadyIssues() catch return false;
            defer storage_mod.freeIssues(allocator, ready_issues);
            if (ready_issues.len != oracle.readyCount()) return false;

            // 2. Status counts match
            for ([_]Status{ .open, .active, .closed }) |status| {
                const issues = ts.storage.listIssues(status) catch return false;
                defer storage_mod.freeIssues(allocator, issues);
                if (issues.len != oracle.countByStatus(status)) return false;
            }

            // 3. Each existing non-archived issue has correct status
            for (0..LifecycleOracle.MAX_ISSUES) |i| {
                if (oracle.exists[i] and !oracle.archived[i]) {
                    const maybe_issue = ts.storage.getIssue(ids[i].?) catch return false;
                    const issue = maybe_issue orelse return false;
                    defer issue.deinit(allocator);
                    if (issue.status != oracle.statuses[i]) return false;
                    // Closed issues must have closed_at
                    if (issue.status == .closed and issue.closed_at == null) return false;
                }
            }

            return true;
        }
    }.property, .{ .iterations = 50, .seed = 0xCAFE });
}

test "prop: transitive blocking chains" {
    // Test that blocking propagates through dependency chains
    // A -> B -> C -> D: if D is open, A/B/C should all be blocked
    const ChainCase = struct {
        chain_length: u3, // 2-7
        blocker_position: u3, // which one in chain is open (rest closed)
        target_position: u3, // which one to check if blocked
    };

    try zc.check(struct {
        fn property(args: ChainCase) bool {
            const allocator = std.testing.allocator;
            const chain_len = @max(2, (args.chain_length % 6) + 2); // 2-7

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            // Create chain: issue[0] -> issue[1] -> ... -> issue[n-1]
            var id_bufs: [8][16]u8 = undefined;
            var ids: [8][]const u8 = undefined;

            const blocker_pos = args.blocker_position % chain_len;
            const target_pos = args.target_position % chain_len;

            for (0..chain_len) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "chain-{d}", .{i}) catch return false;
                // All closed except the blocker
                const status: Status = if (i == blocker_pos) .open else .closed;
                const closed_at: ?[]const u8 = if (status == .closed) fixed_timestamp else null;
                const issue = Issue{
                    .id = ids[i],
                    .title = ids[i],
                    .description = "",
                    .status = status,
                    .priority = 2,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = fixed_timestamp,
                    .closed_at = closed_at,
                    .close_reason = null,
                    .blocks = &.{},
                    .parent = null,
                };
                ts.storage.createIssue(issue, null) catch return false;
            }

            // Create dependency chain: 0 depends on 1, 1 depends on 2, etc.
            for (0..chain_len - 1) |i| {
                ts.storage.addDependency(ids[i], ids[i + 1], "blocks") catch return false;
            }

            // Check if target is in ready list
            const ready = ts.storage.getReadyIssues() catch return false;
            defer storage_mod.freeIssues(allocator, ready);

            var target_in_ready = false;
            for (ready) |issue| {
                if (std.mem.eql(u8, issue.id, ids[target_pos])) {
                    target_in_ready = true;
                    break;
                }
            }

            // If target is open (== blocker_pos), it should be in ready iff not blocked
            // If target is closed, it should never be in ready
            if (target_pos == blocker_pos) {
                // Target is open, should be in ready iff not blocked by anything downstream
                // Since target IS the blocker, nothing blocks it
                return target_in_ready == true;
            } else {
                // Target is closed, never in ready
                return target_in_ready == false;
            }
        }
    }.property, .{ .iterations = 50, .seed = 0xFADE });
}

test "prop: parent-child close constraint" {
    // Cannot close a parent if it has open children
    const ParentChildCase = struct {
        num_children: u3, // 1-4
        children_closed: [4]bool, // which children are closed
    };

    try zc.check(struct {
        fn property(args: ParentChildCase) bool {
            const allocator = std.testing.allocator;
            const num_children = @max(1, (args.num_children % 4) + 1);

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            // Create parent
            const parent = Issue{
                .id = "parent",
                .title = "Parent",
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
            ts.storage.createIssue(parent, null) catch return false;

            // Create children
            var child_bufs: [4][16]u8 = undefined;
            var all_closed = true;
            for (0..num_children) |i| {
                const id = std.fmt.bufPrint(&child_bufs[i], "child-{d}", .{i}) catch return false;
                const is_closed = args.children_closed[i];
                if (!is_closed) all_closed = false;

                const child = Issue{
                    .id = id,
                    .title = id,
                    .description = "",
                    .status = if (is_closed) .closed else .open,
                    .priority = 2,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = fixed_timestamp,
                    .closed_at = if (is_closed) fixed_timestamp else null,
                    .close_reason = null,
                    .blocks = &.{},
                    .parent = null,
                };
                ts.storage.createIssue(child, "parent") catch return false;
            }

            // Try to close parent
            const result = ts.storage.updateStatus("parent", .closed, fixed_timestamp, null);

            // Oracle: can only close if all children are closed
            if (all_closed) {
                // Should succeed
                if (result) |_| {
                    return true;
                } else |_| {
                    return false;
                }
            } else {
                // Should fail with ChildrenNotClosed
                if (result) |_| {
                    return false; // Shouldn't succeed
                } else |err| {
                    return err == error.ChildrenNotClosed;
                }
            }
        }
    }.property, .{ .iterations = 30, .seed = 0xDAD });
}

test "prop: priority ordering in list" {
    // List should return issues sorted by priority (lower = higher priority)
    const PriorityCase = struct {
        priorities: [6]u3,
    };

    try zc.check(struct {
        fn property(args: PriorityCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            // Create issues with random priorities
            for (0..6) |i| {
                var id_buf: [16]u8 = undefined;
                const id = std.fmt.bufPrint(&id_buf, "pri-{d}", .{i}) catch return false;
                const issue = Issue{
                    .id = id,
                    .title = id,
                    .description = "",
                    .status = .open,
                    .priority = args.priorities[i] % 5,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = fixed_timestamp,
                    .closed_at = null,
                    .close_reason = null,
                    .blocks = &.{},
                    .parent = null,
                };
                ts.storage.createIssue(issue, null) catch return false;
            }

            // Get list
            const issues = ts.storage.listIssues(.open) catch return false;
            defer storage_mod.freeIssues(allocator, issues);

            // Verify sorted by priority (ascending)
            var prev_priority: i64 = -1;
            for (issues) |issue| {
                if (issue.priority < prev_priority) return false;
                prev_priority = issue.priority;
            }

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0xACE });
}

test "prop: status transition state machine" {
    // Verify: closed issues have closed_at, open/active don't
    // Verify: reopening clears closed_at
    const TransitionCase = struct {
        transitions: [8]u2, // 0=open, 1=active, 2=closed
    };

    try zc.check(struct {
        fn property(args: TransitionCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            // Create issue
            const issue = Issue{
                .id = "transition-test",
                .title = "Transition Test",
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
            ts.storage.createIssue(issue, null) catch return false;

            // Apply transitions
            for (args.transitions) |t| {
                const status: Status = switch (t % 3) {
                    0 => .open,
                    1 => .active,
                    2 => .closed,
                    else => unreachable,
                };
                const closed_at: ?[]const u8 = if (status == .closed) fixed_timestamp else null;
                ts.storage.updateStatus("transition-test", status, closed_at, null) catch continue;

                // Verify invariant after each transition
                const maybe_current = ts.storage.getIssue("transition-test") catch return false;
                const current = maybe_current orelse return false;
                defer current.deinit(allocator);

                // Invariant: closed_at set iff status is closed
                if (current.status == .closed) {
                    if (current.closed_at == null) return false;
                } else {
                    if (current.closed_at != null) return false;
                }
            }

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0xDEED });
}

test "prop: search finds exactly matching issues" {
    const SearchCase = struct {
        // Create issues with titles containing these substrings
        has_foo: [4]bool,
        has_bar: [4]bool,
    };

    try zc.check(struct {
        fn property(args: SearchCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            defer ts.deinit();

            var foo_count: usize = 0;
            var bar_count: usize = 0;

            // Create issues
            for (0..4) |i| {
                var title_buf: [32]u8 = undefined;
                var len: usize = 0;

                // Build title
                const prefix = std.fmt.bufPrint(title_buf[len..], "Issue {d}", .{i}) catch return false;
                len += prefix.len;

                if (args.has_foo[i]) {
                    const foo = std.fmt.bufPrint(title_buf[len..], " foo", .{}) catch return false;
                    len += foo.len;
                    foo_count += 1;
                }
                if (args.has_bar[i]) {
                    const bar = std.fmt.bufPrint(title_buf[len..], " bar", .{}) catch return false;
                    len += bar.len;
                    bar_count += 1;
                }

                var id_buf: [16]u8 = undefined;
                const id = std.fmt.bufPrint(&id_buf, "search-{d}", .{i}) catch return false;
                const issue = Issue{
                    .id = id,
                    .title = title_buf[0..len],
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
                ts.storage.createIssue(issue, null) catch return false;
            }

            // Search for "foo"
            const foo_results = ts.storage.searchIssues("foo") catch return false;
            defer storage_mod.freeIssues(allocator, foo_results);
            if (foo_results.len != foo_count) return false;

            // Search for "bar"
            const bar_results = ts.storage.searchIssues("bar") catch return false;
            defer storage_mod.freeIssues(allocator, bar_results);
            if (bar_results.len != bar_count) return false;

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0x5EED });
}
