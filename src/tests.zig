const std = @import("std");
const fs = std.fs;

const build_options = @import("build_options");
const dot_binary = build_options.dot_binary;

const storage_mod = @import("storage.zig");
const zc = @import("zcheck");
const OhSnap = @import("ohsnap");

const max_output_bytes = 1024 * 1024;
const fixed_timestamp = "2024-01-01T00:00:00.000000+00:00";

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const Status = storage_mod.Status;
const Issue = storage_mod.Issue;
const Storage = storage_mod.Storage;

fn isBlocking(status: Status) bool {
    return status == .open or status == .active;
}

fn oracleReady(statuses: [4]Status, deps: [4][4]bool) [4]bool {
    // Simulate insertion order and detect transitive cycles
    var effective_deps = [_][4]bool{[_]bool{false} ** 4} ** 4;

    // Insert dependencies in order, skip if would create cycle
    for (0..4) |i| {
        for (0..4) |j| {
            if (deps[i][j]) {
                // Check if j can reach i (would create cycle)
                if (!canReach(effective_deps, j, i)) {
                    effective_deps[i][j] = true;
                }
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

// Check if 'from' can reach 'to' via transitive dependencies
fn canReach(deps: [4][4]bool, from: usize, to: usize) bool {
    var visited = [_]bool{false} ** 4;
    return canReachDfs(deps, from, to, &visited);
}

fn canReachDfs(deps: [4][4]bool, current: usize, target: usize, visited: *[4]bool) bool {
    if (current == target) return true;
    if (visited[current]) return false;
    visited[current] = true;

    for (0..4) |j| {
        if (deps[current][j] and canReachDfs(deps, j, target, visited)) {
            return true;
        }
    }
    return false;
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
    var argv: std.ArrayList([]const u8) = .{};
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
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, max_output_bytes);
    errdefer allocator.free(stderr);
    const term = try child.wait();

    return RunResult{ .stdout = stdout, .stderr = stderr, .term = term };
}

/// Multi-process test harness for concurrent operations
const MultiProcess = struct {
    const MAX_PROCS = 8;
    const MAX_ARGS = 8;

    allocator: std.mem.Allocator,
    cwd: []const u8,
    children: [MAX_PROCS]std.process.Child = undefined,
    argv_storage: [MAX_PROCS][MAX_ARGS][]const u8 = undefined,
    argv_lens: [MAX_PROCS]usize = [_]usize{0} ** MAX_PROCS,
    inputs: [MAX_PROCS]?[]const u8 = [_]?[]const u8{null} ** MAX_PROCS,
    count: usize = 0,

    fn init(allocator: std.mem.Allocator, cwd: []const u8) MultiProcess {
        return .{ .allocator = allocator, .cwd = cwd };
    }

    /// Add a process to spawn with given args and optional stdin
    fn add(self: *MultiProcess, args: []const []const u8, input: ?[]const u8) !void {
        if (self.count >= MAX_PROCS) return error.TooManyProcesses;
        if (args.len + 1 > MAX_ARGS) return error.TooManyArgs;

        // Store args in fixed storage
        self.argv_storage[self.count][0] = dot_binary;
        for (args, 0..) |arg, i| {
            self.argv_storage[self.count][i + 1] = arg;
        }
        self.argv_lens[self.count] = args.len + 1;
        self.inputs[self.count] = input;
        self.count += 1;
    }

    /// Spawn all processes concurrently
    fn spawnAll(self: *MultiProcess) !void {
        for (0..self.count) |i| {
            const argv = self.argv_storage[i][0..self.argv_lens[i]];
            self.children[i] = std.process.Child.init(argv, self.allocator);
            self.children[i].cwd = self.cwd;
            self.children[i].stdin_behavior = if (self.inputs[i] != null) .Pipe else .Ignore;
            self.children[i].stdout_behavior = .Pipe;
            self.children[i].stderr_behavior = .Pipe;

            try self.children[i].spawn();
            if (self.inputs[i]) |data| {
                try self.children[i].stdin.?.writeAll(data);
                self.children[i].stdin.?.close();
                self.children[i].stdin = null;
            }
        }
    }

    /// Wait for all processes and return results
    fn waitAll(self: *MultiProcess) ![MAX_PROCS]?RunResult {
        var results: [MAX_PROCS]?RunResult = [_]?RunResult{null} ** MAX_PROCS;
        errdefer self.freeResults(&results);
        for (0..self.count) |i| {
            const stdout = try self.children[i].stdout.?.readToEndAlloc(self.allocator, max_output_bytes);
            errdefer self.allocator.free(stdout);
            const stderr = try self.children[i].stderr.?.readToEndAlloc(self.allocator, max_output_bytes);
            errdefer self.allocator.free(stderr);
            const term = try self.children[i].wait();
            results[i] = .{ .stdout = stdout, .stderr = stderr, .term = term };
        }
        return results;
    }

    /// Check if all processes succeeded (exit code 0)
    fn allSucceeded(results: [MAX_PROCS]?RunResult, count: usize) bool {
        for (0..count) |i| {
            if (results[i]) |r| {
                if (!isExitCode(r.term, 0)) return false;
            }
        }
        return true;
    }

    /// Free all result memory
    fn freeResults(self: *MultiProcess, results: *[MAX_PROCS]?RunResult) void {
        for (0..self.count) |i| {
            if (results[i]) |r| {
                self.allocator.free(r.stdout);
                self.allocator.free(r.stderr);
                results[i] = null;
            }
        }
    }
};

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

// Helper to open storage in a test directory
// Returns the storage and original directory for cleanup
const TestStorage = struct {
    storage: Storage,
    original_dir: fs.Dir,
    test_dir_path: []const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, test_dir: []const u8) !TestStorage {
        const original_dir = fs.cwd();

        // Change to test directory
        var dir = try fs.openDirAbsolute(test_dir, .{});
        defer dir.close(); // Close after setAsCwd - we don't need to keep it open
        try dir.setAsCwd();

        // Open storage (creates .dots in test dir)
        const storage = Storage.open(allocator) catch |err| {
            // Restore original directory on error
            original_dir.setAsCwd() catch {};
            return err;
        };

        return TestStorage{
            .storage = storage,
            .original_dir = original_dir,
            .test_dir_path = test_dir,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestStorage) void {
        self.storage.close();
        self.original_dir.setAsCwd() catch {};
    }
};

fn openTestStorage(allocator: std.mem.Allocator, dir: []const u8) TestStorage {
    return TestStorage.init(allocator, dir) catch |err| {
        std.debug.panic("open storage: {}", .{err});
    };
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

fn makeTestIssue(id: []const u8, status: Status) Issue {
    return Issue{
        .id = id,
        .title = id,
        .description = "",
        .status = status,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = fixed_timestamp,
        .closed_at = if (status == .closed) fixed_timestamp else null,
        .close_reason = null,
        .blocks = &.{},
        .parent = null,
    };
}

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

const JsonIssue = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: i64,
};

test "cli: hook command is rejected" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    _ = runDot(allocator, &.{"init"}, test_dir) catch unreachable;

    const result = runDot(allocator, &.{"hook"}, test_dir) catch unreachable;
    defer result.deinit(allocator);

    try std.testing.expect(!isExitCode(result.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Unknown command: hook") != null);
}

test "cli: init creates dots directory" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const result = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(isExitCode(result.term, 0));

    // Verify .dots directory exists
    const dots_path = std.fmt.allocPrint(allocator, "{s}/.dots", .{test_dir}) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(dots_path);

    const stat = fs.cwd().statFile(dots_path) catch |err| {
        std.debug.panic("stat: {}", .{err});
    };
    try std.testing.expect(stat.kind == .directory);
}

test "cli: add creates markdown file" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    const result = runDot(allocator, &.{ "add", "Test task" }, test_dir) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer result.deinit(allocator);

    try std.testing.expect(isExitCode(result.term, 0));

    const id = trimNewline(result.stdout);
    try std.testing.expect(id.len > 0);

    // Verify markdown file exists
    const md_path = std.fmt.allocPrint(allocator, "{s}/.dots/{s}.md", .{ test_dir, id }) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(md_path);

    const stat = fs.cwd().statFile(md_path) catch |err| {
        std.debug.panic("stat: {}", .{err});
    };
    try std.testing.expect(stat.kind == .file);
}

test "cli: purge removes archived dots" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add and close an issue to archive it
    const add = runDot(allocator, &.{ "add", "To archive" }, test_dir) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    const id = trimNewline(add.stdout);

    const off = runDot(allocator, &.{ "off", id }, test_dir) catch |err| {
        std.debug.panic("off: {}", .{err});
    };
    defer off.deinit(allocator);

    // Verify archive has content
    const archive_path = std.fmt.allocPrint(allocator, "{s}/.dots/archive", .{test_dir}) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(archive_path);

    var archive_dir = fs.cwd().openDir(archive_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("open archive: {}", .{err});
    };
    defer archive_dir.close();

    var count: usize = 0;
    var iter = archive_dir.iterate();
    while (try iter.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count > 0);

    // Purge
    const purge = runDot(allocator, &.{"purge"}, test_dir) catch |err| {
        std.debug.panic("purge: {}", .{err});
    };
    defer purge.deinit(allocator);

    try std.testing.expect(isExitCode(purge.term, 0));

    // Verify archive is empty
    var archive_dir2 = fs.cwd().openDir(archive_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("open archive2: {}", .{err});
    };
    defer archive_dir2.close();

    var count2: usize = 0;
    var iter2 = archive_dir2.iterate();
    while (try iter2.next()) |_| {
        count2 += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), count2);
}

