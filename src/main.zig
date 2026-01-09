const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const storage_mod = @import("storage.zig");
const build_options = @import("build_options");
const mapping_util = @import("util/mapping.zig");

const libc = @cImport({
    @cInclude("time.h");
});

const Storage = storage_mod.Storage;
const Issue = storage_mod.Issue;
const Status = storage_mod.Status;

const DOTS_DIR = ".dots";
const MAPPING_FILE = ".dots/todo-mapping.json";
const max_hook_input_bytes = 1024 * 1024;
const max_mapping_bytes = 1024 * 1024;
const max_jsonl_line_bytes = 1024 * 1024;
const default_priority: i64 = 2;

// Command dispatch table
const Handler = *const fn (Allocator, []const []const u8) anyerror!void;
const Command = struct { names: []const []const u8, handler: Handler };

const commands = [_]Command{
    .{ .names = &.{ "add", "create" }, .handler = cmdAdd },
    .{ .names = &.{ "ls", "list" }, .handler = cmdList },
    .{ .names = &.{ "on", "it" }, .handler = cmdOn },
    .{ .names = &.{ "off", "done" }, .handler = cmdOff },
    .{ .names = &.{ "rm", "delete" }, .handler = cmdRm },
    .{ .names = &.{"show"}, .handler = cmdShow },
    .{ .names = &.{"ready"}, .handler = cmdReady },
    .{ .names = &.{"tree"}, .handler = cmdTree },
    .{ .names = &.{"find"}, .handler = cmdFind },
    .{ .names = &.{"update"}, .handler = cmdUpdate },
    .{ .names = &.{"close"}, .handler = cmdClose },
    .{ .names = &.{"purge"}, .handler = cmdPurge },
    .{ .names = &.{"hook"}, .handler = cmdHook },
    .{ .names = &.{"init"}, .handler = cmdInitWrapper },
    .{ .names = &.{ "help", "--help", "-h" }, .handler = cmdHelp },
    .{ .names = &.{ "--version", "-v" }, .handler = cmdVersion },
    // ExecPlan commands
    .{ .names = &.{"plan"}, .handler = cmdPlan },
    .{ .names = &.{"milestone"}, .handler = cmdMilestone },
    .{ .names = &.{"task"}, .handler = cmdTask },
    .{ .names = &.{"progress"}, .handler = cmdProgress },
    .{ .names = &.{"discover"}, .handler = cmdDiscover },
    .{ .names = &.{"decide"}, .handler = cmdDecide },
    .{ .names = &.{"backlog"}, .handler = cmdBacklog },
    .{ .names = &.{"activate"}, .handler = cmdActivate },
    .{ .names = &.{"ralph"}, .handler = cmdRalph },
    .{ .names = &.{"migrate"}, .handler = cmdMigrate },
    .{ .names = &.{"restructure"}, .handler = cmdRestructure },
};

fn findCommand(name: []const u8) ?Handler {
    inline for (commands) |cmd| {
        inline for (cmd.names) |n| {
            if (std.mem.eql(u8, name, n)) return cmd.handler;
        }
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak detected");
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try cmdReady(allocator, &.{"--json"});
    } else {
        const cmd = args[1];
        if (findCommand(cmd)) |handler| {
            try handler(allocator, args[2..]);
        } else {
            // Quick add: dot "title"
            try cmdAdd(allocator, args[1..]);
        }
    }

    if (stdout_writer) |*writer| {
        try writer.interface.flush();
    }
}

fn cmdInitWrapper(allocator: Allocator, args: []const []const u8) !void {
    return cmdInit(allocator, args);
}

fn cmdHelp(_: Allocator, _: []const []const u8) !void {
    return stdout().writeAll(USAGE);
}

fn cmdVersion(_: Allocator, _: []const []const u8) !void {
    return stdout().print("dots {s} ({s})\n", .{ build_options.version, build_options.git_hash });
}

fn openStorage(allocator: Allocator) !Storage {
    return Storage.open(allocator);
}

// I/O helpers
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer: ?fs.File.Writer = null;

fn stdout() *std.Io.Writer {
    if (stdout_writer == null) {
        stdout_writer = fs.File.stdout().writer(&stdout_buffer);
    }
    return &stdout_writer.?.interface;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

// ID resolution helper - resolves short ID or exits with error
fn resolveIdOrFatal(storage: *storage_mod.Storage, id: []const u8) []const u8 {
    return storage.resolveId(id) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{id}),
        error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{id}),
        else => fatal("Error resolving ID: {s}\n", .{id}),
    };
}

fn resolveIds(allocator: Allocator, storage: *Storage, ids: []const []const u8) !std.ArrayList([]const u8) {
    var resolved: std.ArrayList([]const u8) = .{};
    errdefer {
        for (resolved.items) |id| allocator.free(id);
        resolved.deinit(allocator);
    }

    for (ids) |id| {
        try resolved.append(allocator, resolveIdOrFatal(storage, id));
    }

    return resolved;
}

// Status parsing helper
fn parseStatusArg(status_str: []const u8) Status {
    return Status.parse(status_str) orelse fatal("Invalid status: {s}\n", .{status_str});
}

// Arg parsing helper
fn getArg(args: []const []const u8, i: *usize, flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, args[i.*], flag) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

const USAGE =
    \\dots - Connect the dots
    \\
    \\Usage: dot [command] [options]
    \\
    \\Commands:
    \\  dot "title"                  Quick add a dot
    \\  dot add "title" [options]    Add a dot (-p priority, -d desc, -P parent, -a after)
    \\  dot ls [--status S] [--json] List dots (--type plan|milestone|task)
    \\  dot on <id>                  Start working (turn it on!)
    \\  dot off <id> [-r reason]     Complete ("cross it off")
    \\  dot rm <id>                  Remove a dot
    \\  dot show <id>                Show dot details
    \\  dot ready [--json]           Show unblocked dots
    \\  dot tree                     Show hierarchy
    \\  dot find "query"             Search dots
    \\  dot purge                    Delete archived dots
    \\  dot init                     Initialize .dots directory
    \\
    \\ExecPlan Commands:
    \\  dot plan "title"             Create a new plan
    \\  dot milestone <plan> "title" Add milestone to a plan
    \\  dot task <milestone> "title" Add task to a milestone
    \\  dot progress <id> "message"  Add progress entry with timestamp
    \\  dot discover <id> "note"     Add to Surprises & Discoveries
    \\  dot decide <id> "decision"   Add to Decision Log
    \\  dot backlog <id>             Move plan to backlog
    \\  dot activate <id>            Move plan from backlog to active
    \\  dot ralph <plan-id>          Generate Ralph execution scaffolding
    \\  dot migrate <path>           Migrate .agent/execplans/ to .dots/
    \\  dot restructure [--dry-run]  Convert legacy hash IDs to hierarchical format
    \\
    \\Examples:
    \\  dot "Fix the bug"
    \\  dot add "Design API" -p 1 -d "REST endpoints"
    \\  dot add "Implement" -P dots-1 -a dots-2
    \\  dot on dots-3
    \\  dot off dots-3 -r "shipped"
    \\  dot plan "User Authentication"
    \\  dot milestone dots-abc "Setup infrastructure"
    \\
;

fn cmdInit(allocator: Allocator, args: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    // Handle --from-jsonl flag for migration
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--from-jsonl")) |jsonl_path| {
            const count = try hydrateFromJsonl(allocator, &storage, jsonl_path);
            if (count > 0) try stdout().print("Imported {d} issues from {s}\n", .{ count, jsonl_path });
        }
    }

    // Add .dots to git if in a git repo
    fs.cwd().access(".git", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    // Run git add .dots
    var child = std.process.Child.init(&.{ "git", "add", DOTS_DIR }, allocator);
    _ = try child.spawnAndWait();
}

