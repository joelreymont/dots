const std = @import("std");
const fs = std.fs;

const build_options = @import("build_options");
const dot_binary = build_options.dot_binary;

const sqlite = @import("sqlite.zig");
const qc = @import("util/quickcheck.zig");
const status_util = @import("util/status.zig");
const mapping_util = @import("util/mapping.zig");

const max_output_bytes = 1024 * 1024;
const fixed_timestamp = "2024-01-01T00:00:00.000000+00:00";
const db_filename = "beads.db";

const RunResult = struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term };

const Status = status_util.StatusKind;

fn statusString(status: Status) []const u8 {
    return status_util.toString(status);
}

fn isBlocking(status: Status) bool {
    return status_util.isBlocking(status);
}

fn oracleReady(statuses: [4]Status, deps: [4][4]bool) [4]bool {
    // Filter out cycles: if deps[i][j] and deps[j][i], later one is skipped
    var effective_deps: [4][4]bool = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            if (deps[i][j] and deps[j][i] and j < i) {
                // Cycle: j->i was added first, skip i->j
                effective_deps[i][j] = false;
            } else {
                effective_deps[i][j] = deps[i][j];
            }
        }
    }

    var ready = [_]bool{ false, false, false, false };
    for (0..4) |i| {
        if (statuses[i] != .open) {
            ready[i] = false;
            continue;
        }
        var blocked = false;
        for (0..4) |j| {
            if (effective_deps[i][j] and isBlocking(statuses[j])) {
                blocked = true;
                break;
            }
        }
        ready[i] = !blocked;
    }
    return ready;
}

fn oracleListCount(statuses: [6]Status, filter: Status) usize {
    var count: usize = 0;
    for (statuses) |status| {
        if (status == filter) count += 1;
    }
    return count;
}

fn oracleChildBlocked(child_blocks: [3][3]bool, blocker_statuses: [3]Status) [3]bool {
    var blocked = [_]bool{ false, false, false };
    for (0..3) |i| {
        var has_blocker = false;
        for (0..3) |j| {
            if (child_blocks[i][j] and isBlocking(blocker_statuses[j])) {
                has_blocker = true;
                break;
            }
        }
        blocked[i] = has_blocker;
    }
    return blocked;
}

fn oracleUpdateClosed(done: bool) bool {
    return done;
}

fn runDot(allocator: std.mem.Allocator, args: []const []const u8, cwd: []const u8) !RunResult {
    return runDotWithInput(allocator, args, cwd, null);
}

fn runDotWithInput(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, dot_binary);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = if (input != null) .Pipe else .Ignore;

    try child.spawn();

    if (input) |data| {
        try child.stdin.?.writeAll(data);
        child.stdin.?.close();
        child.stdin = null;
    }

    const stdout = try child.stdout.?.readToEndAlloc(allocator, max_output_bytes);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, max_output_bytes);
    const term = try child.wait();

    return RunResult{ .stdout = stdout, .stderr = stderr, .term = term };
}

fn setupTestDir(allocator: std.mem.Allocator) ![]const u8 {
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const path = try std.fmt.allocPrint(allocator, "/tmp/dots-test-{s}", .{hex});

    try fs.makeDirAbsolute(path);
    return path;
}

fn cleanupTestDir(path: []const u8) !void {
    try fs.cwd().deleteTree(path);
}

fn cleanupTestDirOrPanic(path: []const u8) void {
    cleanupTestDir(path) catch |err| {
        std.debug.print("cleanup failed: {}\n", .{err});
        @panic("cleanup failed");
    };
}

fn setupTestDirOrPanic(allocator: std.mem.Allocator) []const u8 {
    return setupTestDir(allocator) catch |err| {
        std.debug.panic("setup: {}", .{err});
    };
}

fn cleanupTestDirAndFree(allocator: std.mem.Allocator, path: []const u8) void {
    cleanupTestDirOrPanic(path);
    allocator.free(path);
}

fn openTestStorage(allocator: std.mem.Allocator, dir: []const u8) sqlite.Storage {
    const db_path = allocPrintZ(allocator, "{s}/{s}", .{ dir, db_filename }) catch |err| {
        std.debug.panic("db path: {}", .{err});
    };
    defer allocator.free(db_path);

    return sqlite.Storage.open(allocator, db_path) catch |err| {
        std.debug.panic("open storage: {}", .{err});
    };
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const tmp = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(tmp);

    const out = try allocator.allocSentinel(u8, tmp.len, 0);
    @memcpy(out[0..tmp.len], tmp);
    return out;
}

fn trimNewline(input: []const u8) []const u8 {
    return std.mem.trimRight(u8, input, "\n");
}

fn isExitCode(term: std.process.Child.Term, code: u8) bool {
    return switch (term) {
        .Exited => |actual| actual == code,
        else => false,
    };
}

