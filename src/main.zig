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
    \\  dot ls [--status S] [--json] List dots
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
    \\Examples:
    \\  dot "Fix the bug"
    \\  dot add "Design API" -p 1 -d "REST endpoints"
    \\  dot add "Implement" -P dots-1 -a dots-2
    \\  dot on dots-3
    \\  dot off dots-3 -r "shipped"
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

    const prefix = try storage_mod.getOrCreatePrefix(allocator, &storage);
    defer allocator.free(prefix);

    const id = try storage_mod.generateId(allocator, prefix);
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
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| filter_status = parseStatusArg(v);
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.listIssues(filter_status);
    defer storage_mod.freeIssues(allocator, issues);

    try writeIssueList(issues, filter_status == null, hasFlag(args, "--json"));
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
    for (roots) |root| {
        try w.print("[{s}] {s} {s}\n", .{ root.id, root.status.symbol(), root.title });

        const children = try storage.getChildren(root.id);
        defer storage_mod.freeChildIssues(allocator, children);

        for (children) |child| {
            const blocked_msg: []const u8 = if (child.blocked) " (blocked)" else "";
            try w.print(
                "  └─ [{s}] {s} {s}{s}\n",
                .{ child.issue.id, child.issue.status.symbol(), child.issue.title, blocked_msg },
            );
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

    const active = try storage.listIssues(.active);
    defer storage_mod.freeIssues(allocator, active);

    const ready = try storage.getReadyIssues();
    defer storage_mod.freeIssues(allocator, ready);

    if (active.len == 0 and ready.len == 0) return;

    const w = stdout();
    try w.writeAll("--- DOTS ---\n");
    if (active.len > 0) {
        try w.writeAll("ACTIVE:\n");
        for (active) |d| try w.print("  [{s}] {s}\n", .{ d.id, d.title });
    }
    if (ready.len > 0) {
        try w.writeAll("READY:\n");
        for (ready) |d| try w.print("  [{s}] {s}\n", .{ d.id, d.title });
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
    // Read stdin
    const input = try fs.File.stdin().readToEndAlloc(allocator, max_hook_input_bytes);
    defer allocator.free(input);
    if (input.len == 0) return error.EmptyHookInput;

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

    // Get prefix for ID generation
    const prefix = try storage_mod.getOrCreatePrefix(allocator, &storage);
    defer allocator.free(prefix);

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
            // Create new dot
            const id = try storage_mod.generateId(allocator, prefix);
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