fn cmdAdd(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot add <title> [options]\n", .{});

    var title: []const u8 = "";
    var description: []const u8 = "";
    var priority: i64 = default_priority;
    var parent: ?[]const u8 = null;
    var after: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-p")) |v| {
            priority = std.fmt.parseInt(i64, v, 10) catch fatal("Invalid priority: {s}\n", .{v});
        } else if (getArg(args, &i, "-d")) |v| {
            description = v;
        } else if (getArg(args, &i, "-P")) |v| {
            parent = v;
        } else if (getArg(args, &i, "-a")) |v| {
            after = v;
        } else if (title.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            title = args[i];
        }
    }

    if (title.len == 0) fatal("Error: title required\n", .{});
    if (parent != null and after != null and std.mem.eql(u8, parent.?, after.?)) {
        fatal("Error: parent and after cannot be the same issue\n", .{});
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    // Generate standalone task ID: t{n}-{slug}
    const id = try storage.generateStandaloneId(title);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    // Handle after dependency (blocks)
    var blocks: []const []const u8 = &.{};
    var blocks_buf: [1][]const u8 = undefined;
    var resolved_after: ?[]const u8 = null;
    if (after) |after_id| {
        // Resolve short ID if needed
        resolved_after = storage.resolveId(after_id) catch |err| switch (err) {
            error.IssueNotFound => fatal("After issue not found: {s}\n", .{after_id}),
            error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{after_id}),
            else => return err,
        };
        blocks_buf[0] = resolved_after.?;
        blocks = &blocks_buf;
    }
    defer if (resolved_after) |r| allocator.free(r);

    // Resolve parent ID if provided
    var resolved_parent: ?[]const u8 = null;
    if (parent) |parent_id| {
        resolved_parent = storage.resolveId(parent_id) catch |err| switch (err) {
            error.IssueNotFound => fatal("Parent issue not found: {s}\n", .{parent_id}),
            error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{parent_id}),
            else => return err,
        };
    }
    defer if (resolved_parent) |p| allocator.free(p);

    const issue = Issue{
        .id = id,
        .title = title,
        .description = description,
        .status = .open,
        .priority = priority,
        .issue_type = "task",
        .assignee = null,
        .created_at = now,
        .closed_at = null,
        .close_reason = null,
        .blocks = blocks,
    };

    storage.createIssue(issue, resolved_parent) catch |err| switch (err) {
        error.DependencyNotFound => fatal("Parent or after issue not found\n", .{}),
        error.DependencyCycle => fatal("Dependency would create a cycle\n", .{}),
        else => return err,
    };

    const w = stdout();
    if (hasFlag(args, "--json")) {
        try writeIssueJson(issue, w);
        try w.writeByte('\n');
    } else {
        try w.print("{s}\n", .{id});
    }
}

fn cmdList(allocator: Allocator, args: []const []const u8) !void {
    var filter_status: ?Status = null;
    var filter_type: ?[]const u8 = null;
    var include_done = false;
    var include_backlog = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| {
            filter_status = parseStatusArg(v);
        } else if (getArg(args, &i, "--type")) |v| {
            filter_type = v;
        } else if (std.mem.eql(u8, args[i], "--include-done")) {
            include_done = true;
        } else if (std.mem.eql(u8, args[i], "--include-backlog")) {
            include_backlog = true;
        } else if (std.mem.eql(u8, args[i], "--all")) {
            include_done = true;
            include_backlog = true;
        }
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const all_issues = try storage.listIssuesWithOptions(.{
        .status_filter = filter_status,
        .include_done = include_done,
        .include_backlog = include_backlog,
    });
    defer storage_mod.freeIssues(allocator, all_issues);

    // Filter by type if specified
    if (filter_type) |ft| {
        var filtered: std.ArrayList(Issue) = .{};
        defer filtered.deinit(allocator);

        for (all_issues) |issue| {
            if (std.mem.eql(u8, issue.issue_type, ft)) {
                try filtered.append(allocator, issue);
            }
        }

        // skip_done: if include_done is explicitly set, don't skip; otherwise skip closed unless filtering by status
        const skip_done = !include_done and filter_status == null;
        try writeIssueList(filtered.items, skip_done, hasFlag(args, "--json"));
    } else {
        const skip_done = !include_done and filter_status == null;
        try writeIssueList(all_issues, skip_done, hasFlag(args, "--json"));
    }
}

fn cmdReady(allocator: Allocator, args: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.getReadyIssues();
    defer storage_mod.freeIssues(allocator, issues);

    try writeIssueList(issues, false, hasFlag(args, "--json"));
}

fn writeIssueList(issues: []const Issue, skip_done: bool, use_json: bool) !void {
    const w = stdout();
    if (use_json) {
        try w.writeByte('[');
        var first = true;
        for (issues) |issue| {
            if (skip_done and issue.status == .closed) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try writeIssueJson(issue, w);
        }
        try w.writeAll("]\n");
    } else {
        for (issues) |issue| {
            if (skip_done and issue.status == .closed) continue;
            try w.print("[{s}] {c} {s}\n", .{ issue.id, issue.status.char(), issue.title });
        }
    }
}

fn cmdOn(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot on <id> [id2 ...]\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    var resolved_ids = try resolveIds(allocator, &storage, args);
    defer {
        for (resolved_ids.items) |id| allocator.free(id);
        resolved_ids.deinit(allocator);
    }

    for (resolved_ids.items) |id| {
        try storage.updateStatus(id, .active, null, null);
    }
}