test "cli: parent creates folder structure" {
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

    // Add child
    const child = runDot(allocator, &.{ "add", "Child task", "-P", parent_id }, test_dir) catch |err| {
        std.debug.panic("add child: {}", .{err});
    };
    defer child.deinit(allocator);

    // Verify folder structure
    const folder_path = std.fmt.allocPrint(allocator, "{s}/.dots/{s}", .{ test_dir, parent_id }) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(folder_path);

    const stat = fs.cwd().statFile(folder_path) catch |err| {
        std.debug.panic("stat: {}", .{err});
    };
    try std.testing.expect(stat.kind == .directory);
}

test "cli: find matches titles case-insensitively" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    const add1 = runDot(allocator, &.{ "add", "Fix Bug" }, test_dir) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);

    const add2 = runDot(allocator, &.{ "add", "Write docs" }, test_dir) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);

    const add3 = runDot(allocator, &.{ "add", "BUG report" }, test_dir) catch |err| {
        std.debug.panic("add3: {}", .{err});
    };
    defer add3.deinit(allocator);

    const result = runDot(allocator, &.{ "find", "bug" }, test_dir) catch |err| {
        std.debug.panic("find: {}", .{err});
    };
    defer result.deinit(allocator);

    try std.testing.expect(isExitCode(result.term, 0));

    var matches: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "Bug") != null or std.mem.indexOf(u8, line, "BUG") != null) {
            matches += 1;
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), matches);
}