test "prop: ready issues match oracle" {
    const ReadyCase = struct {
        statuses: [4]Status,
        deps: [4][4]bool,
    };

    try qc.check(struct {
        fn property(args: ReadyCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var storage = openTestStorage(allocator, test_dir);
            defer storage.close();

            var id_bufs: [4][16]u8 = undefined;
            var ids: [4][]const u8 = undefined;

            for (0..4) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "t{d}", .{i}) catch |err| {
                    std.debug.panic("id format: {}", .{err});
                };

                const status = statusString(args.statuses[i]);
                const closed_at: ?[]const u8 = if (args.statuses[i] == .closed) fixed_timestamp else null;

                const issue = sqlite.Issue{
                    .id = ids[i],
                    .title = ids[i],
                    .description = "",
                    .status = status,
                    .priority = 2,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = fixed_timestamp,
                    .updated_at = fixed_timestamp,
                    .closed_at = closed_at,
                    .close_reason = null,
                    .after = null,
                    .parent = null,
                };

                storage.createIssue(issue) catch |err| {
                    std.debug.panic("create issue: {}", .{err});
                };
            }

            for (0..4) |i| {
                for (0..4) |j| {
                    if (args.deps[i][j]) {
                        storage.addDependency(ids[i], ids[j], "blocks", fixed_timestamp) catch |err| switch (err) {
                            error.DependencyCycle => {}, // Skip cycles
                            else => std.debug.panic("add dependency: {}", .{err}),
                        };
                    }
                }
            }

            const issues = storage.getReadyIssues() catch |err| {
                std.debug.panic("get ready: {}", .{err});
            };
            defer sqlite.freeIssues(allocator, issues);

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

    try qc.check(struct {
        fn property(args: ListCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var storage = openTestStorage(allocator, test_dir);
            defer storage.close();

            var id_bufs: [6][16]u8 = undefined;
            var ids: [6][]const u8 = undefined;

            for (0..6) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "i{d}", .{i}) catch |err| {
                    std.debug.panic("id format: {}", .{err});
                };

                const status = statusString(args.statuses[i]);
                const closed_at: ?[]const u8 = if (args.statuses[i] == .closed) fixed_timestamp else null;

                const issue = sqlite.Issue{
                    .id = ids[i],
                    .title = ids[i],
                    .description = "",
                    .status = status,
                    .priority = 2,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = fixed_timestamp,
                    .updated_at = fixed_timestamp,
                    .closed_at = closed_at,
                    .close_reason = null,
                    .after = null,
                    .parent = null,
                };

                storage.createIssue(issue) catch |err| {
                    std.debug.panic("create issue: {}", .{err});
                };
            }

            const filters = [_]Status{ .open, .active, .closed };
            for (filters) |filter| {
                const issues = storage.listIssues(statusString(filter)) catch |err| {
                    std.debug.panic("list issues: {}", .{err});
                };
                defer sqlite.freeIssues(allocator, issues);

                const expected_count = oracleListCount(args.statuses, filter);
                if (issues.len != expected_count) return false;

                for (issues) |issue| {
                    if (!std.mem.eql(u8, issue.status, statusString(filter))) return false;
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

    try qc.check(struct {
        fn property(args: TreeCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var storage = openTestStorage(allocator, test_dir);
            defer storage.close();

            var parent_buf: [16]u8 = undefined;
            const parent_id = std.fmt.bufPrint(&parent_buf, "parent", .{}) catch |err| {
                std.debug.panic("parent id: {}", .{err});
            };

            const parent_issue = sqlite.Issue{
                .id = parent_id,
                .title = parent_id,
                .description = "",
                .status = "open",
                .priority = 2,
                .issue_type = "task",
                .assignee = null,
                .created_at = fixed_timestamp,
                .updated_at = fixed_timestamp,
                .closed_at = null,
                .close_reason = null,
                .after = null,
                .parent = null,
            };
            storage.createIssue(parent_issue) catch |err| {
                std.debug.panic("create parent: {}", .{err});
            };

            var child_bufs: [3][16]u8 = undefined;
            var child_ids: [3][]const u8 = undefined;
            for (0..3) |i| {
                child_ids[i] = std.fmt.bufPrint(&child_bufs[i], "c{d}", .{i}) catch |err| {
                    std.debug.panic("child id: {}", .{err});
                };

                const status = statusString(args.child_statuses[i]);
                const closed_at: ?[]const u8 = if (args.child_statuses[i] == .closed) fixed_timestamp else null;

                const issue = sqlite.Issue{
                    .id = child_ids[i],
                    .title = child_ids[i],
                    .description = "",
                    .status = status,
                    .priority = 2,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = fixed_timestamp,
                    .updated_at = fixed_timestamp,
                    .closed_at = closed_at,
                    .close_reason = null,
                    .after = null,
                    .parent = null,
                };

                storage.createIssue(issue) catch |err| {
                    std.debug.panic("create child: {}", .{err});
                };

                storage.addDependency(child_ids[i], parent_id, "parent-child", fixed_timestamp) catch |err| {
                    std.debug.panic("add parent-child: {}", .{err});
                };
            }

            var blocker_bufs: [3][16]u8 = undefined;
            var blocker_ids: [3][]const u8 = undefined;
            for (0..3) |i| {
                blocker_ids[i] = std.fmt.bufPrint(&blocker_bufs[i], "b{d}", .{i}) catch |err| {
                    std.debug.panic("blocker id: {}", .{err});
                };

                const status = statusString(args.blocker_statuses[i]);
                const closed_at: ?[]const u8 = if (args.blocker_statuses[i] == .closed) fixed_timestamp else null;

                const issue = sqlite.Issue{
                    .id = blocker_ids[i],
                    .title = blocker_ids[i],
                    .description = "",
                    .status = status,
                    .priority = 2,
                    .issue_type = "task",
                    .assignee = null,
                    .created_at = fixed_timestamp,
                    .updated_at = fixed_timestamp,
                    .closed_at = closed_at,
                    .close_reason = null,
                    .after = null,
                    .parent = null,
                };

                storage.createIssue(issue) catch |err| {
                    std.debug.panic("create blocker: {}", .{err});
                };
            }

            for (0..3) |i| {
                for (0..3) |j| {
                    if (args.child_blocks[i][j]) {
                        storage.addDependency(child_ids[i], blocker_ids[j], "blocks", fixed_timestamp) catch |err| {
                            std.debug.panic("add block dep: {}", .{err});
                        };
                    }
                }
            }

            const children = storage.getChildren(parent_id) catch |err| {
                std.debug.panic("get children: {}", .{err});
            };
            defer sqlite.freeChildIssues(allocator, children);

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

    try qc.check(struct {
        fn property(args: UpdateCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            _ = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };

            const add = runDot(allocator, &.{ "add", "Update done test" }, test_dir) catch |err| {
                std.debug.panic("add: {}", .{err});
            };
            defer allocator.free(add.stdout);
            defer allocator.free(add.stderr);

            const id = trimNewline(add.stdout);
            if (id.len == 0) return false;

            const status = if (args.done) "done" else "open";
            const update = runDot(allocator, &.{ "update", id, "--status", status }, test_dir) catch |err| {
                std.debug.panic("update: {}", .{err});
            };
            defer allocator.free(update.stdout);
            defer allocator.free(update.stderr);
            if (!isExitCode(update.term, 0)) return false;

            const show = runDot(allocator, &.{ "show", id }, test_dir) catch |err| {
                std.debug.panic("show: {}", .{err});
            };
            defer allocator.free(show.stdout);
            defer allocator.free(show.stderr);
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

    try qc.check(struct {
        fn property(args: UnknownCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            _ = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };

            var id_buf: [8]u8 = undefined;
            for (args.raw, 0..) |byte, i| {
                id_buf[i] = @as(u8, 'a') + (byte % 26);
            }
            const id = id_buf[0..];

            const on_result = runDot(allocator, &.{ "on", id }, test_dir) catch |err| {
                std.debug.panic("on: {}", .{err});
            };
            defer allocator.free(on_result.stdout);
            defer allocator.free(on_result.stderr);
            if (!isExitCode(on_result.term, 1)) return false;
            if (std.mem.indexOf(u8, on_result.stderr, "Issue not found") == null) return false;

            const rm_result = runDot(allocator, &.{ "rm", id }, test_dir) catch |err| {
                std.debug.panic("rm: {}", .{err});
            };
            defer allocator.free(rm_result.stdout);
            defer allocator.free(rm_result.stderr);
            if (!isExitCode(rm_result.term, 1)) return false;
            if (std.mem.indexOf(u8, rm_result.stderr, "Issue not found") == null) return false;

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0xBAD1D });
}

test "prop: dependency cycle rejected" {
    // Test cycle detection at sqlite level
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var storage = openTestStorage(allocator, test_dir);
    defer storage.close();

    // Create two issues
    const issue_a = sqlite.Issue{
        .id = "test-a",
        .title = "Issue A",
        .description = "",
        .status = "open",
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .updated_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .after = null,
        .parent = null,
    };
    storage.createIssue(issue_a) catch |err| {
        std.debug.panic("create A: {}", .{err});
    };

    const issue_b = sqlite.Issue{
        .id = "test-b",
        .title = "Issue B",
        .description = "",
        .status = "open",
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .updated_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .after = null,
        .parent = null,
    };
    storage.createIssue(issue_b) catch |err| {
        std.debug.panic("create B: {}", .{err});
    };

    // Add A depends on B (A->B)
    storage.addDependency("test-a", "test-b", "blocks", fixed_timestamp) catch |err| {
        std.debug.panic("add A->B: {}", .{err});
    };

    // Try to add B depends on A (B->A) - should fail with DependencyCycle
    const cycle_result = storage.addDependency("test-b", "test-a", "blocks", fixed_timestamp);
    try std.testing.expectError(error.DependencyCycle, cycle_result);
}

test "prop: invalid dependency rejected" {
    const DepCase = struct {
        raw: [8]u8,
        use_parent: bool,
    };

    try qc.check(struct {
        fn property(args: DepCase) bool {
            const allocator = std.testing.allocator;

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            _ = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };

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

            const parsed = std.json.parseFromSlice([]JsonIssue, allocator, list.stdout, .{}) catch |err| {
                std.debug.panic("parse: {}", .{err});
            };
            defer parsed.deinit();

            // Oracle: no issues should exist
            return parsed.value.len == 0;
        }
    }.property, .{ .iterations = 20, .seed = 0xDEADBEEF });
}

const max_model_tasks = 8;
const max_model_steps = 20;
const max_hook_todos = 4;
const max_hydrate_issues = 4;

const Action = enum(u4) {
    add,
    add_json,
    quick_add,
    on,
    off,
    update,
    rm,
    list_text,
    list_json,
    ready_text,
    ready_json,
    tree,
    find,
    show,
    help,
    version,
};

const ModelTask = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: Status,
    priority: i64,
    order: usize,
};

const Model = struct {
    tasks: [max_model_tasks]?ModelTask,
    deps: [max_model_tasks][max_model_tasks]bool,
    parents: [max_model_tasks]?usize,
    next_order: usize,

    fn init() Model {
        const empty_task = [_]?ModelTask{null} ** max_model_tasks;
        const empty_parent = [_]?usize{null} ** max_model_tasks;
        const empty_row = [_]bool{false} ** max_model_tasks;
        const empty_deps = [_][max_model_tasks]bool{empty_row} ** max_model_tasks;
        return .{ .tasks = empty_task, .deps = empty_deps, .parents = empty_parent, .next_order = 0 };
    }
};

const JsonIssue = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    status: []const u8,
    priority: i64,
    issue_type: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    closed_at: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
};

const ShowInfo = struct {
    id: []const u8,
    title: []const u8,
    status: Status,
    priority: i64,
    description: []const u8,
    has_closed: bool,
};

fn modelCount(model: *const Model) usize {
    var count: usize = 0;
    for (model.tasks) |task| {
        if (task != null) count += 1;
    }
    return count;
}

fn collectExistingIndices(model: *const Model, out: *[max_model_tasks]usize) usize {
    var len: usize = 0;
    for (0..max_model_tasks) |i| {
        if (model.tasks[i] != null) {
            out[len] = i;
            len += 1;
        }
    }
    return len;
}

fn sortIndices(model: *const Model, indices: []usize) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const left = model.tasks[indices[j - 1]].?;
            const right = model.tasks[indices[j]].?;
            if (left.priority < right.priority) break;
            if (left.priority == right.priority and left.order <= right.order) break;
            const tmp = indices[j];
            indices[j] = indices[j - 1];
            indices[j - 1] = tmp;
        }
    }
}

fn collectListIndices(model: *const Model, filter: ?Status, skip_done: bool, out: *[max_model_tasks]usize) usize {
    var len: usize = 0;
    for (0..max_model_tasks) |i| {
        if (model.tasks[i]) |task| {
            if (skip_done and task.status == .closed) continue;
            if (filter) |want| {
                if (task.status != want) continue;
            }
            out[len] = i;
            len += 1;
        }
    }
    sortIndices(model, out[0..len]);
    return len;
}

fn collectReadyIndices(model: *const Model, out: *[max_model_tasks]usize) usize {
    var len: usize = 0;
    for (0..max_model_tasks) |i| {
        if (model.tasks[i]) |task| {
            if (task.status != .open) continue;
            var blocked = false;
            for (0..max_model_tasks) |j| {
                if (model.deps[i][j]) {
                    if (model.tasks[j]) |blocker| {
                        if (isBlocking(blocker.status)) {
                            blocked = true;
                            break;
                        }
                    }
                }
            }
            if (!blocked) {
                out[len] = i;
                len += 1;
            }
        }
    }
    sortIndices(model, out[0..len]);
    return len;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn parseStatusDisplay(input: []const u8) ?Status {
    if (std.mem.eql(u8, input, "open")) return .open;
    if (std.mem.eql(u8, input, "active")) return .active;
    if (std.mem.eql(u8, input, "done")) return .closed;
    if (std.mem.eql(u8, input, "closed")) return .closed;
    return null;
}

fn parseStatusChar(ch: u8) ?Status {
    return switch (ch) {
        'o' => .open,
        '>' => .active,
        'x' => .closed,
        else => null,
    };
}

fn listJsonMatches(allocator: std.mem.Allocator, model: *const Model, input: []const u8, filter: ?Status, skip_done: bool) bool {
    const parsed = std.json.parseFromSlice([]JsonIssue, allocator, input, .{}) catch |err| {
        std.debug.panic("parse list json: {}", .{err});
    };
    defer parsed.deinit();

    const issues = parsed.value;
    var expected: [max_model_tasks]usize = undefined;
    const expected_len = collectListIndices(model, filter, skip_done, &expected);
    if (issues.len != expected_len) return false;

    var found = [_]bool{false} ** max_model_tasks;
    var last_priority: ?i64 = null;
    for (issues) |issue| {
        if (last_priority) |prev| {
            if (issue.priority < prev) return false;
        }
        last_priority = issue.priority;

        var matched_idx: ?usize = null;
        for (expected[0..expected_len]) |idx| {
            const task = model.tasks[idx].?;
            if (std.mem.eql(u8, issue.id, task.id)) {
                matched_idx = idx;
                if (!std.mem.eql(u8, issue.title, task.title)) return false;
                const desc = issue.description orelse "";
                if (!std.mem.eql(u8, desc, task.description)) return false;
                const status = parseStatusDisplay(issue.status) orelse return false;
                if (status != task.status) return false;
                if (issue.priority != task.priority) return false;
                break;
            }
        }
        if (matched_idx == null) return false;
        if (found[matched_idx.?]) return false;
        found[matched_idx.?] = true;
    }

    for (expected[0..expected_len]) |idx| {
        if (!found[idx]) return false;
    }

    return true;
}

fn readyJsonMatches(allocator: std.mem.Allocator, model: *const Model, input: []const u8) bool {
    const parsed = std.json.parseFromSlice([]JsonIssue, allocator, input, .{}) catch |err| {
        std.debug.panic("parse ready json: {}", .{err});
    };
    defer parsed.deinit();

    const issues = parsed.value;
    var expected: [max_model_tasks]usize = undefined;
    const expected_len = collectReadyIndices(model, &expected);
    if (issues.len != expected_len) return false;

    var found = [_]bool{false} ** max_model_tasks;
    var last_priority: ?i64 = null;
    for (issues) |issue| {
        if (last_priority) |prev| {
            if (issue.priority < prev) return false;
        }
        last_priority = issue.priority;

        var matched_idx: ?usize = null;
        for (expected[0..expected_len]) |idx| {
            const task = model.tasks[idx].?;
            if (std.mem.eql(u8, issue.id, task.id)) {
                matched_idx = idx;
                const status = parseStatusDisplay(issue.status) orelse return false;
                if (status != task.status) return false;
                break;
            }
        }
        if (matched_idx == null) return false;
        if (found[matched_idx.?]) return false;
        found[matched_idx.?] = true;
    }

    for (expected[0..expected_len]) |idx| {
        if (!found[idx]) return false;
    }

    return true;
}

fn listTextMatches(model: *const Model, input: []const u8, filter: ?Status, skip_done: bool) bool {
    var expected: [max_model_tasks]usize = undefined;
    const expected_len = collectListIndices(model, filter, skip_done, &expected);

    var lines = std.mem.splitScalar(u8, input, '\n');
    var found = [_]bool{false} ** max_model_tasks;
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const open_bracket = std.mem.indexOfScalar(u8, line, '[') orelse return false;
        const close_bracket = std.mem.indexOfScalarPos(u8, line, open_bracket + 1, ']') orelse return false;
        if (close_bracket + 2 >= line.len) return false;
        const id = line[open_bracket + 1 .. close_bracket];
        const status_char = line[close_bracket + 2];
        const status = parseStatusChar(status_char) orelse return false;
        var matched_idx: ?usize = null;
        for (expected[0..expected_len]) |idx| {
            const task = model.tasks[idx].?;
            if (std.mem.eql(u8, id, task.id)) {
                matched_idx = idx;
                if (status != task.status) return false;
                break;
            }
        }
        if (matched_idx == null) return false;
        if (found[matched_idx.?]) return false;
        found[matched_idx.?] = true;
        seen += 1;
    }

    if (seen != expected_len) return false;
    for (expected[0..expected_len]) |idx| {
        if (!found[idx]) return false;
    }
    return true;
}

fn readyTextMatches(model: *const Model, input: []const u8) bool {
    var expected: [max_model_tasks]usize = undefined;
    const expected_len = collectReadyIndices(model, &expected);

    var lines = std.mem.splitScalar(u8, input, '\n');
    var found = [_]bool{false} ** max_model_tasks;
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const open_bracket = std.mem.indexOfScalar(u8, line, '[') orelse return false;
        const close_bracket = std.mem.indexOfScalarPos(u8, line, open_bracket + 1, ']') orelse return false;
        if (close_bracket + 2 >= line.len) return false;
        const id = line[open_bracket + 1 .. close_bracket];
        const status_char = line[close_bracket + 2];
        const status = parseStatusChar(status_char) orelse return false;
        var matched_idx: ?usize = null;
        for (expected[0..expected_len]) |idx| {
            const task = model.tasks[idx].?;
            if (std.mem.eql(u8, id, task.id)) {
                matched_idx = idx;
                if (status != task.status) return false;
                break;
            }
        }
        if (matched_idx == null) return false;
        if (found[matched_idx.?]) return false;
        found[matched_idx.?] = true;
        seen += 1;
    }

    if (seen != expected_len) return false;
    for (expected[0..expected_len]) |idx| {
        if (!found[idx]) return false;
    }
    return true;
}

fn findTextMatches(model: *const Model, input: []const u8, query: []const u8) bool {
    var expected: [max_model_tasks]usize = undefined;
    var expected_len: usize = 0;
    for (0..max_model_tasks) |i| {
        if (model.tasks[i]) |task| {
            if (containsCaseInsensitive(task.title, query) or containsCaseInsensitive(task.description, query)) {
                expected[expected_len] = i;
                expected_len += 1;
            }
        }
    }
    sortIndices(model, expected[0..expected_len]);

    var lines = std.mem.splitScalar(u8, input, '\n');
    var found = [_]bool{false} ** max_model_tasks;
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const open_bracket = std.mem.indexOfScalar(u8, line, '[') orelse return false;
        const close_bracket = std.mem.indexOfScalarPos(u8, line, open_bracket + 1, ']') orelse return false;
        if (close_bracket + 2 >= line.len) return false;
        const id = line[open_bracket + 1 .. close_bracket];
        const status_char = line[close_bracket + 2];
        const status = parseStatusChar(status_char) orelse return false;
        var matched_idx: ?usize = null;
        for (expected[0..expected_len]) |idx| {
            const task = model.tasks[idx].?;
            if (std.mem.eql(u8, id, task.id)) {
                matched_idx = idx;
                if (status != task.status) return false;
                break;
            }
        }
        if (matched_idx == null) return false;
        if (found[matched_idx.?]) return false;
        found[matched_idx.?] = true;
        seen += 1;
    }

    if (seen != expected_len) return false;
    for (expected[0..expected_len]) |idx| {
        if (!found[idx]) return false;
    }
    return true;
}

fn findLineContaining(output: []const u8, needle: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, output, needle) orelse return null;
    var start = std.mem.lastIndexOfScalar(u8, output[0..pos], '\n') orelse 0;
    if (start != 0) start += 1;
    const end = std.mem.indexOfScalarPos(u8, output, pos, '\n') orelse output.len;
    return output[start..end];
}