fn cmdOff(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot off <id> [id2 ...] [-r reason]\n", .{});

    var reason: ?[]const u8 = null;
    var ids: std.ArrayList([]const u8) = .{};
    defer ids.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-r")) |v| {
            reason = v;
        } else {
            try ids.append(allocator, args[i]);
        }
    }

    if (ids.items.len == 0) fatal("Usage: dot off <id> [id2 ...] [-r reason]\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    var resolved_ids = try resolveIds(allocator, &storage, ids.items);
    defer {
        for (resolved_ids.items) |id| allocator.free(id);
        resolved_ids.deinit(allocator);
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    for (resolved_ids.items) |id| {
        storage.updateStatus(id, .closed, now, reason) catch |err| switch (err) {
            error.ChildrenNotClosed => fatal("Cannot close {s}: children are not all closed\n", .{id}),
            else => return err,
        };
    }
}

fn cmdRm(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot rm <id> [id2 ...]\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    var resolved_ids = try resolveIds(allocator, &storage, args);
    defer {
        for (resolved_ids.items) |id| allocator.free(id);
        resolved_ids.deinit(allocator);
    }

    for (resolved_ids.items) |id| {
        try storage.deleteIssue(id);
    }
}

fn cmdShow(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot show <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    const iss = try storage.getIssue(resolved) orelse fatal("Issue not found: {s}\n", .{args[0]});
    defer iss.deinit(allocator);

    const w = stdout();
    try w.print("ID:       {s}\nTitle:    {s}\nStatus:   {s}\nPriority: {d}\n", .{
        iss.id,
        iss.title,
        iss.status.display(),
        iss.priority,
    });
    if (iss.description.len > 0) try w.print("Desc:     {s}\n", .{iss.description});
    try w.print("Created:  {s}\n", .{iss.created_at});
    if (iss.closed_at) |ca| try w.print("Closed:   {s}\n", .{ca});
    if (iss.close_reason) |r| try w.print("Reason:   {s}\n", .{r});
}

fn cmdTree(allocator: Allocator, _: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    const roots = try storage.getRootIssues();
    defer storage_mod.freeIssues(allocator, roots);

    const w = stdout();
    for (roots, 0..) |root, root_idx| {
        try w.print("[{s}] {s} {s}\n", .{ root.id, root.status.symbol(), root.title });

        const children = try storage.getChildren(root.id);
        defer storage_mod.freeChildIssues(allocator, children);

        const is_last_root = (root_idx == roots.len - 1);

        for (children, 0..) |child, child_idx| {
            const blocked_msg: []const u8 = if (child.blocked) " (blocked)" else "";
            const is_last_child = (child_idx == children.len - 1);
            const child_prefix: []const u8 = if (is_last_child) "  └─" else "  ├─";
            try w.print(
                "{s} [{s}] {s} {s}{s}\n",
                .{ child_prefix, child.issue.id, child.issue.status.symbol(), child.issue.title, blocked_msg },
            );

            // Show grandchildren (tasks under milestones)
            const grandchildren = try storage.getChildren(child.issue.id);
            defer storage_mod.freeChildIssues(allocator, grandchildren);

            const continuation: []const u8 = if (is_last_child) "   " else "  │";
            _ = is_last_root;

            for (grandchildren, 0..) |grandchild, gc_idx| {
                const gc_blocked_msg: []const u8 = if (grandchild.blocked) " (blocked)" else "";
                const is_last_gc = (gc_idx == grandchildren.len - 1);
                const gc_prefix: []const u8 = if (is_last_gc) "  └─" else "  ├─";
                try w.print(
                    "{s}{s} [{s}] {s} {s}{s}\n",
                    .{ continuation, gc_prefix, grandchild.issue.id, grandchild.issue.status.symbol(), grandchild.issue.title, gc_blocked_msg },
                );
            }
        }
    }
}

fn cmdFind(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot find <query>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.searchIssues(args[0]);
    defer storage_mod.freeIssues(allocator, issues);

    const w = stdout();
    for (issues) |issue| {
        try w.print("[{s}] {c} {s}\n", .{ issue.id, issue.status.char(), issue.title });
    }
}

fn cmdUpdate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot update <id> [--status S]\n", .{});

    var new_status: ?Status = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| new_status = parseStatusArg(v);
    }

    const status = new_status orelse fatal("--status required\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    var ts_buf: [40]u8 = undefined;
    const closed_at: ?[]const u8 = if (status == .closed) try formatTimestamp(&ts_buf) else null;

    storage.updateStatus(resolved, status, closed_at, null) catch |err| switch (err) {
        error.ChildrenNotClosed => fatal("Cannot close: children are not all closed\n", .{}),
        else => return err,
    };
}

fn cmdClose(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot close <id> [--reason R]\n", .{});

    var reason: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--reason")) |v| reason = v;
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    storage.updateStatus(resolved, .closed, now, reason) catch |err| switch (err) {
        error.ChildrenNotClosed => fatal("Cannot close: children are not all closed\n", .{}),
        else => return err,
    };
}

fn cmdPurge(allocator: Allocator, _: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.purgeArchive();
    try stdout().writeAll("Archive purged\n");
}

fn formatTimestamp(buf: []u8) ![]const u8 {
    const nanos = std.time.nanoTimestamp();
    if (nanos < 0) return error.InvalidTimestamp;
    const epoch_nanos: u128 = @intCast(nanos);
    const epoch_secs: libc.time_t = std.math.cast(libc.time_t, epoch_nanos / 1_000_000_000) orelse return error.TimestampOverflow;
    const micros: u64 = @intCast((epoch_nanos % 1_000_000_000) / 1000);

    var tm: libc.struct_tm = undefined;
    if (libc.localtime_r(&epoch_secs, &tm) == null) {
        return error.LocaltimeFailed;
    }

    const year: u64 = @intCast(tm.tm_year + 1900);
    const month: u64 = @intCast(tm.tm_mon + 1);
    const day: u64 = @intCast(tm.tm_mday);
    const hours: u64 = @intCast(tm.tm_hour);
    const mins: u64 = @intCast(tm.tm_min);
    const secs: u64 = @intCast(tm.tm_sec);

    const tz_offset_secs: i64 = tm.tm_gmtoff;
    const tz_sign: u8 = if (tz_offset_secs >= 0) '+' else '-';
    const tz_abs: u64 = @abs(tz_offset_secs);
    const tz_hours_abs: u64 = tz_abs / 3600;
    const tz_mins: u64 = (tz_abs % 3600) / 60;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}{c}{d:0>2}:{d:0>2}", .{
        year, month, day, hours, mins, secs, micros, tz_sign, tz_hours_abs, tz_mins,
    });
}

const JsonIssue = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    status: []const u8,
    priority: i64,
    issue_type: []const u8,
    created_at: []const u8,
    closed_at: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
};

fn writeIssueJson(issue: Issue, w: *std.Io.Writer) !void {
    const json_issue = JsonIssue{
        .id = issue.id,
        .title = issue.title,
        .description = if (issue.description.len > 0) issue.description else null,
        .status = issue.status.display(),
        .priority = issue.priority,
        .issue_type = issue.issue_type,
        .created_at = issue.created_at,
        .closed_at = issue.closed_at,
        .close_reason = issue.close_reason,
    };
    try std.json.Stringify.value(json_issue, .{}, w);
}

// ExecPlan command handlers

// Plan template for new plans
const plan_template =
    \\## Purpose / Big Picture
    \\
    \\[What someone gains after this change]
    \\
    \\## Milestones
    \\
    \\[Auto-populated as milestones are added]
    \\
    \\## Progress
    \\
    \\## Surprises & Discoveries
    \\
    \\## Decision Log
    \\
    \\## Context and Orientation
    \\
    \\[Current state, key files, definitions]
    \\
    \\## Plan of Work
    \\
    \\[Narrative describing the sequence of edits]
    \\
    \\## Validation and Acceptance
    \\
    \\[How to verify success]
    \\
    \\## Idempotence and Recovery
    \\
    \\[Safe retry/rollback paths]
    \\
    \\## Outcomes & Retrospective
    \\
    \\[Filled at completion]
;

const milestone_template =
    \\## Goal
    \\
    \\[What will exist at the end of this milestone]
    \\
    \\## Tasks
    \\
    \\[Auto-populated as tasks are added]
    \\
    \\## Notes
    \\
    \\## Outcomes & Retrospective
    \\
    \\[Filled at completion]
;

const task_template =
    \\## Description
    \\
    \\[What to do, concrete steps, expected output]
    \\
    \\## Acceptance Criteria
    \\
    \\- [ ] [Criterion 1]
    \\- [ ] [Criterion 2]
    \\
    \\## Outcomes & Retrospective
    \\
    \\[Filled at completion]
;

fn cmdPlan(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot plan <title> [-s scope] [-a acceptance]\n", .{});

    var title: []const u8 = "";
    var scope: ?[]const u8 = null;
    var acceptance: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-s")) |v| {
            scope = v;
        } else if (getArg(args, &i, "-a")) |v| {
            acceptance = v;
        } else if (title.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            title = args[i];
        }
    }

    if (title.len == 0) fatal("Error: title required\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    // Generate hierarchical plan ID: p{n}-{slug}
    const id = try storage.generatePlanId(title);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    const issue = Issue{
        .id = id,
        .title = title,
        .description = plan_template,
        .status = .open,
        .priority = default_priority,
        .issue_type = "plan",
        .assignee = null,
        .created_at = now,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .scope = scope,
        .acceptance = acceptance,
    };

    // Create plan with artifacts folder and done subfolder
    try storage.createPlanWithArtifacts(issue);
    try stdout().print("{s}\n", .{id});
}