test "cli: jsonl hydration imports issues and archives closed" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const jsonl_path = try std.fmt.allocPrint(allocator, "{s}/import.jsonl", .{test_dir});
    defer allocator.free(jsonl_path);

    const JsonlDependency = struct {
        depends_on_id: []const u8,
        type: ?[]const u8 = null,
    };

    const JsonlIssue = struct {
        id: []const u8,
        title: []const u8,
        description: ?[]const u8 = null,
        status: []const u8,
        priority: i64,
        issue_type: []const u8,
        assignee: ?[]const u8 = null,
        created_at: []const u8,
        updated_at: ?[]const u8 = null,
        closed_at: ?[]const u8 = null,
        close_reason: ?[]const u8 = null,
        dependencies: ?[]const JsonlDependency = null,
    };

    const issues = [_]JsonlIssue{
        .{
            .id = "parent",
            .title = "Parent",
            .status = "open",
            .priority = 1,
            .issue_type = "task",
            .created_at = fixed_timestamp,
        },
        .{
            .id = "child",
            .title = "Child",
            .status = "open",
            .priority = 2,
            .issue_type = "task",
            .created_at = fixed_timestamp,
            .dependencies = &.{.{ .depends_on_id = "parent", .type = "parent-child" }},
        },
        .{
            .id = "blocker",
            .title = "Blocker",
            .status = "open",
            .priority = 2,
            .issue_type = "task",
            .created_at = fixed_timestamp,
        },
        .{
            .id = "blocked",
            .title = "Blocked",
            .status = "open",
            .priority = 3,
            .issue_type = "task",
            .created_at = fixed_timestamp,
            .dependencies = &.{.{ .depends_on_id = "blocker", .type = "blocks" }},
        },
        .{
            .id = "closed",
            .title = "Closed",
            .status = "done",
            .priority = 1,
            .issue_type = "task",
            .created_at = fixed_timestamp,
            .closed_at = fixed_timestamp,
        },
    };

    const file = try fs.createFileAbsolute(jsonl_path, .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    const w = &writer.interface;
    for (issues) |issue| {
        try std.json.Stringify.value(issue, .{}, w);
        try w.writeByte('\n');
    }
    try w.flush();
    try file.sync();

    const init = runDot(allocator, &.{ "init", "--from-jsonl", jsonl_path }, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);
    try std.testing.expect(isExitCode(init.term, 0));

    var ts = openTestStorage(allocator, test_dir);
    defer ts.deinit();

    const parent = ts.storage.getIssue("parent") catch |err| {
        std.debug.panic("parent: {}", .{err});
    };
    defer parent.?.deinit(allocator);
    try std.testing.expect(parent != null);

    const child = ts.storage.getIssue("child") catch |err| {
        std.debug.panic("child: {}", .{err});
    };
    defer child.?.deinit(allocator);
    try std.testing.expect(child != null);
    try std.testing.expectEqualStrings("parent", child.?.parent.?);

    const blocked = ts.storage.getIssue("blocked") catch |err| {
        std.debug.panic("blocked: {}", .{err});
    };
    defer blocked.?.deinit(allocator);
    try std.testing.expect(blocked != null);
    try std.testing.expectEqual(@as(usize, 1), blocked.?.blocks.len);
    try std.testing.expectEqualStrings("blocker", blocked.?.blocks[0]);

    const closed = ts.storage.getIssue("closed") catch |err| {
        std.debug.panic("closed: {}", .{err});
    };
    defer closed.?.deinit(allocator);
    try std.testing.expect(closed != null);
    try std.testing.expectEqual(Status.closed, closed.?.status);

    const closed_list = ts.storage.listIssues(.closed) catch |err| {
        std.debug.panic("list: {}", .{err});
    };
    defer storage_mod.freeIssues(allocator, closed_list);
    try std.testing.expectEqual(@as(usize, 0), closed_list.len);
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

// =============================================================================
// Comprehensive Property Tests
// =============================================================================

// Oracle for full lifecycle: tracks expected state after a sequence of operations
const LifecycleOracle = struct {
    const MAX_ISSUES = 8;

    // Issue state
    exists: [MAX_ISSUES]bool = [_]bool{false} ** MAX_ISSUES,
    statuses: [MAX_ISSUES]Status = [_]Status{.open} ** MAX_ISSUES,
    priorities: [MAX_ISSUES]u3 = [_]u3{2} ** MAX_ISSUES,
    has_closed_at: [MAX_ISSUES]bool = [_]bool{false} ** MAX_ISSUES,
    archived: [MAX_ISSUES]bool = [_]bool{false} ** MAX_ISSUES, // Closed root issues get archived
    parents: [MAX_ISSUES]?usize = [_]?usize{null} ** MAX_ISSUES,
    // deps[i][j] = true means i depends on j (j blocks i)
    deps: [MAX_ISSUES][MAX_ISSUES]bool = [_][MAX_ISSUES]bool{[_]bool{false} ** MAX_ISSUES} ** MAX_ISSUES,

    fn create(self: *LifecycleOracle, idx: usize, priority: u3, parent: ?usize) void {
        self.exists[idx] = true;
        self.statuses[idx] = .open;
        self.priorities[idx] = priority;
        self.has_closed_at[idx] = false;
        self.archived[idx] = false;
        self.parents[idx] = parent;
    }

    fn delete(self: *LifecycleOracle, idx: usize) void {
        self.exists[idx] = false;
        self.archived[idx] = false;
        // Remove all dependencies involving this issue
        for (0..MAX_ISSUES) |i| {
            self.deps[idx][i] = false;
            self.deps[i][idx] = false;
        }
    }

    fn setStatus(self: *LifecycleOracle, idx: usize, status: Status) void {
        self.statuses[idx] = status;
        self.has_closed_at[idx] = (status == .closed);
        // Root issues (no parent) get archived when closed
        if (status == .closed and self.parents[idx] == null) {
            self.archived[idx] = true;
        } else if (status != .closed) {
            self.archived[idx] = false;
        }
    }

    fn canClose(self: *LifecycleOracle, idx: usize) bool {
        // Can't close if has open children
        for (0..MAX_ISSUES) |i| {
            if (self.exists[i] and self.parents[i] == idx) {
                if (self.statuses[i] != .closed) return false;
            }
        }
        return true;
    }

    fn addDep(self: *LifecycleOracle, from: usize, to: usize) bool {
        // Check for cycle
        if (self.wouldCreateCycle(from, to)) return false;
        self.deps[from][to] = true;
        return true;
    }

    fn wouldCreateCycle(self: *LifecycleOracle, from: usize, to: usize) bool {
        // Adding from->to would create cycle if to can reach from
        var visited = [_]bool{false} ** MAX_ISSUES;
        return self.canReachDfs(to, from, &visited);
    }

    fn canReachDfs(self: *LifecycleOracle, current: usize, target: usize, visited: *[MAX_ISSUES]bool) bool {
        if (current == target) return true;
        if (visited[current]) return false;
        visited[current] = true;
        for (0..MAX_ISSUES) |j| {
            if (self.deps[current][j] and self.canReachDfs(j, target, visited)) {
                return true;
            }
        }
        return false;
    }

    fn isBlocked(self: *LifecycleOracle, idx: usize) bool {
        for (0..MAX_ISSUES) |j| {
            if (self.deps[idx][j] and self.exists[j]) {
                if (self.statuses[j] == .open or self.statuses[j] == .active) {
                    return true;
                }
            }
        }
        return false;
    }

    fn isReady(self: *LifecycleOracle, idx: usize) bool {
        // Archived issues are not in ready list
        return self.exists[idx] and !self.archived[idx] and self.statuses[idx] == .open and !self.isBlocked(idx);
    }

    fn countByStatus(self: *LifecycleOracle, status: Status) usize {
        var count: usize = 0;
        for (0..MAX_ISSUES) |i| {
            // Archived issues are not in listIssues (only in archive dir)
            if (self.exists[i] and !self.archived[i] and self.statuses[i] == status) count += 1;
        }
        return count;
    }

    fn readyCount(self: *LifecycleOracle) usize {
        var count: usize = 0;
        for (0..MAX_ISSUES) |i| {
            if (self.isReady(i)) count += 1;
        }
        return count;
    }
};

// Operation types for lifecycle simulation
const OpType = enum { create, delete, set_open, set_active, set_closed, add_dep };

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

// Snapshot tests using ohsnap

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
        \\tests.test.snap: simple struct.TestStruct
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
    const child2 = runDot(allocator, &.{ "add", "Child two", "-P", parent_id }, test_dir) catch |err| {
        std.debug.panic("add child2: {}", .{err});
    };
    defer child2.deinit(allocator);

    // Get tree output
    const tree = runDot(allocator, &.{"tree"}, test_dir) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer tree.deinit(allocator);

    // Normalize: replace IDs with placeholders
    // Tree format: "[full-id] ○ Title" for parent, "  └─ [full-id] ○ Title" for children
    var normalized = std.ArrayList(u8){};
    defer normalized.deinit(allocator);

    var lines = std.mem.splitScalar(u8, tree.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Find "[" and "]" to replace ID
        if (std.mem.indexOf(u8, line, "[")) |start| {
            if (std.mem.indexOfPos(u8, line, start, "]")) |end| {
                // Prefix before [
                try normalized.appendSlice(allocator, line[0..start]);
                // Replace ID with placeholder
                try normalized.appendSlice(allocator, "[ID]");
                // Rest of line after ]
                try normalized.appendSlice(allocator, line[end + 1 ..]);
            } else {
                try normalized.appendSlice(allocator, line);
            }
        } else {
            try normalized.appendSlice(allocator, line);
        }
        try normalized.append(allocator, '\n');
    }

    const oh = OhSnap{};
    // Tree shows parent with children indented
    try oh.snap(@src(),
        \\[]u8
        \\  "[ID] ○ Parent task
        \\  └─ [ID] ○ Child one
        \\  └─ [ID] ○ Child two
        \\"
    ).expectEqual(normalized.items);
}

