const std = @import("std");
const fs = std.fs;

// Path to the built binary (set at comptime based on build directory)
const dot_binary = "/Users/joel/Work/dots/zig-out/bin/dot";

// Test helper to run dot command and capture output
fn runDot(allocator: std.mem.Allocator, args: []const []const u8, cwd: []const u8) !struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term } {
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

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();

    return .{ .stdout = stdout, .stderr = stderr, .term = term };
}

// Create a temp directory for each test
fn setupTestDir(allocator: std.mem.Allocator) ![]const u8 {
    // Generate a unique directory name using random bytes
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);

    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const path = try std.fmt.allocPrint(allocator, "/tmp/dots-test-{s}", .{hex});

    try fs.makeDirAbsolute(path);
    return path;
}

fn cleanupTestDir(path: []const u8) void {
    fs.cwd().deleteTree(path) catch {};
}

// Strip timestamps from output for stable comparisons
fn stripTimestamps(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;

    while (i < input.len) {
        // Look for timestamp pattern: 4 digits, dash, 2 digits, dash, 2 digits, T
        if (i + 25 < input.len and
            std.ascii.isDigit(input[i]) and
            std.ascii.isDigit(input[i + 1]) and
            std.ascii.isDigit(input[i + 2]) and
            std.ascii.isDigit(input[i + 3]) and
            input[i + 4] == '-' and
            input[i + 7] == '-' and
            input[i + 10] == 'T')
        {
            try result.appendSlice(allocator, "<TIMESTAMP>");
            // Skip until end of timestamp
            while (i < input.len and input[i] != '"' and input[i] != ',' and input[i] != '\n' and input[i] != ' ') {
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// Strip IDs for stable comparisons (d-xxxx -> d-ID)
fn stripIds(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;

    while (i < input.len) {
        if (i + 2 < input.len and input[i] == 'd' and input[i + 1] == '-') {
            try result.appendSlice(allocator, "d-ID");
            i += 2;
            while (i < input.len and std.ascii.isHex(input[i])) {
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn normalize(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const no_ts = try stripTimestamps(allocator, input);
    defer allocator.free(no_ts);
    return stripIds(allocator, no_ts);
}

test "dot help" {
    const allocator = std.testing.allocator;

    const result = try runDot(allocator, &.{"--help"}, "/tmp");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "dots - Connect the dots") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "dot \"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "dot it <id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "dot off <id>") != null);
}

test "dot version" {
    const allocator = std.testing.allocator;

    const result = try runDot(allocator, &.{"--version"}, "/tmp");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "dots "));
}

test "dot add and list" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    // Init
    _ = try runDot(allocator, &.{"init"}, test_dir);

    // Add a dot
    const add_result = try runDot(allocator, &.{ "add", "Test task", "-p", "1", "-d", "A test description" }, test_dir);
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);

    try std.testing.expect(std.mem.startsWith(u8, add_result.stdout, "bd-"));

    // List dots
    const list_result = try runDot(allocator, &.{"ls"}, test_dir);
    defer allocator.free(list_result.stdout);
    defer allocator.free(list_result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, list_result.stdout, "Test task") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_result.stdout, "o ") != null); // open marker
}

test "dot add with json" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    const result = try runDot(allocator, &.{ "add", "JSON test", "-p", "2", "--json" }, test_dir);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"title\":\"JSON test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"status\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"priority\":2") != null);
}

test "dot it and off workflow" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    // Add a task
    const add_result = try runDot(allocator, &.{ "add", "Workflow test" }, test_dir);
    const id = std.mem.trim(u8, add_result.stdout, "\n");
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);

    // Start work
    const it_result = try runDot(allocator, &.{ "it", id }, test_dir);
    defer allocator.free(it_result.stdout);
    defer allocator.free(it_result.stderr);

    // Check status changed to active
    const list1 = try runDot(allocator, &.{"ls"}, test_dir);
    defer allocator.free(list1.stdout);
    defer allocator.free(list1.stderr);

    try std.testing.expect(std.mem.indexOf(u8, list1.stdout, "> Workflow test") != null);

    // Complete
    const off_result = try runDot(allocator, &.{ "off", id, "-r", "Done testing" }, test_dir);
    defer allocator.free(off_result.stdout);
    defer allocator.free(off_result.stderr);

    // Check it's gone from default list (done items hidden)
    const list2 = try runDot(allocator, &.{"ls"}, test_dir);
    defer allocator.free(list2.stdout);
    defer allocator.free(list2.stderr);

    try std.testing.expect(std.mem.indexOf(u8, list2.stdout, "Workflow test") == null);

    // But visible with --status done
    const list3 = try runDot(allocator, &.{ "ls", "--status", "done" }, test_dir);
    defer allocator.free(list3.stdout);
    defer allocator.free(list3.stderr);

    try std.testing.expect(std.mem.indexOf(u8, list3.stdout, "x Workflow test") != null);
}