fn cmdMilestone(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 2) fatal("Usage: dot milestone <plan-id> <title>\n", .{});

    const plan_id_arg = args[0];
    const title = args[1];

    var storage = try openStorage(allocator);
    defer storage.close();

    // Resolve the plan ID
    const plan_id = resolveIdOrFatal(&storage, plan_id_arg);
    defer allocator.free(plan_id);

    // Verify it's a plan
    const plan = try storage.getIssue(plan_id) orelse fatal("Plan not found: {s}\n", .{plan_id_arg});
    defer plan.deinit(allocator);
    if (!std.mem.eql(u8, plan.issue_type, "plan")) {
        fatal("Error: {s} is not a plan (type: {s})\n", .{ plan_id, plan.issue_type });
    }

    // Generate hierarchical milestone ID: m{n}-{slug}
    const id = try storage.generateMilestoneId(plan_id, title);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    const issue = Issue{
        .id = id,
        .title = title,
        .description = milestone_template,
        .status = .open,
        .priority = default_priority,
        .issue_type = "milestone",
        .assignee = null,
        .created_at = now,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .scope = null,
        .acceptance = null,
    };

    // Create milestone folder within plan
    try storage.createMilestoneWithFolder(issue, plan_id);
    try stdout().print("{s}\n", .{id});
}

fn cmdTask(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 2) fatal("Usage: dot task <milestone-id> <title>\n", .{});

    const milestone_id_arg = args[0];
    const title = args[1];

    var storage = try openStorage(allocator);
    defer storage.close();

    // Resolve the milestone ID
    const milestone_id = resolveIdOrFatal(&storage, milestone_id_arg);
    defer allocator.free(milestone_id);

    // Verify it's a milestone and get its parent plan
    const milestone = try storage.getIssue(milestone_id) orelse fatal("Milestone not found: {s}\n", .{milestone_id_arg});
    defer milestone.deinit(allocator);
    if (!std.mem.eql(u8, milestone.issue_type, "milestone")) {
        fatal("Error: {s} is not a milestone (type: {s})\n", .{ milestone_id, milestone.issue_type });
    }

    // Get the parent plan ID from milestone
    const plan_id = milestone.parent orelse fatal("Milestone {s} has no parent plan\n", .{milestone_id});

    // Generate hierarchical task ID: t{n}-{slug}
    const id = try storage.generateTaskId(plan_id, milestone_id, title);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    const issue = Issue{
        .id = id,
        .title = title,
        .description = task_template,
        .status = .open,
        .priority = default_priority,
        .issue_type = "task",
        .assignee = null,
        .created_at = now,
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
        .scope = null,
        .acceptance = null,
    };

    // Create task file within milestone folder
    try storage.createTaskInMilestone(issue, plan_id, milestone_id);
    try stdout().print("{s}\n", .{id});
}

fn cmdProgress(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 2) fatal("Usage: dot progress <id> <message>\n", .{});

    const id_arg = args[0];
    const message = args[1];

    var storage = try openStorage(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, id_arg);
    defer allocator.free(id);

    var issue = try storage.getIssue(id) orelse fatal("Issue not found: {s}\n", .{id_arg});
    defer issue.deinit(allocator);

    // Format timestamp for progress entry
    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    // Append progress entry to description
    const progress_entry = try std.fmt.allocPrint(allocator, "\n- [x] ({s}) {s}", .{ now, message });
    defer allocator.free(progress_entry);

    // Find ## Progress section and append
    const new_desc = try appendToSection(allocator, issue.description, "## Progress", progress_entry);
    defer allocator.free(new_desc);

    // Rewrite the file with updated description
    try updateIssueDescription(&storage, allocator, id, new_desc);
    try stdout().print("Progress added to {s}\n", .{id});
}

fn cmdDiscover(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 2) fatal("Usage: dot discover <id> <observation>\n", .{});

    const id_arg = args[0];
    const observation = args[1];

    var storage = try openStorage(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, id_arg);
    defer allocator.free(id);

    var issue = try storage.getIssue(id) orelse fatal("Issue not found: {s}\n", .{id_arg});
    defer issue.deinit(allocator);

    // Format timestamp for discovery entry
    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    // Append discovery entry to description
    const entry = try std.fmt.allocPrint(allocator, "\n- Observation ({s}): {s}\n  Evidence: [TODO]", .{ now, observation });
    defer allocator.free(entry);

    // Find ## Surprises & Discoveries section and append
    const new_desc = try appendToSection(allocator, issue.description, "## Surprises & Discoveries", entry);
    defer allocator.free(new_desc);

    try updateIssueDescription(&storage, allocator, id, new_desc);
    try stdout().print("Discovery added to {s}\n", .{id});
}

fn cmdDecide(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 2) fatal("Usage: dot decide <id> <decision>\n", .{});

    const id_arg = args[0];
    const decision = args[1];

    var storage = try openStorage(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, id_arg);
    defer allocator.free(id);

    var issue = try storage.getIssue(id) orelse fatal("Issue not found: {s}\n", .{id_arg});
    defer issue.deinit(allocator);

    // Format timestamp for decision entry
    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    // Append decision entry to description
    const entry = try std.fmt.allocPrint(allocator, "\n- Decision ({s}): {s}\n  Rationale: [TODO]", .{ now, decision });
    defer allocator.free(entry);

    // Find ## Decision Log section and append
    const new_desc = try appendToSection(allocator, issue.description, "## Decision Log", entry);
    defer allocator.free(new_desc);

    try updateIssueDescription(&storage, allocator, id, new_desc);
    try stdout().print("Decision added to {s}\n", .{id});
}

fn cmdBacklog(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot backlog <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(id);

    // Verify it's a plan
    const issue = try storage.getIssue(id) orelse fatal("Issue not found: {s}\n", .{args[0]});
    defer issue.deinit(allocator);
    if (!std.mem.eql(u8, issue.issue_type, "plan")) {
        fatal("Error: only plans can be moved to backlog\n", .{});
    }

    // Move to backlog directory
    try storage.moveToBacklog(id);
    try stdout().print("Moved {s} to backlog\n", .{id});
}

fn cmdActivate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot activate <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(id);

    // Activate from backlog
    try storage.activateFromBacklog(id);
    try stdout().print("Activated {s} from backlog\n", .{id});
}

