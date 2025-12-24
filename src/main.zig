const std = @import("std");
const fs = std.fs;
const json = std.json;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");

const libc = @cImport({
    @cInclude("time.h");
});

const BEADS_DIR = ".beads";
const BEADS_DB = ".beads/beads.db";
const BEADS_JSONL = ".beads/issues.jsonl";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // No args = show ready
    if (args.len < 2) {
        try cmdReady(allocator, &[_][]const u8{"--json"});
        return;
    }

    const cmd = args[1];

    // Quick add: dot "title"
    if (cmd.len > 0 and cmd[0] != '-' and !isCommand(cmd)) {
        try cmdAdd(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        try cmdAdd(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "ls") or std.mem.eql(u8, cmd, "list")) {
        try cmdList(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "it") or std.mem.eql(u8, cmd, "do")) {
        try cmdIt(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "off") or std.mem.eql(u8, cmd, "done")) {
        try cmdOff(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "delete")) {
        try cmdRm(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "show")) {
        try cmdShow(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "ready")) {
        try cmdReady(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "tree")) {
        try cmdTree(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "find")) {
        try cmdFind(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(allocator);
    } else if (std.mem.eql(u8, cmd, "create")) {
        try cmdAdd(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "update")) {
        try cmdBeadsUpdate(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "close")) {
        try cmdBeadsClose(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage();
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try printVersion();
    } else {
        try cmdAdd(allocator, args[1..]);
    }
}

fn isCommand(s: []const u8) bool {
    const commands = [_][]const u8{ "add", "ls", "list", "it", "do", "off", "done", "rm", "delete", "show", "ready", "tree", "find", "init", "help", "create", "update", "close" };
    for (commands) |c| {
        if (std.mem.eql(u8, s, c)) return true;
    }
    return false;
}

fn openStorage(allocator: Allocator) !sqlite.Storage {
    return sqlite.Storage.open(allocator, BEADS_DB);
}

fn printUsage() !void {
    const usage =
        \\dots - Connect the dots
        \\
        \\Usage: dot [command] [options]
        \\
        \\Commands:
        \\  dot "title"                  Quick add a dot
        \\  dot add "title" [options]    Add a dot (-p priority, -d desc, -P parent, -a after)
        \\  dot ls [--status S] [--json] List dots
        \\  dot it <id>                  Start working ("I'm on it!")
        \\  dot off <id> [-r reason]     Complete ("cross it off")
        \\  dot rm <id>                  Remove a dot
        \\  dot show <id>                Show dot details
        \\  dot ready [--json]           Show unblocked dots
        \\  dot tree                     Show hierarchy
        \\  dot find "query"             Search dots
        \\  dot init                     Initialize .beads directory
        \\
        \\Examples:
        \\  dot "Fix the bug"
        \\  dot add "Design API" -p 1 -d "REST endpoints"
        \\  dot add "Implement" -P bd-1 -a bd-2
        \\  dot it bd-3
        \\  dot off bd-3 -r "shipped"
        \\
    ;
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;
    try w.writeAll(usage);
    try w.flush();
}

fn printVersion() !void {
    const stdout_file = fs.File.stdout();
    var buf: [256]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;
    try w.writeAll("dots 0.2.0\n");
    try w.flush();
}

fn cmdInit(allocator: Allocator) !void {
    // Create .beads directory
    fs.cwd().makeDir(BEADS_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Check if we should hydrate from JSONL
    const jsonl_exists = blk: {
        fs.cwd().access(BEADS_JSONL, .{}) catch break :blk false;
        break :blk true;
    };

    var storage = try openStorage(allocator);
    defer storage.close();

    if (jsonl_exists) {
        const count = try sqlite.hydrateFromJsonl(&storage, allocator, BEADS_JSONL);
        if (count > 0) {
            const stdout = fs.File.stdout();
            var buf: [256]u8 = undefined;
            var file_writer = stdout.writer(&buf);
            const w = &file_writer.interface;
            try w.print("Hydrated {d} issues from {s}\n", .{ count, BEADS_JSONL });
            try w.flush();
        }
    }
}

fn cmdAdd(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printUsage();
        std.process.exit(1);
    }

    var title: []const u8 = "";
    var description: []const u8 = "";
    var priority: i64 = 2;
    var parent: ?[]const u8 = null;
    var after: ?[]const u8 = null;
    var use_json = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            priority = std.fmt.parseInt(i64, args[i], 10) catch 2;
        } else if (std.mem.eql(u8, args[i], "-d") and i + 1 < args.len) {
            i += 1;
            description = args[i];
        } else if (std.mem.eql(u8, args[i], "-P") and i + 1 < args.len) {
            i += 1;
            parent = args[i];
        } else if (std.mem.eql(u8, args[i], "-a") and i + 1 < args.len) {
            i += 1;
            after = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            use_json = true;
        } else if (title.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            title = args[i];
        }
    }

    if (title.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Error: title required\n");
        try w.flush();
        std.process.exit(1);
    }

    const id = try generateId(allocator);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    const issue = sqlite.Issue{
        .id = id,
        .title = title,
        .description = description,
        .status = "open",
        .priority = priority,
        .issue_type = "task",
        .assignee = null,
        .created_at = now,
        .updated_at = now,
        .closed_at = null,
        .close_reason = null,
        .after = after,
        .parent = parent,
    };

    try storage.createIssue(issue);

    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    if (use_json) {
        try writeIssueJson(issue, w);
        try w.writeByte('\n');
    } else {
        try w.print("{s}\n", .{id});
    }
    try w.flush();
}