// ============================================================================
// Slugify tests
// ============================================================================

test "slugify: basic conversion" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};

    const slug = try storage_mod.slugify(allocator, "Fix User Authentication Bug");
    defer allocator.free(slug);

    try oh.snap(@src(),
        \\[]u8
        \\  "fix-user-auth"
    ).expectEqual(slug);
}

test "slugify: multiple abbreviations" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};

    const slug = try storage_mod.slugify(allocator, "Database Configuration Implementation");
    defer allocator.free(slug);

    try oh.snap(@src(),
        \\[]u8
        \\  "db-config-impl"
    ).expectEqual(slug);
}

test "slugify: empty title" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};

    const slug = try storage_mod.slugify(allocator, "");
    defer allocator.free(slug);

    try oh.snap(@src(),
        \\[]u8
        \\  "untitled"
    ).expectEqual(slug);
}

test "slugify: special characters stripped" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};

    const slug = try storage_mod.slugify(allocator, "Fix: API (v2) -- update!");
    defer allocator.free(slug);

    try oh.snap(@src(),
        \\[]u8
        \\  "fix-api-v2"
    ).expectEqual(slug);
}

test "slugify: truncation at word boundary" {
    const allocator = std.testing.allocator;

    // This should be truncated to fit within MAX_SLUG_LEN (32)
    const slug = try storage_mod.slugify(allocator, "Implement user authentication service with database connection pooling");
    defer allocator.free(slug);

    // Should truncate at word boundary
    try std.testing.expect(slug.len <= 32);
    try std.testing.expect(slug[slug.len - 1] != '-');
}