fn cmdRalph(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot ralph <plan-id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(id);

    // Verify it's a plan
    const plan = try storage.getIssue(id) orelse fatal("Plan not found: {s}\n", .{args[0]});
    defer plan.deinit(allocator);
    if (!std.mem.eql(u8, plan.issue_type, "plan")) {
        fatal("Error: {s} is not a plan (type: {s})\n", .{ id, plan.issue_type });
    }

    // Create ralph directory inside the plan folder
    const ralph_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/ralph", .{ DOTS_DIR, id });
    defer allocator.free(ralph_dir);

    fs.cwd().makePath(ralph_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // OK if exists
        else => return err,
    };

    // Get project prefix for naming
    const prefix = try storage_mod.getOrCreatePrefix(allocator, &storage);
    defer allocator.free(prefix);

    // Collect milestones and tasks
    const children = try storage.getChildren(id);
    defer storage_mod.freeChildIssues(allocator, children);

    // Build tasks.json structure
    var tasks_json: std.ArrayList(u8) = .{};
    defer tasks_json.deinit(allocator);

    const w = tasks_json.writer(allocator);
    try w.writeAll("{\n");
    try w.print("  \"name\": \"{s}\",\n", .{escapeJsonString(plan.title)});
    try w.print("  \"description\": \"Plan: {s}\",\n", .{escapeJsonString(plan.title)});
    try w.print("  \"execplan\": \".dots/{s}/{s}.md\",\n", .{ id, id });
    try w.writeAll("  \"tasks\": [\n");

    var task_count: usize = 0;
    var task_num: usize = 1;
    for (children) |child| {
        if (!std.mem.eql(u8, child.issue.issue_type, "milestone")) continue;

        // Get tasks under this milestone
        const milestone_children = try storage.getChildren(child.issue.id);
        defer storage_mod.freeChildIssues(allocator, milestone_children);

        for (milestone_children) |task_child| {
            if (!std.mem.eql(u8, task_child.issue.issue_type, "task")) continue;

            if (task_count > 0) try w.writeAll(",\n");
            try w.writeAll("    {\n");
            try w.print("      \"id\": \"TASK-{d:0>3}\",\n", .{task_num});
            try w.print("      \"title\": \"{s}\",\n", .{escapeJsonString(task_child.issue.title)});
            try w.print("      \"priority\": {d},\n", .{task_child.issue.priority});
            try w.print("      \"done\": {s},\n", .{if (task_child.issue.status == .closed) "true" else "false"});
            try w.print("      \"milestone\": \"{s}\",\n", .{child.issue.id});
            try w.print("      \"dotId\": \"{s}\",\n", .{task_child.issue.id});
            try w.writeAll("      \"description\": \"\",\n");
            try w.writeAll("      \"acceptanceCriteria\": [],\n");
            try w.writeAll("      \"verify\": \"\",\n");
            try w.writeAll("      \"notes\": \"\"\n");
            try w.writeAll("    }");

            task_count += 1;
            task_num += 1;
        }
    }

    try w.writeAll("\n  ]\n}\n");

    // Write tasks.json
    const tasks_path = try std.fmt.allocPrint(allocator, "{s}/tasks.json", .{ralph_dir});
    defer allocator.free(tasks_path);
    const tasks_file = try fs.cwd().createFile(tasks_path, .{});
    defer tasks_file.close();
    try tasks_file.writeAll(tasks_json.items);

    // Write ralph.sh
    const ralph_sh_path = try std.fmt.allocPrint(allocator, "{s}/ralph.sh", .{ralph_dir});
    defer allocator.free(ralph_sh_path);
    const ralph_sh = try fs.cwd().createFile(ralph_sh_path, .{ .mode = 0o755 });
    defer ralph_sh.close();
    const ralph_sh_content = try std.fmt.allocPrint(allocator,
        \\#!/bin/bash
        \\# Ralph execution script for: {s}
        \\# Generated by: dot ralph {s}
        \\
        \\set -euo pipefail
        \\
        \\SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
        \\PLAN_ID="{s}"
        \\TASKS_FILE="$SCRIPT_DIR/tasks.json"
        \\PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
        \\PROMPT_FILE="$SCRIPT_DIR/prompt.md"
        \\
        \\# Initialize progress file if not exists
        \\if [ ! -f "$PROGRESS_FILE" ]; then
        \\    echo "# Ralph Progress for $PLAN_ID" > "$PROGRESS_FILE"
        \\    echo "Started: $(date -Iseconds)" >> "$PROGRESS_FILE"
        \\    echo "" >> "$PROGRESS_FILE"
        \\fi
        \\
        \\# Log progress
        \\log_progress() {{
        \\    echo "[$(date -Iseconds)] $1" >> "$PROGRESS_FILE"
        \\}}
        \\
        \\# Mark task complete in dots
        \\complete_task() {{
        \\    local dot_id="$1"
        \\    dot off "$dot_id" -r "Completed by Ralph"
        \\    log_progress "Completed: $dot_id"
        \\}}
        \\
        \\echo "Ralph execution environment ready for plan: {s}"
        \\echo "Tasks file: $TASKS_FILE"
        \\echo "Progress: $PROGRESS_FILE"
        \\echo "Prompt: $PROMPT_FILE"
        \\
    , .{ plan.title, id, id, plan.title });
    defer allocator.free(ralph_sh_content);
    try ralph_sh.writeAll(ralph_sh_content);

    // Write prompt.md
    const prompt_path = try std.fmt.allocPrint(allocator, "{s}/prompt.md", .{ralph_dir});
    defer allocator.free(prompt_path);
    const prompt_file = try fs.cwd().createFile(prompt_path, .{});
    defer prompt_file.close();
    const prompt_content = try std.fmt.allocPrint(allocator,
        \\# Ralph Execution Prompt
        \\
        \\## Plan: {s}
        \\
        \\You are Ralph, an autonomous execution agent. Your task is to execute the plan
        \\defined in `.dots/{s}/{s}.md`.
        \\
        \\## Instructions
        \\
        \\1. Read the ExecPlan at the path above
        \\2. Process tasks from `tasks.json` in priority order
        \\3. For each task:
        \\   - Read the task details
        \\   - Execute the required changes
        \\   - Run any verification commands
        \\   - Mark complete with `dot off <dot-id> -r "reason"`
        \\4. Log progress to `progress.txt`
        \\5. Stop if you encounter blockers or need human input
        \\
        \\## Project Context
        \\
        \\Project prefix: {s}
        \\Plan ID: {s}
        \\Total tasks: {d}
        \\
        \\## Safety
        \\
        \\- Do not proceed if acceptance criteria are unclear
        \\- Create checkpoints before destructive operations
        \\- Ask for clarification rather than guessing
        \\
    , .{ plan.title, id, id, prefix, id, task_count });
    defer allocator.free(prompt_content);
    try prompt_file.writeAll(prompt_content);

    // Write progress.txt
    const progress_path = try std.fmt.allocPrint(allocator, "{s}/progress.txt", .{ralph_dir});
    defer allocator.free(progress_path);
    const progress_file = try fs.cwd().createFile(progress_path, .{});
    defer progress_file.close();

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);
    const progress_content = try std.fmt.allocPrint(allocator,
        \\# Ralph Progress for {s}
        \\
        \\Generated: {s}
        \\Plan: {s}
        \\Tasks: {d}
        \\
        \\## Execution Log
        \\
    , .{ id, now, plan.title, task_count });
    defer allocator.free(progress_content);
    try progress_file.writeAll(progress_content);

    try stdout().print("Ralph scaffolding created at {s}/\n", .{ralph_dir});
    try stdout().print("  tasks.json    - {d} tasks extracted\n", .{task_count});
    try stdout().print("  ralph.sh      - execution script\n", .{});
    try stdout().print("  prompt.md     - agent prompt\n", .{});
    try stdout().print("  progress.txt  - progress tracking\n", .{});
}

fn escapeJsonString(s: []const u8) []const u8 {
    // Simple passthrough - in production would escape special chars
    // For now, trust that titles don't contain JSON-breaking characters
    return s;
}