fn cmdList(allocator: Allocator, args: []const []const u8) !void {
    var use_json = false;
    var filter_status: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            use_json = true;
        } else if (std.mem.eql(u8, args[i], "--status") and i + 1 < args.len) {
            i += 1;
            filter_status = mapStatus(args[i]);
        }
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.listIssues(filter_status);
    defer allocator.free(issues);

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    if (use_json) {
        try w.writeByte('[');
        for (issues, 0..) |issue, idx| {
            if (idx > 0) try w.writeByte(',');
            // Skip done unless explicitly requested
            if (filter_status == null and std.mem.eql(u8, issue.status, "done")) continue;
            try writeIssueJson(issue, w);
        }
        try w.writeAll("]\n");
    } else {
        for (issues) |issue| {
            // Skip done unless explicitly requested
            if (filter_status == null and std.mem.eql(u8, issue.status, "done")) continue;
            const status_char: u8 = if (std.mem.eql(u8, issue.status, "open")) 'o' else if (std.mem.eql(u8, issue.status, "active")) '>' else 'x';
            try w.print("[{s}] {c} {s}\n", .{ issue.id, status_char, issue.title });
        }
    }
    try w.flush();
}

fn cmdReady(allocator: Allocator, args: []const []const u8) !void {
    var use_json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) use_json = true;
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.getReadyIssues();
    defer allocator.free(issues);

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    if (use_json) {
        try w.writeByte('[');
        for (issues, 0..) |issue, idx| {
            if (idx > 0) try w.writeByte(',');
            try writeIssueJson(issue, w);
        }
        try w.writeAll("]\n");
    } else {
        for (issues) |issue| {
            try w.print("[{s}] {s}\n", .{ issue.id, issue.title });
        }
    }
    try w.flush();
}

fn cmdIt(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot it <id>\n");
        try w.flush();
        std.process.exit(1);
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.updateStatus(args[0], "active", now, null, null);
}

fn cmdOff(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot off <id> [-r reason]\n");
        try w.flush();
        std.process.exit(1);
    }

    const id = args[0];
    var reason: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-r") and i + 1 < args.len) {
            i += 1;
            reason = args[i];
        }
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.updateStatus(id, "done", now, now, reason);
}

fn cmdRm(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot rm <id>\n");
        try w.flush();
        std.process.exit(1);
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.deleteIssue(args[0]);
}

fn cmdShow(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot show <id>\n");
        try w.flush();
        std.process.exit(1);
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issue = try storage.getIssue(args[0]);
    if (issue == null) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.print("Issue not found: {s}\n", .{args[0]});
        try w.flush();
        std.process.exit(1);
    }

    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    const iss = issue.?;
    try w.print("ID:       {s}\n", .{iss.id});
    try w.print("Title:    {s}\n", .{iss.title});
    try w.print("Status:   {s}\n", .{iss.status});
    try w.print("Priority: {d}\n", .{iss.priority});
    if (iss.description.len > 0) {
        try w.print("Desc:     {s}\n", .{iss.description});
    }
    try w.print("Created:  {s}\n", .{iss.created_at});
    if (iss.closed_at) |ca| {
        try w.print("Closed:   {s}\n", .{ca});
    }
    if (iss.close_reason) |r| {
        try w.print("Reason:   {s}\n", .{r});
    }
    try w.flush();
}

fn cmdTree(allocator: Allocator, args: []const []const u8) !void {
    _ = args;

    var storage = try openStorage(allocator);
    defer storage.close();

    const roots = try storage.getRootIssues();
    defer allocator.free(roots);

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    for (roots) |root| {
        const status_sym = if (std.mem.eql(u8, root.status, "open")) "○" else if (std.mem.eql(u8, root.status, "active")) "●" else "✓";
        try w.print("[{s}] {s} {s}\n", .{ root.id, status_sym, root.title });

        // Print children
        const children = try storage.getChildren(root.id);
        defer allocator.free(children);

        for (children) |child| {
            const child_status = if (std.mem.eql(u8, child.status, "open")) "○" else if (std.mem.eql(u8, child.status, "active")) "●" else "✓";
            const blocked = try storage.isBlocked(child.id);
            const blocked_msg: []const u8 = if (blocked) " (blocked)" else "";
            try w.print("  └─ [{s}] {s} {s}{s}\n", .{ child.id, child_status, child.title, blocked_msg });
        }
    }
    try w.flush();
}