test "dot ready with dependencies" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    // Add first task
    const add1 = try runDot(allocator, &.{ "add", "First task" }, test_dir);
    const id1 = std.mem.trim(u8, add1.stdout, "\n");
    defer allocator.free(add1.stdout);
    defer allocator.free(add1.stderr);

    // Add second task blocked by first
    const add2 = try runDot(allocator, &.{ "add", "Second task", "-a", id1 }, test_dir);
    defer allocator.free(add2.stdout);
    defer allocator.free(add2.stderr);

    // Only first should be ready
    const ready1 = try runDot(allocator, &.{"ready"}, test_dir);
    defer allocator.free(ready1.stdout);
    defer allocator.free(ready1.stderr);

    try std.testing.expect(std.mem.indexOf(u8, ready1.stdout, "First task") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready1.stdout, "Second task") == null);

    // Complete first task
    const off_result = try runDot(allocator, &.{ "off", id1 }, test_dir);
    defer allocator.free(off_result.stdout);
    defer allocator.free(off_result.stderr);

    // Now second should be ready
    const ready2 = try runDot(allocator, &.{"ready"}, test_dir);
    defer allocator.free(ready2.stdout);
    defer allocator.free(ready2.stderr);

    try std.testing.expect(std.mem.indexOf(u8, ready2.stdout, "Second task") != null);
}

test "dot tree with parent" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    // Add parent
    const add1 = try runDot(allocator, &.{ "add", "Parent task" }, test_dir);
    const parent_id = std.mem.trim(u8, add1.stdout, "\n");
    defer allocator.free(add1.stdout);
    defer allocator.free(add1.stderr);

    // Add child
    const add2 = try runDot(allocator, &.{ "add", "Child task", "-P", parent_id }, test_dir);
    defer allocator.free(add2.stdout);
    defer allocator.free(add2.stderr);

    // Tree should show hierarchy
    const tree = try runDot(allocator, &.{"tree"}, test_dir);
    defer allocator.free(tree.stdout);
    defer allocator.free(tree.stderr);

    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Parent task") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "└─") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Child task") != null);
}

test "dot show" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    const add = try runDot(allocator, &.{ "add", "Show test", "-p", "1", "-d", "Description here" }, test_dir);
    const id = std.mem.trim(u8, add.stdout, "\n");
    defer allocator.free(add.stdout);
    defer allocator.free(add.stderr);

    const show = try runDot(allocator, &.{ "show", id }, test_dir);
    defer allocator.free(show.stdout);
    defer allocator.free(show.stderr);

    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Title:    Show test") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Status:   open") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Priority: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Desc:     Description here") != null);
}

test "dot find" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    const a1 = try runDot(allocator, &.{ "add", "Alpha task" }, test_dir);
    defer allocator.free(a1.stdout);
    defer allocator.free(a1.stderr);

    const a2 = try runDot(allocator, &.{ "add", "Beta task" }, test_dir);
    defer allocator.free(a2.stdout);
    defer allocator.free(a2.stderr);

    const a3 = try runDot(allocator, &.{ "add", "Gamma task" }, test_dir);
    defer allocator.free(a3.stdout);
    defer allocator.free(a3.stderr);

    const find = try runDot(allocator, &.{ "find", "Beta" }, test_dir);
    defer allocator.free(find.stdout);
    defer allocator.free(find.stderr);

    try std.testing.expect(std.mem.indexOf(u8, find.stdout, "Beta task") != null);
    try std.testing.expect(std.mem.indexOf(u8, find.stdout, "Alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, find.stdout, "Gamma") == null);
}

test "dot rm" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    const add = try runDot(allocator, &.{ "add", "To be removed" }, test_dir);
    const id = std.mem.trim(u8, add.stdout, "\n");
    defer allocator.free(add.stdout);
    defer allocator.free(add.stderr);

    // Remove it
    const rm = try runDot(allocator, &.{ "rm", id }, test_dir);
    defer allocator.free(rm.stdout);
    defer allocator.free(rm.stderr);

    // Should be gone
    const list = try runDot(allocator, &.{"ls"}, test_dir);
    defer allocator.free(list.stdout);
    defer allocator.free(list.stderr);

    try std.testing.expectEqualStrings("", list.stdout);
}

test "beads compatibility - create" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    // Use beads-style create command
    const result = try runDot(allocator, &.{ "create", "Beads compat test", "-p", "2", "-d", "Testing beads commands", "--json" }, test_dir);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"title\":\"Beads compat test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"status\":\"open\"") != null);
}

test "beads compatibility - close" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    const add = try runDot(allocator, &.{ "add", "To close" }, test_dir);
    const id = std.mem.trim(u8, add.stdout, "\n");
    defer allocator.free(add.stdout);
    defer allocator.free(add.stderr);

    // Use beads-style close command
    const close = try runDot(allocator, &.{ "close", id, "--reason", "Completed via beads API" }, test_dir);
    defer allocator.free(close.stdout);
    defer allocator.free(close.stderr);

    // Should be closed
    const list = try runDot(allocator, &.{ "ls", "--status", "done" }, test_dir);
    defer allocator.free(list.stdout);
    defer allocator.free(list.stderr);

    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "To close") != null);
}

test "quick add" {
    const allocator = std.testing.allocator;

    const test_dir = try setupTestDir(allocator);
    defer {
        cleanupTestDir(test_dir);
        allocator.free(test_dir);
    }

    _ = try runDot(allocator, &.{"init"}, test_dir);

    // Quick add without "add" subcommand
    const result = try runDot(allocator, &.{"Quick add test"}, test_dir);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should have created a dot
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "bd-"));

    // Verify it's in the list
    const list = try runDot(allocator, &.{"ls"}, test_dir);
    defer allocator.free(list.stdout);
    defer allocator.free(list.stderr);

    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "Quick add test") != null);
}