fn cmdMigrate(allocator: Allocator, args: []const []const u8) !void {
    const source_path = if (args.len > 0) args[0] else ".agent/execplans";

    // Check if source exists
    var source_dir = fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => fatal("Source directory not found: {s}\n", .{source_path}),
        else => return err,
    };
    defer source_dir.close();

    // Ensure .dots exists
    var storage = try openStorage(allocator);
    defer storage.close();

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var migrated_count: usize = 0;

    // Iterate through source directory for .md files
    var iter = source_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        // Read the file
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_path, entry.name });
        defer allocator.free(file_path);

        const content = fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
            std.debug.print("Warning: Could not read {s}: {any}\n", .{ file_path, err });
            continue;
        };
        defer allocator.free(content);

        // Extract title from filename (remove .md extension)
        const title = entry.name[0 .. entry.name.len - 3];

        // Generate hierarchical plan ID: p{n}-{slug}
        const id = try storage.generatePlanId(title);
        defer allocator.free(id);

        // Create as a plan
        const issue = Issue{
            .id = id,
            .title = title,
            .description = content,
            .status = .open,
            .priority = default_priority,
            .issue_type = "plan",
            .assignee = null,
            .created_at = now,
            .closed_at = null,
            .close_reason = null,
            .blocks = &.{},
            .scope = null,
            .acceptance = null,
        };

        storage.createPlanWithArtifacts(issue) catch |err| {
            std.debug.print("Warning: Could not create plan for {s}: {any}\n", .{ title, err });
            continue;
        };

        try stdout().print("Migrated: {s} -> {s}\n", .{ entry.name, id });
        migrated_count += 1;
    }

    try stdout().print("\nMigration complete: {d} plans imported\n", .{migrated_count});
    if (migrated_count > 0) {
        try stdout().print("Original files preserved at: {s}\n", .{source_path});
    }
}

/// Restructure flat .dots/ directory to hierarchical format
/// Migrates: {hash-id}/{hash-id}.md -> p{n}-{slug}/_plan.md (and children)
fn cmdRestructure(allocator: Allocator, args: []const []const u8) !void {
    const dry_run = hasFlag(args, "--dry-run");

    // Check if .dots exists
    var dots_dir = fs.cwd().openDir(DOTS_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => fatal("No .dots directory found\n", .{}),
        else => return err,
    };
    defer dots_dir.close();

    if (dry_run) {
        try stdout().print("=== DRY RUN - No changes will be made ===\n\n", .{});
    } else {
        // Create backup before restructuring
        try stdout().print("Creating backup at .dots.bak/...\n", .{});
        fs.cwd().deleteTree(".dots.bak") catch {};
        const argv = [_][]const u8{ "cp", "-r", ".dots", ".dots.bak" };
        var backup_result = std.process.Child.init(&argv, allocator);
        _ = try backup_result.spawn();
        _ = try backup_result.wait();
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    // Get all issues with legacy hash IDs
    const all_issues = try storage.listIssues(null);
    defer storage_mod.freeIssues(allocator, all_issues);

    // Build parent-child relationships
    var children_map = std.StringHashMap(std.ArrayList(Issue)).init(allocator);
    defer {
        var it = children_map.valueIterator();
        while (it.next()) |list| {
            list.deinit(allocator);
        }
        children_map.deinit();
    }

    var root_issues: std.ArrayList(Issue) = .{};
    defer root_issues.deinit(allocator);

    for (all_issues) |issue| {
        if (issue.parent) |parent_id| {
            var gop = try children_map.getOrPut(parent_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.append(allocator, issue);
        } else {
            try root_issues.append(allocator, issue);
        }
    }

    // Track ID mappings: old hash ID -> new hierarchical ID
    var id_mapping = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = id_mapping.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        id_mapping.deinit();
    }

    var plan_count: usize = 0;
    var milestone_count: usize = 0;
    var task_count: usize = 0;

    // Process root issues (plans or standalone items)
    for (root_issues.items) |issue| {
        // Check if this looks like a legacy hash ID (contains only hex after prefix)
        if (!isLegacyHashId(issue.id)) {
            try stdout().print("Skipping (already new format): {s}\n", .{issue.id});
            continue;
        }

        const issue_type = issue.issue_type;
        if (std.mem.eql(u8, issue_type, "plan")) {
            // Create new plan with hierarchical ID
            const new_id = try storage_mod.generateHierarchicalId(allocator, storage.dots_dir, "plan", issue.title);
            defer allocator.free(new_id);

            try id_mapping.put(issue.id, try allocator.dupe(u8, new_id));
            plan_count += 1;

            try stdout().print("Plan: {s} -> {s} ({s})\n", .{ issue.id, new_id, issue.title });

            if (!dry_run) {
                // Create new plan structure
                const new_issue = Issue{
                    .id = new_id,
                    .title = issue.title,
                    .description = issue.description,
                    .status = issue.status,
                    .priority = issue.priority,
                    .issue_type = "plan",
                    .assignee = issue.assignee,
                    .created_at = issue.created_at,
                    .closed_at = issue.closed_at,
                    .close_reason = issue.close_reason,
                    .blocks = issue.blocks,
                    .scope = issue.scope,
                    .acceptance = issue.acceptance,
                    .parent = null,
                };
                try storage.createPlanWithArtifacts(new_issue);

                // Process milestones (children of plan)
                if (children_map.get(issue.id)) |milestones| {
                    for (milestones.items) |ms| {
                        const ms_new_id = try storage_mod.generateHierarchicalIdInDir(
                            allocator,
                            storage.dots_dir,
                            new_id,
                            .milestone,
                            ms.title,
                        );
                        defer allocator.free(ms_new_id);

                        try id_mapping.put(ms.id, try allocator.dupe(u8, ms_new_id));
                        milestone_count += 1;

                        try stdout().print("  Milestone: {s} -> {s} ({s})\n", .{ ms.id, ms_new_id, ms.title });

                        const ms_issue = Issue{
                            .id = ms_new_id,
                            .title = ms.title,
                            .description = ms.description,
                            .status = ms.status,
                            .priority = ms.priority,
                            .issue_type = "milestone",
                            .assignee = ms.assignee,
                            .created_at = ms.created_at,
                            .closed_at = ms.closed_at,
                            .close_reason = ms.close_reason,
                            .blocks = ms.blocks,
                            .scope = ms.scope,
                            .acceptance = ms.acceptance,
                            .parent = new_id,
                        };
                        try storage.createMilestoneWithFolder(ms_issue, new_id);

                        // Process tasks (children of milestone)
                        if (children_map.get(ms.id)) |tasks| {
                            for (tasks.items) |t| {
                                // Build milestone dir path
                                var ms_dir_buf: [512]u8 = undefined;
                                const ms_dir_path = std.fmt.bufPrint(&ms_dir_buf, "{s}/{s}", .{ new_id, ms_new_id }) catch continue;

                                const t_new_id = try storage_mod.generateHierarchicalIdInDir(
                                    allocator,
                                    storage.dots_dir,
                                    ms_dir_path,
                                    .task,
                                    t.title,
                                );
                                defer allocator.free(t_new_id);

                                try id_mapping.put(t.id, try allocator.dupe(u8, t_new_id));
                                task_count += 1;

                                try stdout().print("    Task: {s} -> {s} ({s})\n", .{ t.id, t_new_id, t.title });

                                const t_issue = Issue{
                                    .id = t_new_id,
                                    .title = t.title,
                                    .description = t.description,
                                    .status = t.status,
                                    .priority = t.priority,
                                    .issue_type = "task",
                                    .assignee = t.assignee,
                                    .created_at = t.created_at,
                                    .closed_at = t.closed_at,
                                    .close_reason = t.close_reason,
                                    .blocks = t.blocks,
                                    .scope = t.scope,
                                    .acceptance = t.acceptance,
                                    .parent = ms_new_id,
                                };
                                try storage.createTaskInMilestone(t_issue, new_id, ms_new_id);
                            }
                        }
                    }
                }
            }
        } else {
            // Non-plan root item - treat as standalone
            try stdout().print("Standalone: {s} (type: {s}) - skipping\n", .{ issue.id, issue_type });
        }
    }

    try stdout().print("\n", .{});
    if (dry_run) {
        try stdout().print("=== DRY RUN COMPLETE ===\n", .{});
        try stdout().print("Would restructure: {d} plans, {d} milestones, {d} tasks\n", .{ plan_count, milestone_count, task_count });
        try stdout().print("Run without --dry-run to apply changes\n", .{});
    } else {
        try stdout().print("Restructure complete: {d} plans, {d} milestones, {d} tasks\n", .{ plan_count, milestone_count, task_count });
        try stdout().print("Backup saved at .dots.bak/\n", .{});
        try stdout().print("\nNote: Old hash-ID files are still present. After verifying the migration,\n", .{});
        try stdout().print("you can manually delete them or run: rm -rf .dots.bak\n", .{});
    }
}

/// Check if an ID looks like a legacy hash ID (prefix-16hexchars)
fn isLegacyHashId(id: []const u8) bool {
    // Legacy format: {prefix}-{16 hex chars}
    // New format: p{n}-{slug}, m{n}-{slug}, t{n}-{slug}
    if (id.len < 18) return false; // Minimum: x-1234567890abcdef

    // Find the dash
    const dash_idx = std.mem.indexOf(u8, id, "-") orelse return false;
    if (dash_idx == 0) return false;

    const suffix = id[dash_idx + 1 ..];

    // Legacy IDs have exactly 16 hex chars after the dash
    if (suffix.len != 16) return false;

    // Check if all chars are hex
    for (suffix) |c| {
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

// Helper to append content to a markdown section
fn appendToSection(allocator: Allocator, description: []const u8, section: []const u8, content: []const u8) ![]u8 {
    // Find the section
    const section_idx = std.mem.indexOf(u8, description, section);
    if (section_idx == null) {
        // Section not found, append it with content
        return std.fmt.allocPrint(allocator, "{s}\n\n{s}\n{s}", .{ description, section, content });
    }

    const idx = section_idx.?;
    // Find the end of the section (next ## or end of file)
    const after_section = description[idx + section.len ..];
    const next_section_idx = std.mem.indexOf(u8, after_section, "\n## ");

    if (next_section_idx) |next_idx| {
        // Insert content before the next section
        const insert_point = idx + section.len + next_idx;
        return std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{
            description[0..insert_point],
            content,
            description[insert_point..],
        });
    } else {
        // Append to end of description
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ description, content });
    }
}