fn cmdFind(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot find <query>\n");
        try w.flush();
        std.process.exit(1);
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.searchIssues(args[0]);
    defer allocator.free(issues);

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    for (issues) |issue| {
        const status_char: u8 = if (std.mem.eql(u8, issue.status, "open")) 'o' else if (std.mem.eql(u8, issue.status, "active")) '>' else 'x';
        try w.print("[{s}] {c} {s}\n", .{ issue.id, status_char, issue.title });
    }
    try w.flush();
}

fn cmdBeadsUpdate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot update <id> [--status S]\n");
        try w.flush();
        std.process.exit(1);
    }

    const id = args[0];
    var new_status: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--status") and i + 1 < args.len) {
            i += 1;
            new_status = mapStatus(args[i]);
        }
    }

    if (new_status) |status| {
        var ts_buf: [40]u8 = undefined;
        const now = try formatTimestamp(&ts_buf);

        var storage = try openStorage(allocator);
        defer storage.close();

        try storage.updateStatus(id, status, now, null, null);
    }
}

fn cmdBeadsClose(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot close <id> [--reason R]\n");
        try w.flush();
        std.process.exit(1);
    }

    const id = args[0];
    var reason: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--reason") and i + 1 < args.len) {
            i += 1;
            reason = args[i];
        }
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.updateStatus(id, "done", now, now, reason);
}

fn mapStatus(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "in_progress")) return "active";
    if (std.mem.eql(u8, s, "closed")) return "done";
    return s;
}

fn generateId(allocator: Allocator) ![]u8 {
    const nanos = std.time.nanoTimestamp();
    const ts: u64 = @intCast(@as(u128, @intCast(nanos)) & 0xFFFFFFFF);
    return std.fmt.allocPrint(allocator, "bd-{x}", .{@as(u16, @truncate(ts))});
}

fn formatTimestamp(buf: []u8) ![]const u8 {
    const nanos = std.time.nanoTimestamp();
    const epoch_nanos: u128 = @intCast(nanos);
    const epoch_secs: libc.time_t = @intCast(epoch_nanos / 1_000_000_000);
    const micros: u64 = @intCast((epoch_nanos % 1_000_000_000) / 1000);

    var tm: libc.struct_tm = undefined;
    _ = libc.localtime_r(&epoch_secs, &tm);

    const year: u64 = @intCast(tm.tm_year + 1900);
    const month: u64 = @intCast(tm.tm_mon + 1);
    const day: u64 = @intCast(tm.tm_mday);
    const hours: u64 = @intCast(tm.tm_hour);
    const mins: u64 = @intCast(tm.tm_min);
    const secs: u64 = @intCast(tm.tm_sec);

    const tz_offset_secs: i64 = tm.tm_gmtoff;
    const tz_hours: i64 = @divTrunc(tz_offset_secs, 3600);
    const tz_mins: u64 = @abs(@rem(tz_offset_secs, 3600)) / 60;
    const tz_sign: u8 = if (tz_hours >= 0) '+' else '-';
    const tz_hours_abs: u64 = @abs(tz_hours);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}{c}{d:0>2}:{d:0>2}", .{
        year, month, day, hours, mins, secs, micros, tz_sign, tz_hours_abs, tz_mins,
    });
}

fn writeIssueJson(issue: sqlite.Issue, w: *std.Io.Writer) !void {
    try w.writeAll("{\"id\":\"");
    try w.writeAll(issue.id);
    try w.writeAll("\",\"title\":");
    try json.Stringify.encodeJsonString(issue.title, .{}, w);
    if (issue.description.len > 0) {
        try w.writeAll(",\"description\":");
        try json.Stringify.encodeJsonString(issue.description, .{}, w);
    }
    try w.writeAll(",\"status\":\"");
    try w.writeAll(issue.status);
    try w.writeAll("\",\"priority\":");
    try w.print("{d}", .{issue.priority});
    try w.writeAll(",\"issue_type\":\"");
    try w.writeAll(issue.issue_type);
    try w.writeAll("\",\"created_at\":\"");
    try w.writeAll(issue.created_at);
    try w.writeAll("\",\"updated_at\":\"");
    try w.writeAll(issue.updated_at);
    try w.writeByte('"');
    if (issue.closed_at) |ca| {
        try w.writeAll(",\"closed_at\":\"");
        try w.writeAll(ca);
        try w.writeByte('"');
    }
    if (issue.close_reason) |r| {
        try w.writeAll(",\"close_reason\":");
        try json.Stringify.encodeJsonString(r, .{}, w);
    }
    try w.writeByte('}');
}

test "basic" {
    try std.testing.expect(true);
}
