const std = @import("std");
const fs = std.fs;

const build_options = @import("build_options");
pub const dot_binary = build_options.dot_binary;

pub const storage_mod = @import("storage.zig");
pub const zc = @import("zcheck");
pub const OhSnap = @import("ohsnap");

pub const max_output_bytes = 1024 * 1024;
pub const fixed_timestamp = "2024-01-01T00:00:00.000000+00:00";

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const Status = storage_mod.Status;
pub const Issue = storage_mod.Issue;
pub const Storage = storage_mod.Storage;

pub fn isBlocking(status: Status) bool {
    return status == .open or status == .active;
}

pub fn oracleReady(statuses: [4]Status, deps: [4][4]bool) [4]bool {
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
pub fn canReach(deps: [4][4]bool, from: usize, to: usize) bool {
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

pub fn oracleListCount(statuses: [6]Status, filter: Status) usize {
    var count: usize = 0;
    for (statuses) |status| {
        if (status == filter) count += 1;
    }
    return count;
}

pub fn oracleChildBlocked(child_blocks: [3][3]bool, blocker_statuses: [3]Status) [3]bool {
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

pub fn oracleUpdateClosed(done: bool) bool {
    return done;
}

pub fn runDot(allocator: std.mem.Allocator, args: []const []const u8, cwd: []const u8) !RunResult {
    return runDotWithInput(allocator, args, cwd, null);
}

pub fn runDotWithInput(
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
pub const MultiProcess = struct {
    const MAX_PROCS = 8;
    const MAX_ARGS = 8;

    allocator: std.mem.Allocator,
    cwd: []const u8,
    children: [MAX_PROCS]std.process.Child = undefined,
    argv_storage: [MAX_PROCS][MAX_ARGS][]const u8 = undefined,
    argv_lens: [MAX_PROCS]usize = [_]usize{0} ** MAX_PROCS,
    inputs: [MAX_PROCS]?[]const u8 = [_]?[]const u8{null} ** MAX_PROCS,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cwd: []const u8) MultiProcess {
        return .{ .allocator = allocator, .cwd = cwd };
    }

    /// Add a process to spawn with given args and optional stdin
    pub fn add(self: *MultiProcess, args: []const []const u8, input: ?[]const u8) !void {
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
    pub fn spawnAll(self: *MultiProcess) !void {
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
    pub fn waitAll(self: *MultiProcess) ![MAX_PROCS]?RunResult {
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
    pub fn allSucceeded(results: [MAX_PROCS]?RunResult, count: usize) bool {
        for (0..count) |i| {
            if (results[i]) |r| {
                if (!isExitCode(r.term, 0)) return false;
            }
        }
        return true;
    }

    /// Free all result memory
    pub fn freeResults(self: *MultiProcess, results: *[MAX_PROCS]?RunResult) void {
        for (0..self.count) |i| {
            if (results[i]) |r| {
                self.allocator.free(r.stdout);
                self.allocator.free(r.stderr);
                results[i] = null;
            }
        }
    }
};

pub fn setupTestDir(allocator: std.mem.Allocator) ![]const u8 {
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const path = try std.fmt.allocPrint(allocator, "/tmp/dots-test-{s}", .{hex});

    try fs.makeDirAbsolute(path);
    return path;
}

pub fn cleanupTestDir(path: []const u8) !void {
    try fs.cwd().deleteTree(path);
}

pub fn cleanupTestDirOrPanic(path: []const u8) void {
    cleanupTestDir(path) catch |err| {
        std.debug.print("cleanup failed: {}\n", .{err});
        @panic("cleanup failed");
    };
}

pub fn setupTestDirOrPanic(allocator: std.mem.Allocator) []const u8 {
    return setupTestDir(allocator) catch |err| {
        std.debug.panic("setup: {}", .{err});
    };
}

pub fn cleanupTestDirAndFree(allocator: std.mem.Allocator, path: []const u8) void {
    cleanupTestDirOrPanic(path);
    allocator.free(path);
}

// Helper to open storage in a test directory
// Returns the storage and original directory for cleanup
pub const TestStorage = struct {
    storage: Storage,
    original_dir: fs.Dir,
    test_dir_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, test_dir: []const u8) !TestStorage {
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

    pub fn deinit(self: *TestStorage) void {
        self.storage.close();
        self.original_dir.setAsCwd() catch {};
    }
};

pub fn openTestStorage(allocator: std.mem.Allocator, dir: []const u8) TestStorage {
    return TestStorage.init(allocator, dir) catch |err| {
        std.debug.panic("open storage: {}", .{err});
    };
}

pub fn trimNewline(input: []const u8) []const u8 {
    return std.mem.trimRight(u8, input, "\n");
}

pub fn normalizeTreeOutput(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    var normalized = std.ArrayList(u8){};
    errdefer normalized.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.indexOf(u8, line, "[")) |start| {
            if (std.mem.indexOfPos(u8, line, start, "]")) |end| {
                try normalized.appendSlice(allocator, line[0..start]);
                try normalized.appendSlice(allocator, "[ID]");
                try normalized.appendSlice(allocator, line[end + 1 ..]);
            } else {
                try normalized.appendSlice(allocator, line);
            }
        } else {
            try normalized.appendSlice(allocator, line);
        }
        try normalized.append(allocator, '\n');
    }

    return normalized.toOwnedSlice(allocator);
}

pub fn isExitCode(term: std.process.Child.Term, code: u8) bool {
    return switch (term) {
        .Exited => |actual| actual == code,
        else => false,
    };
}

pub fn makeTestIssue(id: []const u8, status: Status) Issue {
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

// Oracle for full lifecycle: tracks expected state after a sequence of operations
pub const LifecycleOracle = struct {
    pub const MAX_ISSUES = 8;

    // Issue state
    exists: [MAX_ISSUES]bool = [_]bool{false} ** MAX_ISSUES,
    statuses: [MAX_ISSUES]Status = [_]Status{.open} ** MAX_ISSUES,
    priorities: [MAX_ISSUES]u3 = [_]u3{2} ** MAX_ISSUES,
    has_closed_at: [MAX_ISSUES]bool = [_]bool{false} ** MAX_ISSUES,
    archived: [MAX_ISSUES]bool = [_]bool{false} ** MAX_ISSUES, // Closed root issues get archived
    parents: [MAX_ISSUES]?usize = [_]?usize{null} ** MAX_ISSUES,
    // deps[i][j] = true means i depends on j (j blocks i)
    deps: [MAX_ISSUES][MAX_ISSUES]bool = [_][MAX_ISSUES]bool{[_]bool{false} ** MAX_ISSUES} ** MAX_ISSUES,

    pub fn create(self: *LifecycleOracle, idx: usize, priority: u3, parent: ?usize) void {
        self.exists[idx] = true;
        self.statuses[idx] = .open;
        self.priorities[idx] = priority;
        self.has_closed_at[idx] = false;
        self.archived[idx] = false;
        self.parents[idx] = parent;
    }

    pub fn delete(self: *LifecycleOracle, idx: usize) void {
        self.exists[idx] = false;
        self.archived[idx] = false;
        // Remove all dependencies involving this issue
        for (0..MAX_ISSUES) |i| {
            self.deps[idx][i] = false;
            self.deps[i][idx] = false;
        }
    }

    pub fn setStatus(self: *LifecycleOracle, idx: usize, status: Status) void {
        self.statuses[idx] = status;
        self.has_closed_at[idx] = (status == .closed);
        // Root issues (no parent) get archived when closed
        if (status == .closed and self.parents[idx] == null) {
            self.archived[idx] = true;
        } else if (status != .closed) {
            self.archived[idx] = false;
        }
    }

    pub fn canClose(self: *LifecycleOracle, idx: usize) bool {
        // Can't close if has open children
        for (0..MAX_ISSUES) |i| {
            if (self.exists[i] and self.parents[i] == idx) {
                if (self.statuses[i] != .closed) return false;
            }
        }
        return true;
    }

    pub fn addDep(self: *LifecycleOracle, from: usize, to: usize) bool {
        // Check for cycle
        if (self.wouldCreateCycle(from, to)) return false;
        self.deps[from][to] = true;
        return true;
    }

    pub fn wouldCreateCycle(self: *LifecycleOracle, from: usize, to: usize) bool {
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

    pub fn isBlocked(self: *LifecycleOracle, idx: usize) bool {
        for (0..MAX_ISSUES) |j| {
            if (self.deps[idx][j] and self.exists[j]) {
                if (self.statuses[j] == .open or self.statuses[j] == .active) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn isReady(self: *LifecycleOracle, idx: usize) bool {
        // Archived issues are not in ready list
        return self.exists[idx] and !self.archived[idx] and self.statuses[idx] == .open and !self.isBlocked(idx);
    }

    pub fn countByStatus(self: *LifecycleOracle, status: Status) usize {
        var count: usize = 0;
        for (0..MAX_ISSUES) |i| {
            // Archived issues are not in listIssues (only in archive dir)
            if (self.exists[i] and !self.archived[i] and self.statuses[i] == status) count += 1;
        }
        return count;
    }

    pub fn readyCount(self: *LifecycleOracle) usize {
        var count: usize = 0;
        for (0..MAX_ISSUES) |i| {
            if (self.isReady(i)) count += 1;
        }
        return count;
    }
};

// Operation types for lifecycle simulation
pub const OpType = enum { create, delete, set_open, set_active, set_closed, add_dep };

pub const JsonIssue = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: i64,
};