fn treeTextMatches(model: *const Model, output: []const u8) bool {
    var root_indices: [max_model_tasks]usize = undefined;
    var root_len: usize = 0;
    for (0..max_model_tasks) |i| {
        if (model.tasks[i]) |task| {
            if (task.status == .closed) continue;
            if (model.parents[i] != null) continue;
            root_indices[root_len] = i;
            root_len += 1;
        }
    }
    sortIndices(model, root_indices[0..root_len]);

    for (root_indices[0..root_len]) |root_idx| {
        const root_task = model.tasks[root_idx].?;
        const root_needle = std.fmt.allocPrint(std.testing.allocator, "[{s}]", .{root_task.id}) catch |err| {
            std.debug.panic("tree needle: {}", .{err});
        };
        defer std.testing.allocator.free(root_needle);
        if (findLineContaining(output, root_needle) == null) return false;

        var child_indices: [max_model_tasks]usize = undefined;
        var child_len: usize = 0;
        for (0..max_model_tasks) |i| {
            if (model.parents[i]) |parent_idx| {
                if (parent_idx == root_idx) {
                    child_indices[child_len] = i;
                    child_len += 1;
                }
            }
        }
        sortIndices(model, child_indices[0..child_len]);

        for (child_indices[0..child_len]) |child_idx| {
            const child_task = model.tasks[child_idx].?;
            const child_needle = std.fmt.allocPrint(std.testing.allocator, "[{s}]", .{child_task.id}) catch |err| {
                std.debug.panic("child needle: {}", .{err});
            };
            defer std.testing.allocator.free(child_needle);

            const line = findLineContaining(output, child_needle) orelse return false;
            var blocked = false;
            for (0..max_model_tasks) |j| {
                if (model.deps[child_idx][j]) {
                    if (model.tasks[j]) |blocker| {
                        if (isBlocking(blocker.status)) {
                            blocked = true;
                            break;
                        }
                    }
                }
            }
            const has_blocked = std.mem.indexOf(u8, line, "(blocked)") != null;
            if (blocked != has_blocked) return false;
        }
    }

    return true;
}

