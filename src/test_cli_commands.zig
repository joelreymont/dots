const std = @import("std");
const fs = std.fs;
const h = @import("test_helpers.zig");

const storage_mod = h.storage_mod;
const Status = h.Status;
const Issue = h.Issue;
const OhSnap = h.OhSnap;
const fixed_timestamp = h.fixed_timestamp;
const runDot = h.runDot;
const isExitCode = h.isExitCode;
const trimNewline = h.trimNewline;
const normalizeTreeOutput = h.normalizeTreeOutput;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const cleanupTestDirAndFree = h.cleanupTestDirAndFree;
const openTestStorage = h.openTestStorage;

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

test "cli: find help" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const help = runDot(allocator, &.{ "find", "--help" }, test_dir) catch |err| {
        std.debug.panic("find help: {}", .{err});
    };
    defer help.deinit(allocator);

    try std.testing.expect(isExitCode(help.term, 0));

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "Usage: dot find <query>
        \\
        \\Search all dots (open first, then archived).
        \\
        \\Searches: title, description, close-reason, created-at, closed-at
        \\
        \\Examples:
        \\  dot find "auth"      Search for dots mentioning auth
        \\  dot find "2026-01"   Find dots from January 2026
        \\"
    ).expectEqual(help.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(help.stderr);
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

test "cli: find searches archive fields and orders results" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    var ts = openTestStorage(allocator, test_dir);

    const open_issue = Issue{
        .id = "open-11111111",
        .title = "Open task",
        .description = "",
        .status = .open,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = "2024-03-01T00:00:00Z",
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .parent = null,
    };
    try ts.storage.createIssue(open_issue, null);

    const closed_issue = Issue{
        .id = "closed-22222222",
        .title = "Closed task",
        .description = "",
        .status = .closed,
        .priority = 2,
        .issue_type = "task",
        .assignee = null,
        .created_at = "2024-01-01T00:00:00Z",
        .closed_at = "2024-02-01T00:00:00Z",
        .close_reason = "wontfix",
        .blocks = &.{},
        .parent = null,
    };
    try ts.storage.createIssue(closed_issue, null);
    try ts.storage.archiveIssue("closed-22222222");
    ts.deinit();

    const find_task = runDot(allocator, &.{ "find", "task" }, test_dir) catch |err| {
        std.debug.panic("find task: {}", .{err});
    };
    defer find_task.deinit(allocator);

    const find_reason = runDot(allocator, &.{ "find", "wontfix" }, test_dir) catch |err| {
        std.debug.panic("find reason: {}", .{err});
    };
    defer find_reason.deinit(allocator);

    const find_created = runDot(allocator, &.{ "find", "2024-03" }, test_dir) catch |err| {
        std.debug.panic("find created: {}", .{err});
    };
    defer find_created.deinit(allocator);

    const find_closed = runDot(allocator, &.{ "find", "2024-02" }, test_dir) catch |err| {
        std.debug.panic("find closed: {}", .{err});
    };
    defer find_closed.deinit(allocator);

    try std.testing.expect(isExitCode(find_task.term, 0));
    try std.testing.expect(isExitCode(find_reason.term, 0));
    try std.testing.expect(isExitCode(find_created.term, 0));
    try std.testing.expect(isExitCode(find_closed.term, 0));

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "[open-11111111] o Open task
        \\[closed-22222222] x Closed task
        \\"
    ).expectEqual(find_task.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  "[closed-22222222] x Closed task
        \\"
    ).expectEqual(find_reason.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  "[open-11111111] o Open task
        \\"
    ).expectEqual(find_created.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  "[closed-22222222] x Closed task
        \\"
    ).expectEqual(find_closed.stdout);

    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_task.stderr);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_reason.stderr);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_created.stderr);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_closed.stderr);
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

test "cli: tree help" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const help = runDot(allocator, &.{ "tree", "--help" }, test_dir) catch |err| {
        std.debug.panic("tree help: {}", .{err});
    };
    defer help.deinit(allocator);

    try std.testing.expect(isExitCode(help.term, 0));

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "Usage: dot tree [id]
        \\
        \\Show dot hierarchy.
        \\
        \\Without arguments: shows all open root dots and their children.
        \\With id: shows that specific dot's tree (including closed children).
        \\
        \\Examples:
        \\  dot tree                    Show all open root dots
        \\  dot tree my-project         Show specific dot and its children
        \\"
    ).expectEqual(help.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(help.stderr);
}