test "slugify: prop: output invariants" {
    // Use zcheck for property-based testing with shrinking
    try zc.check(struct {
        fn property(args: struct { title: zc.String }) bool {
            const allocator = std.testing.allocator;
            const title = args.title.slice();

            const slug = storage_mod.slugify(allocator, title) catch return false;
            defer allocator.free(slug);

            // Invariants:
            // 1. Never empty (returns "untitled" for empty input)
            if (slug.len == 0) return false;
            // 2. Never exceeds max length
            if (slug.len > 32) return false;
            // 3. Never ends with hyphen
            if (slug[slug.len - 1] == '-') return false;
            // 4. Only lowercase alphanumeric and hyphens
            for (slug) |c| {
                if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
            }
            return true;
        }
    }.property, .{ .iterations = 100, .seed = 42 });
}

test "slugify: prop: idempotent on valid slugs" {
    // Use zcheck for property-based testing with shrinking
    try zc.check(struct {
        fn property(args: struct { id: zc.Id }) bool {
            const allocator = std.testing.allocator;
            // zc.Id generates alphanumeric strings - valid slug input
            const input = args.id.slice();

            const slug1 = storage_mod.slugify(allocator, input) catch return false;
            defer allocator.free(slug1);
            const slug2 = storage_mod.slugify(allocator, slug1) catch return false;
            defer allocator.free(slug2);

            // Slugifying a valid slug should be idempotent
            return std.mem.eql(u8, slug1, slug2);
        }
    }.property, .{ .iterations = 50, .seed = 123 });
}