fn parseShow(output: []const u8) ?ShowInfo {
    var info = ShowInfo{
        .id = "",
        .title = "",
        .status = .open,
        .priority = 0,
        .description = "",
        .has_closed = false,
    };
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ID:")) {
            info.id = std.mem.trim(u8, line[3..], " ");
        } else if (std.mem.startsWith(u8, line, "Title:")) {
            info.title = std.mem.trim(u8, line[6..], " ");
        } else if (std.mem.startsWith(u8, line, "Status:")) {
            const raw = std.mem.trim(u8, line[7..], " ");
            info.status = parseStatusDisplay(raw) orelse return null;
        } else if (std.mem.startsWith(u8, line, "Priority:")) {
            const raw = std.mem.trim(u8, line[9..], " ");
            info.priority = std.fmt.parseInt(i64, raw, 10) catch return null;
        } else if (std.mem.startsWith(u8, line, "Desc:")) {
            info.description = std.mem.trim(u8, line[5..], " ");
        } else if (std.mem.startsWith(u8, line, "Closed:")) {
            info.has_closed = true;
        }
    }
    if (info.id.len == 0 or info.title.len == 0) return null;
    return info;
}

fn makeTitle(allocator: std.mem.Allocator, counter: usize) []const u8 {
    return std.fmt.allocPrint(allocator, "Task {d}", .{counter}) catch |err| {
        std.debug.panic("title alloc: {}", .{err});
    };
}

fn makeDescription(allocator: std.mem.Allocator, counter: usize) []const u8 {
    return std.fmt.allocPrint(allocator, "Desc {d}", .{counter}) catch |err| {
        std.debug.panic("desc alloc: {}", .{err});
    };
}

fn randomAction(random: std.Random, has_capacity: bool) Action {
    const roll = random.uintLessThan(u8, 100);
    if (!has_capacity) {
        if (roll < 20) return .list_json;
        if (roll < 40) return .ready_json;
        if (roll < 60) return .tree;
        if (roll < 75) return .find;
        if (roll < 90) return .show;
        if (roll < 95) return .help;
        return .version;
    }
    if (roll < 10) return .add;
    if (roll < 20) return .add_json;
    if (roll < 28) return .quick_add;
    if (roll < 38) return .on;
    if (roll < 48) return .off;
    if (roll < 58) return .update;
    if (roll < 66) return .rm;
    if (roll < 72) return .list_text;
    if (roll < 78) return .list_json;
    if (roll < 84) return .ready_text;
    if (roll < 90) return .ready_json;
    if (roll < 94) return .tree;
    if (roll < 97) return .find;
    if (roll < 98) return .show;
    if (roll < 99) return .help;
    return .version;
}

fn pickIndex(random: std.Random, indices: []const usize) usize {
    const idx = random.uintLessThan(usize, indices.len);
    return indices[idx];
}

fn statusToUpdateArg(status: Status) []const u8 {
    return switch (status) {
        .open => "open",
        .active => "active",
        .closed => "done",
    };
}

fn verifyAllCli(allocator: std.mem.Allocator, test_dir: []const u8, model: *const Model) bool {
    const list_json = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
        std.debug.panic("ls json: {}", .{err});
    };
    defer allocator.free(list_json.stdout);
    defer allocator.free(list_json.stderr);
    if (!listJsonMatches(allocator, model, list_json.stdout, null, true)) return false;

    const ready_json = runDot(allocator, &.{ "ready", "--json" }, test_dir) catch |err| {
        std.debug.panic("ready json: {}", .{err});
    };
    defer allocator.free(ready_json.stdout);
    defer allocator.free(ready_json.stderr);
    if (!readyJsonMatches(allocator, model, ready_json.stdout)) return false;

    const tree = runDot(allocator, &.{"tree"}, test_dir) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer allocator.free(tree.stdout);
    defer allocator.free(tree.stderr);
    if (!treeTextMatches(model, tree.stdout)) return false;

    return true;
}