test "cli: tree id shows specific root" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    const parent1 = runDot(allocator, &.{ "add", "Parent one" }, test_dir) catch |err| {
        std.debug.panic("add parent1: {}", .{err});
    };
    defer parent1.deinit(allocator);
    const parent1_id = trimNewline(parent1.stdout);

    const parent2 = runDot(allocator, &.{ "add", "Parent two" }, test_dir) catch |err| {
        std.debug.panic("add parent2: {}", .{err});
    };
    defer parent2.deinit(allocator);

    const child = runDot(allocator, &.{ "add", "Child one", "-P", parent1_id }, test_dir) catch |err| {
        std.debug.panic("add child: {}", .{err});
    };
    defer child.deinit(allocator);
    const child_id = trimNewline(child.stdout);

    const off = runDot(allocator, &.{ "off", child_id }, test_dir) catch |err| {
        std.debug.panic("off child: {}", .{err});
    };
    defer off.deinit(allocator);

    const tree = runDot(allocator, &.{ "tree", parent1_id }, test_dir) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer tree.deinit(allocator);

    try std.testing.expect(isExitCode(tree.term, 0));

    const normalized = try normalizeTreeOutput(allocator, tree.stdout);
    defer allocator.free(normalized);

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "[ID] ○ Parent one
        \\  └─ [ID] ✓ Child one
        \\"
    ).expectEqual(normalized);
}

test "cli: tree ignores missing parent" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    var dir = fs.openDirAbsolute(test_dir, .{}) catch |err| {
        std.debug.panic("open dir: {}", .{err});
    };
    defer dir.close();

    var dots_dir = dir.openDir(".dots", .{ .iterate = true }) catch |err| {
        std.debug.panic("open .dots: {}", .{err});
    };
    defer dots_dir.close();

    dots_dir.makeDir("orphan") catch |err| {
        std.debug.panic("mkdir orphan: {}", .{err});
    };

    const orphan =
        \\---
        \\title: Orphan child
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: 2024-01-01T00:00:00Z
        \\---
    ;
    dots_dir.writeFile(.{ .sub_path = "orphan/orphan-child.md", .data = orphan }) catch |err| {
        std.debug.panic("write orphan: {}", .{err});
    };

    const tree = runDot(allocator, &.{"tree"}, test_dir) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer tree.deinit(allocator);

    try std.testing.expect(isExitCode(tree.term, 0));

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "[orphan-child] ○ Orphan child
        \\"
    ).expectEqual(tree.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(tree.stderr);
}

test "cli: fix promotes orphan children" {
    const allocator = std.testing.allocator;

    const test_dir = setupTestDirOrPanic(allocator);
    defer cleanupTestDirAndFree(allocator, test_dir);

    const init = runDot(allocator, &.{"init"}, test_dir) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    var dir = fs.openDirAbsolute(test_dir, .{}) catch |err| {
        std.debug.panic("open dir: {}", .{err});
    };
    defer dir.close();

    var dots_dir = dir.openDir(".dots", .{ .iterate = true }) catch |err| {
        std.debug.panic("open .dots: {}", .{err});
    };
    defer dots_dir.close();

    dots_dir.makeDir("orphan") catch |err| {
        std.debug.panic("mkdir orphan: {}", .{err});
    };

    const orphan =
        \\---
        \\title: Orphan child
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: 2024-01-01T00:00:00Z
        \\---
    ;
    dots_dir.writeFile(.{ .sub_path = "orphan/orphan-child.md", .data = orphan }) catch |err| {
        std.debug.panic("write orphan: {}", .{err});
    };

    const fix = runDot(allocator, &.{"fix"}, test_dir) catch |err| {
        std.debug.panic("fix: {}", .{err});
    };
    defer fix.deinit(allocator);

    try std.testing.expect(isExitCode(fix.term, 0));

    const oh = OhSnap{};
    try oh.snap(@src(),
        \\[]u8
        \\  "Fixed 1 orphan parent(s), moved 1 file(s)
        \\"
    ).expectEqual(fix.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(fix.stderr);

    _ = dots_dir.statFile("orphan-child.md") catch |err| {
        std.debug.panic("stat moved orphan: {}", .{err});
    };

    if (dots_dir.openDir("orphan", .{})) |orphan_dir| {
        var od = orphan_dir;
        od.close();
        std.debug.panic("orphan dir still exists", .{});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("open orphan dir: {}", .{err}),
    }
}