test "cli: slugify skips already-slugged issues from dot add" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    // Init
    const init = try runDot(allocator, &.{"init"}, test_dir);
    defer init.deinit(allocator);

    // Create an issue - dot add already creates slugified IDs
    const add = try runDot(allocator, &.{ "add", "Fix authentication bug" }, test_dir);
    defer add.deinit(allocator);

    // Get the created issue ID
    const ls1 = try runDot(allocator, &.{ "ls", "--json" }, test_dir);
    defer ls1.deinit(allocator);

    const parsed1 = try std.json.parseFromSlice([]JsonIssue, allocator, ls1.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer parsed1.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed1.value.len);
    const old_id = parsed1.value[0].id;

    // Verify the ID is already slugified (contains "fix-auth")
    try oh.snap(@src(),
        \\bool
        \\  true
    ).expectEqual(std.mem.indexOf(u8, old_id, "fix-auth") != null);

    // Slugify - should skip since already slugified
    const slugify = try runDot(allocator, &.{"slugify"}, test_dir);
    defer slugify.deinit(allocator);
    try std.testing.expect(isExitCode(slugify.term, 0));

    // Should report 0 slugified
    try oh.snap(@src(),
        \\bool
        \\  true
    ).expectEqual(std.mem.indexOf(u8, slugify.stdout, "Slugified 0") != null);

    // ID should be unchanged
    const ls2 = try runDot(allocator, &.{ "ls", "--json" }, test_dir);
    defer ls2.deinit(allocator);

    const parsed2 = try std.json.parseFromSlice([]JsonIssue, allocator, ls2.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer parsed2.deinit();

    try std.testing.expectEqualStrings(old_id, parsed2.value[0].id);
}