test "prop: cli state machine oracle" {
    const Scenario = struct {
        seed: u64,
        steps: u8,
    };

    try qc.check(struct {
        fn property(args: Scenario) bool {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            _ = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };

            var model = Model.init();
            var task_counter: usize = 0;

            var prng = std.Random.DefaultPrng.init(args.seed);
            const random = prng.random();
            const total_steps: usize = @as(usize, args.steps % max_model_steps) + 1;

            const State = enum { init, step, verify, done };
            var state: State = .init;
            var step_idx: usize = 0;

            state: while (true) {
                switch (state) {
                    .init => {
                        state = .step;
                        continue :state;
                    },
                    .step => {
                    if (step_idx >= total_steps) {
                        state = .verify;
                        continue :state;
                    }

                    var existing: [max_model_tasks]usize = undefined;
                    const existing_len = collectExistingIndices(&model, &existing);
                    const has_capacity = modelCount(&model) < max_model_tasks;
                    const action = randomAction(random, has_capacity);

                    switch (action) {
                        .add, .add_json, .quick_add => {
                            if (!has_capacity) {
                                step_idx += 1;
                                continue :state;
                            }

                            const slot = if (existing_len < max_model_tasks) blk: {
                                var idx: usize = 0;
                                while (idx < max_model_tasks) : (idx += 1) {
                                    if (model.tasks[idx] == null) break :blk idx;
                                }
                                break :blk 0;
                            } else 0;

                            const title = makeTitle(allocator, task_counter);
                            const is_quick = action == .quick_add;
                            const description = if (is_quick) "" else makeDescription(allocator, task_counter);
                            const priority: i64 = if (is_quick) 2 else @as(i64, random.uintLessThan(u8, 4));
                            task_counter += 1;
                            var parent_idx: ?usize = null;
                            var dep_idx: ?usize = null;

                            var args_list: std.ArrayList([]const u8) = .empty;
                            defer args_list.deinit(allocator);

                            switch (action) {
                                .quick_add => {
                                    args_list.append(allocator, title) catch |err| {
                                        std.debug.panic("args add: {}", .{err});
                                    };
                                },
                                else => {
                                    args_list.append(allocator, "add") catch |err| {
                                        std.debug.panic("args add: {}", .{err});
                                    };
                                    args_list.append(allocator, title) catch |err| {
                                        std.debug.panic("args title: {}", .{err});
                                    };
                                    args_list.append(allocator, "-p") catch |err| {
                                        std.debug.panic("args priority: {}", .{err});
                                    };
                                    const prio_str = std.fmt.allocPrint(allocator, "{d}", .{priority}) catch |err| {
                                        std.debug.panic("prio alloc: {}", .{err});
                                    };
                                    args_list.append(allocator, prio_str) catch |err| {
                                        std.debug.panic("args prio: {}", .{err});
                                    };
                                    args_list.append(allocator, "-d") catch |err| {
                                        std.debug.panic("args desc flag: {}", .{err});
                                    };
                                    args_list.append(allocator, description) catch |err| {
                                        std.debug.panic("args desc: {}", .{err});
                                    };

                                    if (existing_len > 0 and random.boolean()) {
                                        const picked_parent = pickIndex(random, existing[0..existing_len]);
                                        args_list.append(allocator, "-P") catch |err| {
                                            std.debug.panic("args parent flag: {}", .{err});
                                        };
                                        args_list.append(allocator, model.tasks[picked_parent].?.id) catch |err| {
                                            std.debug.panic("args parent: {}", .{err});
                                        };
                                        parent_idx = picked_parent;
                                    }

                                    if (existing_len > 0 and random.boolean()) {
                                        const picked_dep = pickIndex(random, existing[0..existing_len]);
                                        args_list.append(allocator, "-a") catch |err| {
                                            std.debug.panic("args dep flag: {}", .{err});
                                        };
                                        args_list.append(allocator, model.tasks[picked_dep].?.id) catch |err| {
                                            std.debug.panic("args dep: {}", .{err});
                                        };
                                        dep_idx = picked_dep;
                                    }

                                    if (action == .add_json) {
                                        args_list.append(allocator, "--json") catch |err| {
                                            std.debug.panic("args json: {}", .{err});
                                        };
                                    }
                                },
                            }

                            const result = runDot(allocator, args_list.items, test_dir) catch |err| {
                                std.debug.panic("add: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            const invalid_parent_dep = parent_idx != null and dep_idx != null and parent_idx.? == dep_idx.?;
                            if (invalid_parent_dep) {
                                if (!isExitCode(result.term, 1)) return false;
                                if (std.mem.indexOf(u8, result.stderr, "parent and after cannot be the same issue") == null) return false;
                            } else {
                                if (!isExitCode(result.term, 0)) return false;

                                var id_slice: []const u8 = undefined;
                                if (action == .add_json) {
                                    const parsed = std.json.parseFromSlice(JsonIssue, allocator, result.stdout, .{}) catch |err| {
                                        std.debug.panic("parse add json: {}", .{err});
                                    };
                                    defer parsed.deinit();
                                    const issue = parsed.value;
                                    id_slice = issue.id;
                                    if (!std.mem.eql(u8, issue.title, title)) return false;
                                    if (issue.priority != priority) return false;
                                    if (!std.mem.eql(u8, issue.description orelse "", description)) return false;
                                } else {
                                    id_slice = trimNewline(result.stdout);
                                }

                                model.tasks[slot] = .{
                                    .id = allocator.dupe(u8, id_slice) catch |err| {
                                        std.debug.panic("id dup: {}", .{err});
                                    },
                                    .title = title,
                                    .description = description,
                                    .status = .open,
                                    .priority = priority,
                                    .order = model.next_order,
                                };
                                if (parent_idx) |idx| model.parents[slot] = idx;
                                if (dep_idx) |idx| model.deps[slot][idx] = true;
                                model.next_order += 1;
                            }
                        },
                        .on => {
                            if (existing_len == 0) {
                                const result = runDot(allocator, &.{ "on", "missing" }, test_dir) catch |err| {
                                    std.debug.panic("on missing: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 1)) return false;
                                if (std.mem.indexOf(u8, result.stderr, "Issue not found") == null) return false;
                            } else {
                                const idx = pickIndex(random, existing[0..existing_len]);
                                const result = runDot(allocator, &.{ "on", model.tasks[idx].?.id }, test_dir) catch |err| {
                                    std.debug.panic("on: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 0)) return false;
                                model.tasks[idx].?.status = .active;
                            }
                        },
                        .off => {
                            if (existing_len == 0) {
                                const result = runDot(allocator, &.{ "off", "missing" }, test_dir) catch |err| {
                                    std.debug.panic("off missing: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 1)) return false;
                                if (std.mem.indexOf(u8, result.stderr, "Issue not found") == null) return false;
                            } else {
                                const idx = pickIndex(random, existing[0..existing_len]);
                                const result = runDot(allocator, &.{ "off", model.tasks[idx].?.id }, test_dir) catch |err| {
                                    std.debug.panic("off: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 0)) return false;
                                model.tasks[idx].?.status = .closed;
                            }
                        },
                        .update => {
                            if (existing_len == 0) {
                                const result = runDot(allocator, &.{ "update", "missing", "--status", "done" }, test_dir) catch |err| {
                                    std.debug.panic("update missing: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 1)) return false;
                                if (std.mem.indexOf(u8, result.stderr, "Issue not found") == null) return false;
                            } else {
                                const idx = pickIndex(random, existing[0..existing_len]);
                                const next_status = @as(Status, @enumFromInt(random.uintLessThan(u2, 3)));
                                const status_arg = statusToUpdateArg(next_status);
                                const result = runDot(allocator, &.{ "update", model.tasks[idx].?.id, "--status", status_arg }, test_dir) catch |err| {
                                    std.debug.panic("update: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 0)) return false;
                                model.tasks[idx].?.status = next_status;
                            }
                        },
                        .rm => {
                            if (existing_len == 0) {
                                const result = runDot(allocator, &.{ "rm", "missing" }, test_dir) catch |err| {
                                    std.debug.panic("rm missing: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 1)) return false;
                                if (std.mem.indexOf(u8, result.stderr, "Issue not found") == null) return false;
                            } else {
                                const idx = pickIndex(random, existing[0..existing_len]);
                                const result = runDot(allocator, &.{ "rm", model.tasks[idx].?.id }, test_dir) catch |err| {
                                    std.debug.panic("rm: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 0)) return false;
                                model.tasks[idx] = null;
                                model.parents[idx] = null;
                                for (0..max_model_tasks) |j| {
                                    model.deps[idx][j] = false;
                                    model.deps[j][idx] = false;
                                    if (model.parents[j] == idx) model.parents[j] = null;
                                }
                            }
                        },
                        .list_text => {
                            const result = runDot(allocator, &.{"ls"}, test_dir) catch |err| {
                                std.debug.panic("ls: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (!listTextMatches(&model, result.stdout, null, true)) return false;
                        },
                        .list_json => {
                            const result = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
                                std.debug.panic("ls json: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (!listJsonMatches(allocator, &model, result.stdout, null, true)) return false;
                        },
                        .ready_text => {
                            const result = runDot(allocator, &.{"ready"}, test_dir) catch |err| {
                                std.debug.panic("ready: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (!readyTextMatches(&model, result.stdout)) return false;
                        },
                        .ready_json => {
                            const result = runDot(allocator, &.{ "ready", "--json" }, test_dir) catch |err| {
                                std.debug.panic("ready json: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (!readyJsonMatches(allocator, &model, result.stdout)) return false;
                        },
                        .tree => {
                            const result = runDot(allocator, &.{"tree"}, test_dir) catch |err| {
                                std.debug.panic("tree: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (!treeTextMatches(&model, result.stdout)) return false;
                        },
                        .find => {
                            const query = if (existing_len > 0) blk: {
                                const idx = pickIndex(random, existing[0..existing_len]);
                                const title = model.tasks[idx].?.title;
                                const len = @min(@as(usize, 3), title.len);
                                break :blk title[0..len];
                            } else "missing";

                            const result = runDot(allocator, &.{ "find", query }, test_dir) catch |err| {
                                std.debug.panic("find: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (!findTextMatches(&model, result.stdout, query)) return false;
                        },
                        .show => {
                            if (existing_len == 0) {
                                const result = runDot(allocator, &.{ "show", "missing" }, test_dir) catch |err| {
                                    std.debug.panic("show missing: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                if (!isExitCode(result.term, 1)) return false;
                                if (std.mem.indexOf(u8, result.stderr, "Issue not found") == null) return false;
                            } else {
                                const idx = pickIndex(random, existing[0..existing_len]);
                                const task = model.tasks[idx].?;
                                const result = runDot(allocator, &.{ "show", task.id }, test_dir) catch |err| {
                                    std.debug.panic("show: {}", .{err});
                                };
                                defer allocator.free(result.stdout);
                                defer allocator.free(result.stderr);
                                const info = parseShow(result.stdout) orelse return false;
                                if (!std.mem.eql(u8, info.id, task.id)) return false;
                                if (!std.mem.eql(u8, info.title, task.title)) return false;
                                if (info.status != task.status) return false;
                                if (info.priority != task.priority) return false;
                                if (!std.mem.eql(u8, info.description, task.description) and task.description.len > 0) return false;
                            }
                        },
                        .help => {
                            const result = runDot(allocator, &.{"--help"}, test_dir) catch |err| {
                                std.debug.panic("help: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (std.mem.indexOf(u8, result.stdout, "dots - Connect the dots") == null) return false;
                        },
                        .version => {
                            const result = runDot(allocator, &.{"--version"}, test_dir) catch |err| {
                                std.debug.panic("version: {}", .{err});
                            };
                            defer allocator.free(result.stdout);
                            defer allocator.free(result.stderr);
                            if (!std.mem.startsWith(u8, result.stdout, "dots ")) return false;
                        },
                    }

                    step_idx += 1;
                    continue :state;
                },
                    .verify => {
                        if (!verifyAllCli(allocator, test_dir, &model)) return false;
                        state = .done;
                        continue :state;
                    },
                    .done => break :state,
                }
            }

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0x5EED5EED });
}

const HookTodo = struct {
    content: []const u8,
    status: []const u8,
    activeForm: []const u8,
};

fn buildTodoWriteJson(allocator: std.mem.Allocator, todos: []const HookTodo) []const u8 {
    const HookInput = struct {
        tool_name: []const u8,
        tool_input: struct {
            todos: []const HookTodo,
        },
    };

    const payload = HookInput{
        .tool_name = "TodoWrite",
        .tool_input = .{ .todos = todos },
    };

    return std.json.Stringify.valueAlloc(allocator, payload, .{}) catch |err| {
        std.debug.panic("hook json: {}", .{err});
    };
}

const Mapping = mapping_util.Mapping;

fn loadMappingFile(allocator: std.mem.Allocator, dir: []const u8) Mapping {
    var map: Mapping = .{};
    errdefer mapping_util.deinit(allocator, &map);

    const path = std.fmt.allocPrint(allocator, "{s}/.beads/todo-mapping.json", .{dir}) catch |err| {
        std.debug.panic("mapping path: {}", .{err});
    };
    defer allocator.free(path);

    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => std.debug.panic("mapping open: {}", .{err}),
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, max_output_bytes) catch |err| {
        std.debug.panic("mapping read: {}", .{err});
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(Mapping, allocator, content, .{ .ignore_unknown_fields = false }) catch |err| {
        std.debug.panic("mapping parse: {}", .{err});
    };
    defer parsed.deinit();

    var it = parsed.value.map.iterator();
    while (it.next()) |entry| {
        const key = allocator.dupe(u8, entry.key_ptr.*) catch |err| {
            std.debug.panic("mapping key: {}", .{err});
        };
        const val = allocator.dupe(u8, entry.value_ptr.*) catch |err| {
            allocator.free(key);
            std.debug.panic("mapping val: {}", .{err});
        };
        map.map.put(allocator, key, val) catch |err| {
            allocator.free(key);
            allocator.free(val);
            std.debug.panic("mapping insert: {}", .{err});
        };
    }

    return map;
}

test "prop: hook sync matches oracle" {
    const HookCase = struct {
        seed: u64,
        count: u8,
    };

    try qc.check(struct {
        fn property(args: HookCase) bool {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var prng = std.Random.DefaultPrng.init(args.seed);
            const random = prng.random();
            const todo_count: usize = @as(usize, args.count % max_hook_todos) + 1;

            var todos_buf: [max_hook_todos]HookTodo = undefined;
            var contents_buf: [max_hook_todos][16]u8 = undefined;
            var forms_buf: [max_hook_todos][16]u8 = undefined;

            for (0..todo_count) |i| {
                const content = std.fmt.bufPrint(&contents_buf[i], "todo{d}", .{i}) catch |err| {
                    std.debug.panic("todo content: {}", .{err});
                };
                const active_form = std.fmt.bufPrint(&forms_buf[i], "form{d}", .{i}) catch |err| {
                    std.debug.panic("todo form: {}", .{err});
                };
                const status = if (random.boolean()) "pending" else "in_progress";
                todos_buf[i] = .{ .content = content, .status = status, .activeForm = active_form };
            }

            const input1 = buildTodoWriteJson(allocator, todos_buf[0..todo_count]);
            const hook1 = runDotWithInput(allocator, &.{ "hook", "sync" }, test_dir, input1) catch |err| {
                std.debug.panic("hook sync: {}", .{err});
            };
            defer allocator.free(hook1.stdout);
            defer allocator.free(hook1.stderr);
            if (!isExitCode(hook1.term, 0)) return false;

            const list1 = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
                std.debug.panic("list json: {}", .{err});
            };
            defer allocator.free(list1.stdout);
            defer allocator.free(list1.stderr);

            const parsed1 = std.json.parseFromSlice([]JsonIssue, allocator, list1.stdout, .{}) catch |err| {
                std.debug.panic("parse list: {}", .{err});
            };
            defer parsed1.deinit();
            if (parsed1.value.len != todo_count) return false;

            for (parsed1.value) |issue| {
                var matched = false;
                for (todos_buf[0..todo_count]) |todo| {
                    if (!std.mem.eql(u8, todo.content, issue.title)) continue;
                    matched = true;
                    const status = parseStatusDisplay(issue.status) orelse return false;
                    const expected_status: Status = if (std.mem.eql(u8, todo.status, "in_progress")) .active else .open;
                    if (status != expected_status) return false;
                    if (!std.mem.eql(u8, issue.description orelse "", todo.activeForm)) return false;
                }
                if (!matched) return false;
            }

            var mapping = loadMappingFile(allocator, test_dir);
            defer {
                mapping_util.deinit(allocator, &mapping);
            }
            if (mapping.map.count() != todo_count) return false;

            var completed_buf: [max_hook_todos]bool = [_]bool{false} ** max_hook_todos;
            for (0..todo_count) |i| {
                completed_buf[i] = random.boolean();
            }

            var todos2_buf: [max_hook_todos]HookTodo = undefined;
            for (0..todo_count) |i| {
                const status = if (completed_buf[i]) "completed" else todos_buf[i].status;
                todos2_buf[i] = .{ .content = todos_buf[i].content, .status = status, .activeForm = todos_buf[i].activeForm };
            }

            const input2 = buildTodoWriteJson(allocator, todos2_buf[0..todo_count]);
            const hook2 = runDotWithInput(allocator, &.{ "hook", "sync" }, test_dir, input2) catch |err| {
                std.debug.panic("hook sync 2: {}", .{err});
            };
            defer allocator.free(hook2.stdout);
            defer allocator.free(hook2.stderr);
            if (!isExitCode(hook2.term, 0)) return false;

            const list_open = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
                std.debug.panic("list open: {}", .{err});
            };
            defer allocator.free(list_open.stdout);
            defer allocator.free(list_open.stderr);
            const parsed_open = std.json.parseFromSlice([]JsonIssue, allocator, list_open.stdout, .{}) catch |err| {
                std.debug.panic("parse open: {}", .{err});
            };
            defer parsed_open.deinit();

            const list_done = runDot(allocator, &.{ "ls", "--status", "done", "--json" }, test_dir) catch |err| {
                std.debug.panic("list done: {}", .{err});
            };
            defer allocator.free(list_done.stdout);
            defer allocator.free(list_done.stderr);
            const parsed_done = std.json.parseFromSlice([]JsonIssue, allocator, list_done.stdout, .{}) catch |err| {
                std.debug.panic("parse done: {}", .{err});
            };
            defer parsed_done.deinit();

            var open_expected: usize = 0;
            var done_expected: usize = 0;
            for (0..todo_count) |i| {
                if (completed_buf[i]) done_expected += 1 else open_expected += 1;
            }
            if (parsed_open.value.len != open_expected) return false;
            if (parsed_done.value.len != done_expected) return false;

            for (parsed_done.value) |issue| {
                if (parseStatusDisplay(issue.status) != .closed) return false;
            }

            var mapping2 = loadMappingFile(allocator, test_dir);
            defer {
                mapping_util.deinit(allocator, &mapping2);
            }

            if (mapping2.map.count() != open_expected) return false;
            for (0..todo_count) |i| {
                const content = todos_buf[i].content;
                if (completed_buf[i]) {
                    if (mapping2.map.contains(content)) return false;
                } else {
                    if (!mapping2.map.contains(content)) return false;
                }
            }

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0xBEEFC0DE });
}

test "prop: hook sync status transitions match oracle" {
    const TransitionCase = struct {
        seed: u64,
        initial_status: bool, // true = in_progress, false = pending
    };

    try qc.check(struct {
        fn property(args: TransitionCase) bool {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            const initial_status: []const u8 = if (args.initial_status) "in_progress" else "pending";
            const expected_db_status: Status = if (args.initial_status) .active else .open;

            // Create initial todo
            const todos1 = [_]HookTodo{.{
                .content = "transition test",
                .status = initial_status,
                .activeForm = "Testing transitions",
            }};

            const input1 = buildTodoWriteJson(allocator, &todos1);
            const hook1 = runDotWithInput(allocator, &.{ "hook", "sync" }, test_dir, input1) catch |err| {
                std.debug.panic("hook sync 1: {}", .{err});
            };
            defer allocator.free(hook1.stdout);
            defer allocator.free(hook1.stderr);
            if (!isExitCode(hook1.term, 0)) return false;

            // Verify initial status
            const list1 = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
                std.debug.panic("list 1: {}", .{err});
            };
            defer allocator.free(list1.stdout);
            defer allocator.free(list1.stderr);

            const parsed1 = std.json.parseFromSlice([]JsonIssue, allocator, list1.stdout, .{}) catch |err| {
                std.debug.panic("parse 1: {}", .{err});
            };
            defer parsed1.deinit();
            if (parsed1.value.len != 1) return false;
            const status1 = parseStatusDisplay(parsed1.value[0].status) orelse return false;
            if (status1 != expected_db_status) return false;

            // Transition to opposite status
            const new_status: []const u8 = if (args.initial_status) "pending" else "in_progress";
            const expected_new_db_status: Status = if (args.initial_status) .open else .active;

            const todos2 = [_]HookTodo{.{
                .content = "transition test",
                .status = new_status,
                .activeForm = "Testing transitions",
            }};

            const input2 = buildTodoWriteJson(allocator, &todos2);
            const hook2 = runDotWithInput(allocator, &.{ "hook", "sync" }, test_dir, input2) catch |err| {
                std.debug.panic("hook sync 2: {}", .{err});
            };
            defer allocator.free(hook2.stdout);
            defer allocator.free(hook2.stderr);
            if (!isExitCode(hook2.term, 0)) return false;

            // Verify status changed
            const list2 = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
                std.debug.panic("list 2: {}", .{err});
            };
            defer allocator.free(list2.stdout);
            defer allocator.free(list2.stderr);

            const parsed2 = std.json.parseFromSlice([]JsonIssue, allocator, list2.stdout, .{}) catch |err| {
                std.debug.panic("parse 2: {}", .{err});
            };
            defer parsed2.deinit();
            if (parsed2.value.len != 1) return false;
            const status2 = parseStatusDisplay(parsed2.value[0].status) orelse return false;
            if (status2 != expected_new_db_status) return false;

            // Should still be only 1 issue (no duplicates)
            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0x7A551F });
}

test "prop: hook sync idempotent for same content" {
    const IdempotentCase = struct {
        seed: u64,
        sync_count: u8,
    };

    try qc.check(struct {
        fn property(args: IdempotentCase) bool {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            const todos = [_]HookTodo{.{
                .content = "idempotent test",
                .status = "pending",
                .activeForm = "Testing idempotency",
            }};

            const input = buildTodoWriteJson(allocator, &todos);
            const sync_count: usize = @as(usize, args.sync_count % 5) + 2;

            // Sync multiple times with same content
            for (0..sync_count) |_| {
                const hook = runDotWithInput(allocator, &.{ "hook", "sync" }, test_dir, input) catch |err| {
                    std.debug.panic("hook sync: {}", .{err});
                };
                defer allocator.free(hook.stdout);
                defer allocator.free(hook.stderr);
                if (!isExitCode(hook.term, 0)) return false;
            }

            // Should still have exactly 1 issue
            const list = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch |err| {
                std.debug.panic("list: {}", .{err});
            };
            defer allocator.free(list.stdout);
            defer allocator.free(list.stderr);

            const parsed = std.json.parseFromSlice([]JsonIssue, allocator, list.stdout, .{}) catch |err| {
                std.debug.panic("parse: {}", .{err});
            };
            defer parsed.deinit();
            if (parsed.value.len != 1) return false;

            // Mapping should have exactly 1 entry
            var mapping = loadMappingFile(allocator, test_dir);
            defer mapping_util.deinit(allocator, &mapping);
            if (mapping.map.count() != 1) return false;

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0x1DE4707 });
}

const JsonDependency = struct {
    depends_on_id: []const u8,
    type: []const u8,
};

const JsonIssueInput = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: []const u8,
    priority: i64,
    issue_type: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    closed_at: ?[]const u8,
    close_reason: ?[]const u8,
    dependencies: ?[]const JsonDependency,
};

fn writeJsonl(allocator: std.mem.Allocator, dir: []const u8, issues: []const JsonIssueInput) void {
    const beads_dir = std.fmt.allocPrint(allocator, "{s}/.beads", .{dir}) catch |err| {
        std.debug.panic("beads dir: {}", .{err});
    };
    defer allocator.free(beads_dir);
    fs.makeDirAbsolute(beads_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => std.debug.panic("beads mkdir: {}", .{err}),
    };

    const path = std.fmt.allocPrint(allocator, "{s}/.beads/issues.jsonl", .{dir}) catch |err| {
        std.debug.panic("jsonl path: {}", .{err});
    };
    defer allocator.free(path);

    const file = fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.panic("jsonl create: {}", .{err});
    };
    defer file.close();

    for (issues) |issue| {
        const line = std.json.Stringify.valueAlloc(allocator, issue, .{}) catch |err| {
            std.debug.panic("jsonl stringify: {}", .{err});
        };
        defer allocator.free(line);
        file.writeAll(line) catch |err| {
            std.debug.panic("jsonl write: {}", .{err});
        };
        file.writeAll("\n") catch |err| {
            std.debug.panic("jsonl newline: {}", .{err});
        };
    }
    file.sync() catch |err| {
        std.debug.panic("jsonl sync: {}", .{err});
    };
}

test "prop: hydrate JSONL matches oracle" {
    const HydrateCase = struct {
        seed: u64,
    };

    try qc.check(struct {
        fn property(args: HydrateCase) bool {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var prng = std.Random.DefaultPrng.init(args.seed);
            const random = prng.random();

            var statuses: [max_hydrate_issues]Status = undefined;
            for (0..max_hydrate_issues) |i| {
                statuses[i] = @as(Status, @enumFromInt(random.uintLessThan(u2, 3)));
            }

            var deps: [max_hydrate_issues][max_hydrate_issues]bool = undefined;
            for (0..max_hydrate_issues) |i| {
                for (0..max_hydrate_issues) |j| {
                    deps[i][j] = (j < i) and random.boolean();
                }
            }

            var parents: [max_hydrate_issues]?usize = [_]?usize{null} ** max_hydrate_issues;
            for (0..max_hydrate_issues) |i| {
                if (i > 0 and random.boolean()) {
                    const parent_idx = random.uintLessThan(usize, i);
                    parents[i] = parent_idx;
                }
            }
            var has_conflict = false;
            for (0..max_hydrate_issues) |i| {
                if (parents[i]) |parent_idx| {
                    if (deps[i][parent_idx]) {
                        has_conflict = true;
                        break;
                    }
                }
            }

            var issues_buf: [max_hydrate_issues]JsonIssueInput = undefined;
            for (0..max_hydrate_issues) |i| {
                var dep_len: usize = 0;
                for (0..max_hydrate_issues) |j| {
                    if (deps[i][j]) {
                        dep_len += 1;
                    }
                }
                if (parents[i] != null) {
                    dep_len += 1;
                }

                var dep_slice: ?[]const JsonDependency = null;
                if (dep_len > 0) {
                    const dep_list = allocator.alloc(JsonDependency, dep_len) catch |err| {
                        std.debug.panic("dep alloc: {}", .{err});
                    };
                    var dep_idx: usize = 0;
                    for (0..max_hydrate_issues) |j| {
                        if (deps[i][j]) {
                            dep_list[dep_idx] = .{
                                .depends_on_id = std.fmt.allocPrint(allocator, "h{d}", .{j}) catch |err| {
                                    std.debug.panic("dep id: {}", .{err});
                                },
                                .type = "blocks",
                            };
                            dep_idx += 1;
                        }
                    }
                    if (parents[i]) |parent_idx| {
                        dep_list[dep_idx] = .{
                            .depends_on_id = std.fmt.allocPrint(allocator, "h{d}", .{parent_idx}) catch |err| {
                                std.debug.panic("parent id: {}", .{err});
                            },
                            .type = "parent-child",
                        };
                        dep_idx += 1;
                    }
                    dep_slice = dep_list[0..dep_idx];
                }

                const status_raw = switch (statuses[i]) {
                    .open => "open",
                    .active => "in_progress",
                    .closed => "closed",
                };
                const closed_at: ?[]const u8 = if (statuses[i] == .closed) fixed_timestamp else null;

                issues_buf[i] = .{
                    .id = std.fmt.allocPrint(allocator, "h{d}", .{i}) catch |err| {
                        std.debug.panic("id: {}", .{err});
                    },
                    .title = std.fmt.allocPrint(allocator, "Hydrate {d}", .{i}) catch |err| {
                        std.debug.panic("title: {}", .{err});
                    },
                    .description = "",
                    .status = status_raw,
                    .priority = 2,
                    .issue_type = "task",
                    .created_at = fixed_timestamp,
                    .updated_at = fixed_timestamp,
                    .closed_at = closed_at,
                    .close_reason = null,
                    .dependencies = dep_slice,
                };
            }

            writeJsonl(allocator, test_dir, issues_buf[0..max_hydrate_issues]);

            const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
                std.debug.panic("init: {}", .{err});
            };
            defer allocator.free(init.stdout);
            defer allocator.free(init.stderr);
            if (has_conflict) {
                if (!isExitCode(init.term, 1)) return false;
                if (std.mem.indexOf(u8, init.stderr, "Invalid dependency at") == null) return false;
                return true;
            }
            if (!isExitCode(init.term, 0)) return false;

            const ready = runDot(allocator, &.{ "ready", "--json" }, test_dir) catch |err| {
                std.debug.panic("ready: {}", .{err});
            };
            defer allocator.free(ready.stdout);
            defer allocator.free(ready.stderr);

            var model = Model.init();
            for (0..max_hydrate_issues) |i| {
                const id = std.fmt.allocPrint(allocator, "h{d}", .{i}) catch |err| {
                    std.debug.panic("model id: {}", .{err});
                };
                model.tasks[i] = .{
                    .id = id,
                    .title = std.fmt.allocPrint(allocator, "Hydrate {d}", .{i}) catch |err| {
                        std.debug.panic("model title: {}", .{err});
                    },
                    .description = "",
                    .status = statuses[i],
                    .priority = 2,
                    .order = i,
                };
                model.parents[i] = parents[i];
                for (0..max_hydrate_issues) |j| {
                    model.deps[i][j] = deps[i][j];
                }
            }

            if (!readyJsonMatches(allocator, &model, ready.stdout)) {
                return false;
            }

            const tree = runDot(allocator, &.{"tree"}, test_dir) catch |err| {
                std.debug.panic("tree: {}", .{err});
            };
            defer allocator.free(tree.stdout);
            defer allocator.free(tree.stderr);
            if (!treeTextMatches(&model, tree.stdout)) {
                return false;
            }

            const list_done = runDot(allocator, &.{ "ls", "--status", "done", "--json" }, test_dir) catch |err| {
                std.debug.panic("list done: {}", .{err});
            };
            defer allocator.free(list_done.stdout);
            defer allocator.free(list_done.stderr);
            const parsed_done = std.json.parseFromSlice([]JsonIssue, allocator, list_done.stdout, .{}) catch |err| {
                std.debug.panic("parse done: {}", .{err});
            };
            defer parsed_done.deinit();
            var expected_closed: usize = 0;
            for (statuses) |status| {
                if (status == .closed) expected_closed += 1;
            }
            if (parsed_done.value.len != expected_closed) {
                return false;
            }

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0xC0DECAFE });
}
