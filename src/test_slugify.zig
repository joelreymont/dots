const std = @import("std");
const h = @import("test_helpers.zig");

const storage_mod = h.storage_mod;
const zc = h.zc;
const OhSnap = h.OhSnap;
const Issue = h.Issue;
const fixed_timestamp = h.fixed_timestamp;
const makeTestIssue = h.makeTestIssue;
const runDot = h.runDot;
const isExitCode = h.isExitCode;
const JsonIssue = h.JsonIssue;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const cleanupTestDirAndFree = h.cleanupTestDirAndFree;
const openTestStorage = h.openTestStorage;

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