// Helper to update issue description by rewriting the file
fn updateIssueDescription(storage: *Storage, allocator: Allocator, id: []const u8, new_description: []const u8) !void {
    const issue = try storage.getIssue(id) orelse return error.IssueNotFound;
    defer issue.deinit(allocator);

    // Create updated issue with new description
    const updated = Issue{
        .id = issue.id,
        .title = issue.title,
        .description = new_description,
        .status = issue.status,
        .priority = issue.priority,
        .issue_type = issue.issue_type,
        .assignee = issue.assignee,
        .created_at = issue.created_at,
        .closed_at = issue.closed_at,
        .close_reason = issue.close_reason,
        .blocks = issue.blocks,
        .scope = issue.scope,
        .acceptance = issue.acceptance,
        .parent = issue.parent,
    };

    try storage.updateIssue(updated);
}

// Claude Code hook handlers
fn cmdHook(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot hook <session|sync>\n", .{});

    const hook_map = std.StaticStringMap(*const fn (Allocator) anyerror!void).initComptime(.{
        .{ "session", hookSession },
        .{ "sync", hookSync },
    });

    const handler = hook_map.get(args[0]) orelse fatal("Unknown hook: {s}\n", .{args[0]});
    try handler(allocator);
}

fn hookSession(allocator: Allocator) !void {
    // Check if .dots exists
    fs.cwd().access(DOTS_DIR, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    var storage = try openStorage(allocator);
    defer storage.close();

    const all_issues = try storage.listIssues(null);
    defer storage_mod.freeIssues(allocator, all_issues);

    // Separate by type and status
    var active_plans: std.ArrayList(Issue) = .{};
    defer active_plans.deinit(allocator);
    var active_tasks: std.ArrayList(Issue) = .{};
    defer active_tasks.deinit(allocator);
    var ready_tasks: std.ArrayList(Issue) = .{};
    defer ready_tasks.deinit(allocator);

    // Build status map for blocking check
    var status_by_id = std.StringHashMap(Status).init(allocator);
    defer status_by_id.deinit();
    for (all_issues) |issue| {
        try status_by_id.put(issue.id, issue.status);
    }

    for (all_issues) |issue| {
        if (issue.status == .closed) continue;

        const is_plan = std.mem.eql(u8, issue.issue_type, "plan");
        const is_active = issue.status == .active;

        if (is_plan and (is_active or issue.status == .open)) {
            try active_plans.append(allocator, issue);
        } else if (is_active) {
            try active_tasks.append(allocator, issue);
        } else if (issue.status == .open) {
            // Check if blocked
            var blocked = false;
            for (issue.blocks) |blocker_id| {
                const status = status_by_id.get(blocker_id) orelse continue;
                if (status == .open or status == .active) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked) {
                try ready_tasks.append(allocator, issue);
            }
        }
    }

    if (active_plans.items.len == 0 and active_tasks.items.len == 0 and ready_tasks.items.len == 0) return;

    const w = stdout();
    try w.writeAll("--- DOTS ---\n");

    // Show active plans first
    if (active_plans.items.len > 0) {
        try w.writeAll("PLANS:\n");
        for (active_plans.items) |p| {
            const status_char = p.status.char();
            try w.print("  [{s}] {c} {s}\n", .{ p.id, status_char, p.title });
        }
    }

    // Show active tasks
    if (active_tasks.items.len > 0) {
        try w.writeAll("ACTIVE:\n");
        for (active_tasks.items) |d| try w.print("  [{s}] {s}\n", .{ d.id, d.title });
    }

    // Show ready tasks
    if (ready_tasks.items.len > 0) {
        try w.writeAll("READY:\n");
        for (ready_tasks.items) |d| try w.print("  [{s}] {s}\n", .{ d.id, d.title });
    }
}

const Mapping = mapping_util.Mapping;

const HookEnvelope = struct {
    tool_name: []const u8,
    tool_input: ?std.json.Value = null,
};

const HookTodoInput = struct {
    todos: []const HookTodo,
};

const HookTodo = struct {
    content: []const u8,
    status: []const u8,
    activeForm: ?[]const u8 = null,
};

fn parseJsonSliceOrError(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    invalid_err: anyerror,
    options: std.json.ParseOptions,
) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, input, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return invalid_err,
    };
}

fn parseJsonValueOrError(
    comptime T: type,
    allocator: Allocator,
    input: std.json.Value,
    invalid_err: anyerror,
    options: std.json.ParseOptions,
) !std.json.Parsed(T) {
    return std.json.parseFromValue(T, allocator, input, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return invalid_err,
    };
}

const hook_status_map = std.StaticStringMap(void).initComptime(.{
    .{ "pending", {} },
    .{ "in_progress", {} },
    .{ "completed", {} },
});

fn validateHookStatus(status: []const u8) bool {
    return hook_status_map.has(status);
}