test "cli: slugify preserves hex suffix from original ID" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    // Create storage and set prefix to "dots"
    var ts = openTestStorage(allocator, test_dir);
    try ts.storage.setConfig("prefix", "dots");

    const issue = Issue{
        .id = "dots-abcd1234",
        .title = "Database migration",
        .description = "",
        .status = .open,
        .priority = 5,
        .issue_type = "task",
        .assignee = "",
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
    };
    try ts.storage.createIssue(issue, null);
    ts.deinit();

    // Slugify
    const slugify = try runDot(allocator, &.{"slugify"}, test_dir);
    defer slugify.deinit(allocator);
    try std.testing.expect(isExitCode(slugify.term, 0));

    // Verify new ID preserves hex suffix
    const ls = try runDot(allocator, &.{ "ls", "--json" }, test_dir);
    defer ls.deinit(allocator);

    const parsed = try std.json.parseFromSlice([]JsonIssue, allocator, ls.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    const new_id = parsed.value[0].id;

    // Should have slug and preserve hex suffix
    try std.testing.expectEqualStrings("dots-db-migration-abcd1234", new_id);
}

test "cli: slugify updates dependency references" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    try ts.storage.setConfig("prefix", "dots");

    // Create blocker issue
    const blocker = Issue{
        .id = "dots-11111111",
        .title = "API endpoint",
        .description = "",
        .status = .open,
        .priority = 5,
        .issue_type = "task",
        .assignee = "",
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
    };
    try ts.storage.createIssue(blocker, null);

    // Create dependent issue
    const dependent = Issue{
        .id = "dots-22222222",
        .title = "Frontend integration",
        .description = "",
        .status = .open,
        .priority = 5,
        .issue_type = "task",
        .assignee = "",
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
    };
    try ts.storage.createIssue(dependent, null);

    // Add dependency
    try ts.storage.addDependency("dots-22222222", "dots-11111111", "blocks");
    ts.deinit();

    // Slugify all
    const slugify = try runDot(allocator, &.{"slugify"}, test_dir);
    defer slugify.deinit(allocator);
    try std.testing.expect(isExitCode(slugify.term, 0));

    // Verify both were renamed (2 issues slugified)
    try std.testing.expect(std.mem.indexOf(u8, slugify.stdout, "Slugified 2") != null);

    // Re-open storage and list all issues to find the dependent
    var ts2 = openTestStorage(allocator, test_dir);
    defer ts2.deinit();

    const all_issues = try ts2.storage.listIssues(null);
    defer storage_mod.freeIssues(allocator, all_issues);

    // Find the dependent (ends with 22222222)
    var found_dep: ?Issue = null;
    for (all_issues) |iss| {
        if (std.mem.endsWith(u8, iss.id, "22222222")) {
            found_dep = iss;
            break;
        }
    }

    const updated_dep = found_dep orelse return error.TestUnexpectedResult;

    // Block should reference the new slugified ID
    try std.testing.expectEqual(@as(usize, 1), updated_dep.blocks.len);
    try std.testing.expectEqualStrings("dots-api-endpoint-11111111", updated_dep.blocks[0]);
}