fn hookSync(allocator: Allocator) !void {
    // Read stdin with timeout to avoid blocking forever when Claude Code
    // doesn't provide input (known bug: github.com/anthropics/claude-code/issues/6403)
    const stdin = fs.File.stdin();
    const stdin_fd = stdin.handle;

    // If stdin is a TTY, no hook input expected
    if (std.posix.isatty(stdin_fd)) return;

    // Poll for data with 100ms timeout
    var fds = [_]std.posix.pollfd{.{
        .fd = stdin_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const poll_result = std.posix.poll(&fds, 100) catch return;
    if (poll_result == 0) return; // Timeout, no data
    if (fds[0].revents & std.posix.POLL.IN == 0) return; // No data available

    const input = try stdin.readToEndAlloc(allocator, max_hook_input_bytes);
    defer allocator.free(input);
    if (input.len == 0) return;

    // Parse JSON
    const parsed = try parseJsonSliceOrError(
        HookEnvelope,
        allocator,
        input,
        error.InvalidHookInput,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.tool_name, "TodoWrite")) return;
    const tool_input = parsed.value.tool_input orelse return error.InvalidHookInput;

    const parsed_input = try parseJsonValueOrError(
        HookTodoInput,
        allocator,
        tool_input,
        error.InvalidHookInput,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed_input.deinit();
    const todos = parsed_input.value.todos;

    // Validate all todos before any operations
    for (todos) |todo| {
        if (todo.content.len == 0) return error.InvalidHookInput;
        if (!validateHookStatus(todo.status)) return error.InvalidHookInput;
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    // Load mapping
    var mapping = try loadMapping(allocator);
    defer mapping_util.deinit(allocator, &mapping);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    // Process todos
    for (todos) |todo| {
        const content = todo.content;
        const status = todo.status;

        if (std.mem.eql(u8, status, "completed")) {
            // Mark as done if we have mapping
            const dot_id = mapping.map.get(content) orelse return error.MissingTodoMapping;
            try storage.updateStatus(dot_id, .closed, now, "Completed via TodoWrite");
            if (mapping.map.fetchOrderedRemove(content)) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
        } else if (mapping.map.get(content)) |dot_id| {
            // Update status if changed
            const new_status: Status = if (std.mem.eql(u8, status, "in_progress")) .active else .open;
            try storage.updateStatus(dot_id, new_status, null, null);
        } else {
            // Create new dot with standalone task ID: t{n}-{slug}
            const id = try storage.generateStandaloneId(content);
            defer allocator.free(id);
            const desc = todo.activeForm orelse "";
            const priority: i64 = if (std.mem.eql(u8, status, "in_progress")) 1 else default_priority;

            const issue = Issue{
                .id = id,
                .title = content,
                .description = desc,
                .status = if (std.mem.eql(u8, status, "in_progress")) .active else .open,
                .priority = priority,
                .issue_type = "task",
                .assignee = null,
                .created_at = now,
                .closed_at = null,
                .close_reason = null,
                .blocks = &.{},
            };

            try storage.createIssue(issue, null);

            // Save mapping
            const key = try allocator.dupe(u8, content);
            const val = allocator.dupe(u8, id) catch |err| {
                allocator.free(key);
                return err;
            };
            mapping.map.put(allocator, key, val) catch |err| {
                allocator.free(key);
                allocator.free(val);
                return err;
            };
        }
    }

    // Save mapping
    try saveMappingAtomic(mapping);
}

fn loadMapping(allocator: Allocator) !Mapping {
    var map: Mapping = .{};
    errdefer mapping_util.deinit(allocator, &map);

    const file = fs.cwd().openFile(MAPPING_FILE, .{}) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, max_mapping_bytes);
    defer allocator.free(content);

    const parsed = try parseJsonSliceOrError(
        Mapping,
        allocator,
        content,
        error.InvalidMapping,
        .{ .ignore_unknown_fields = false },
    );
    defer parsed.deinit();

    var it = parsed.value.map.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const val = allocator.dupe(u8, entry.value_ptr.*) catch |err| {
            allocator.free(key);
            return err;
        };
        map.map.put(allocator, key, val) catch |err| {
            allocator.free(key);
            allocator.free(val);
            return err;
        };
    }

    return map;
}

fn saveMappingAtomic(map: Mapping) !void {
    const tmp_file = MAPPING_FILE ++ ".tmp";

    // Write to temp file
    const file = try fs.cwd().createFile(tmp_file, .{});
    defer file.close();
    errdefer fs.cwd().deleteFile(tmp_file) catch |err| switch (err) {
        error.FileNotFound => {}, // Already deleted
        else => {}, // Best effort cleanup
    };

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const w = &file_writer.interface;
    try std.json.Stringify.value(map, .{}, w);
    try w.flush();
    try file.sync();

    // Atomic rename
    try fs.cwd().rename(tmp_file, MAPPING_FILE);
}

// JSONL hydration for migration
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

fn hydrateFromJsonl(allocator: Allocator, storage: *Storage, jsonl_path: []const u8) !usize {
    const file = fs.cwd().openFile(jsonl_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close();

    var count: usize = 0;
    const read_buf = try allocator.alloc(u8, max_jsonl_line_bytes);
    defer allocator.free(read_buf);
    var file_reader = fs.File.Reader.init(file, read_buf);
    const reader = &file_reader.interface;

    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.JsonlLineTooLong,
            error.ReadFailed => break,
        } orelse break;

        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(JsonlIssue, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJsonl,
        };
        defer parsed.deinit();

        const obj = parsed.value;

        // Normalize status
        const status = Status.parse(obj.status) orelse blk: {
            if (std.mem.eql(u8, obj.status, "in_progress")) break :blk Status.active;
            if (std.mem.eql(u8, obj.status, "done")) break :blk Status.closed;
            break :blk Status.open;
        };

        const issue = Issue{
            .id = obj.id,
            .title = obj.title,
            .description = obj.description orelse "",
            .status = status,
            .priority = obj.priority,
            .issue_type = obj.issue_type,
            .assignee = obj.assignee,
            .created_at = obj.created_at,
            .closed_at = obj.closed_at,
            .close_reason = obj.close_reason,
            .blocks = &.{},
        };

        // Determine parent from dependencies
        var parent_id: ?[]const u8 = null;
        if (obj.dependencies) |deps| {
            for (deps) |dep| {
                const dep_type = dep.type orelse "blocks";
                if (std.mem.eql(u8, dep_type, "parent-child")) {
                    parent_id = dep.depends_on_id;
                    break;
                }
            }
        }

        storage.createIssue(issue, parent_id) catch |err| switch (err) {
            error.IssueAlreadyExists => continue, // Duplicate in JSONL, skip
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // Other expected errors (invalid ID format, etc.)
        };

        // Add block dependencies
        if (obj.dependencies) |deps| {
            for (deps) |dep| {
                const dep_type = dep.type orelse "blocks";
                if (std.mem.eql(u8, dep_type, "blocks")) {
                    storage.addDependency(obj.id, dep.depends_on_id, "blocks") catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // DependencyNotFound, DependencyCycle, InvalidId are expected during migration
                        else => {},
                    };
                }
            }
        }

        count += 1;
    }

    // Second pass: archive all closed issues (after all imports, so parent-child relationships are complete)
    const all_issues = try storage.listIssues(null);
    defer storage_mod.freeIssues(allocator, all_issues);
    for (all_issues) |iss| {
        if (iss.status == .closed) {
            storage.archiveIssue(iss.id) catch |err| switch (err) {
                // ChildrenNotClosed is expected if parent closed but children aren't
                error.ChildrenNotClosed => {},
                // IssueNotFound can happen if already archived by parent move
                error.IssueNotFound => {},
                else => return err,
            };
        }
    }

    return count;
}