test "cli: slugify skips already-slugified IDs" {
    const allocator = std.testing.allocator;
    const oh = OhSnap{};

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    try ts.storage.setConfig("prefix", "dots");

    // Create issue with already-slugified ID
    const issue = Issue{
        .id = "dots-fix-auth-bug-abcd1234",
        .title = "Fix authentication bug",
        .description = "",
        .status = .open,
        .priority = 5,
        .issue_type = "task",
        .assignee = "",
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
    };
    try ts.storage.createIssue(issue, null);
    ts.deinit();

    // Slugify - should skip
    const slugify = try runDot(allocator, &.{"slugify"}, test_dir);
    defer slugify.deinit(allocator);
    try std.testing.expect(isExitCode(slugify.term, 0));

    // Count should be 0
    try oh.snap(@src(),
        \\bool
        \\  true
    ).expectEqual(std.mem.indexOf(u8, slugify.stdout, "Slugified 0") != null);

    // ID should be unchanged
    const ls = try runDot(allocator, &.{ "ls", "--json" }, test_dir);
    defer ls.deinit(allocator);

    const parsed = try std.json.parseFromSlice([]JsonIssue, allocator, ls.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("dots-fix-auth-bug-abcd1234", parsed.value[0].id);
}

test "cli: slugify prop: preserves issue count" {
    try zc.check(struct {
        fn property(args: struct { count: u8 }) bool {
            const allocator = std.testing.allocator;
            const n = @min(args.count % 5, 4); // 0-4 issues

            const test_dir = setupTestDirOrPanic(allocator);
            defer cleanupTestDirAndFree(allocator, test_dir);

            var ts = openTestStorage(allocator, test_dir);
            ts.storage.setConfig("prefix", "dots") catch return false;

            var id_buf: [20]u8 = undefined;
            for (0..n) |i| {
                const id = std.fmt.bufPrint(&id_buf, "dots-{x:0>8}", .{@as(u32, @intCast(i)) + 0x10000000}) catch return false;
                const issue = makeTestIssue(id, .open);
                ts.storage.createIssue(issue, null) catch return false;
            }
            ts.deinit();

            const slugify = runDot(allocator, &.{"slugify"}, test_dir) catch return false;
            defer slugify.deinit(allocator);
            if (!isExitCode(slugify.term, 0)) return false;

            const ls = runDot(allocator, &.{ "ls", "--json" }, test_dir) catch return false;
            defer ls.deinit(allocator);

            const parsed = std.json.parseFromSlice([]JsonIssue, allocator, ls.stdout, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            defer parsed.deinit();

            // Issue count should be preserved
            return parsed.value.len == n;
        }
    }.property, .{ .iterations = 20, .seed = 0x5106 });
}

test "cli: slugify includes closed/archived issues" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);
    try ts.storage.setConfig("prefix", "dots");

    // Create open issue
    const open_issue = Issue{
        .id = "dots-11111111",
        .title = "Open task",
        .description = "",
        .status = .open,
        .priority = 5,
        .issue_type = "task",
        .assignee = "",
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
    };
    try ts.storage.createIssue(open_issue, null);

    // Create closed issue
    const closed_issue = Issue{
        .id = "dots-22222222",
        .title = "Closed task",
        .description = "",
        .status = .closed,
        .priority = 5,
        .issue_type = "task",
        .assignee = "",
        .created_at = fixed_timestamp,
        .closed_at = fixed_timestamp,
        .close_reason = "done",
        .blocks = &.{},
    };
    try ts.storage.createIssue(closed_issue, null);
    ts.deinit();

    // Slugify all
    const slugify = try runDot(allocator, &.{"slugify"}, test_dir);
    defer slugify.deinit(allocator);
    try std.testing.expect(isExitCode(slugify.term, 0));

    // Both should be slugified (open and closed)
    try std.testing.expect(std.mem.indexOf(u8, slugify.stdout, "Slugified 2") != null);

    // Verify both were renamed (check output contains both new IDs)
    try std.testing.expect(std.mem.indexOf(u8, slugify.stdout, "open-task") != null);
    try std.testing.expect(std.mem.indexOf(u8, slugify.stdout, "closed-task") != null);
}
