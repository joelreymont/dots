const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const build_options = @import("build_options");
const status_util = @import("util/status.zig");
const mapping_util = @import("util/mapping.zig");

const libc = @cImport({
    @cInclude("time.h");
});

const BEADS_DIR = ".beads";
const BEADS_DB = ".beads/beads.db";
const BEADS_JSONL = ".beads/issues.jsonl";
const max_hook_input_bytes = 1024 * 1024;
const max_mapping_bytes = 1024 * 1024;
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
    .{ .names = &.{"update"}, .handler = cmdBeadsUpdate },
    .{ .names = &.{"close"}, .handler = cmdBeadsClose },
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

fn cmdInitWrapper(allocator: Allocator, _: []const []const u8) !void {
    return cmdInit(allocator);
}

fn cmdHelp(_: Allocator, _: []const []const u8) !void {
    return stdout().writeAll(USAGE);
}

fn cmdVersion(_: Allocator, _: []const []const u8) !void {
    return stdout().print("dots {s} ({s})\n", .{ build_options.version, build_options.git_hash });
}

fn openStorage(allocator: Allocator) !sqlite.Storage {
    // Auto-create .beads/ directory
    fs.cwd().makeDir(BEADS_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Verify it's actually a directory
            const stat = fs.cwd().statFile(BEADS_DIR) catch return err;
            if (stat.kind != .directory) fatal("{s} exists but is not a directory\n", .{BEADS_DIR});
        },
        else => return err,
    };
    return sqlite.Storage.open(allocator, BEADS_DB);
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

// Status helpers
const StatusKind = status_util.StatusKind;

fn statusKindOrFatal(status_str: []const u8) StatusKind {
    return status_util.parse(status_str) orelse fatal("Invalid status: {s}\n", .{status_str});
}

fn statusToString(kind: StatusKind) []const u8 {
    return status_util.toString(kind);
}

fn parseStatusArg(status: []const u8) []const u8 {
    return statusToString(statusKindOrFatal(status));
}

fn statusChar(status: []const u8) u8 {
    return status_util.char(statusKindOrFatal(status));
}

fn statusSym(status: []const u8) []const u8 {
    return status_util.symbol(statusKindOrFatal(status));
}

fn displayStatus(status: []const u8) []const u8 {
    return status_util.display(statusKindOrFatal(status));
}

fn isClosedStatus(status: []const u8) bool {
    return statusKindOrFatal(status) == .closed;
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
    \\  dot init                     Initialize .beads directory
    \\
    \\Examples:
    \\  dot "Fix the bug"
    \\  dot add "Design API" -p 1 -d "REST endpoints"
    \\  dot add "Implement" -P bd-1 -a bd-2
    \\  dot on bd-3
    \\  dot off bd-3 -r "shipped"
    \\
;

fn cmdInit(allocator: Allocator) !void {
    fs.cwd().makeDir(BEADS_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const jsonl_exists = blk: {
        fs.cwd().access(BEADS_JSONL, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    var storage = try openStorage(allocator);
    defer storage.close();

    if (jsonl_exists) {
        const count = try sqlite.hydrateFromJsonl(&storage, allocator, BEADS_JSONL);
        if (count > 0) try stdout().print("Hydrated {d} issues from {s}\n", .{ count, BEADS_JSONL });
    }
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

    const prefix = try getOrCreatePrefix(allocator, &storage);
    defer allocator.free(prefix);

    const id = try generateId(allocator, prefix);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

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

    storage.createIssue(issue) catch |err| switch (err) {
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
    var filter_status: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| filter_status = parseStatusArg(v);
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.listIssues(filter_status);
    defer sqlite.freeIssues(allocator, issues);

    try writeIssueList(issues, filter_status == null, hasFlag(args, "--json"));
}

fn cmdReady(allocator: Allocator, args: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.getReadyIssues();
    defer sqlite.freeIssues(allocator, issues);

    try writeIssueList(issues, false, hasFlag(args, "--json"));
}

fn writeIssueList(issues: []const sqlite.Issue, skip_done: bool, use_json: bool) !void {
    const w = stdout();
    if (use_json) {
        try w.writeByte('[');
        var first = true;
        for (issues) |issue| {
            if (skip_done and isClosedStatus(issue.status)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try writeIssueJson(issue, w);
        }
        try w.writeAll("]\n");
    } else {
        for (issues) |issue| {
            if (skip_done and isClosedStatus(issue.status)) continue;
            try w.print("[{s}] {c} {s}\n", .{ issue.id, statusChar(issue.status), issue.title });
        }
    }
}

fn cmdOn(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot on <id>\n", .{});

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    storage.updateStatus(args[0], "active", now, null, null) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{args[0]}),
        else => return err,
    };
}

fn cmdOff(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot off <id> [-r reason]\n", .{});

    var reason: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-r")) |v| reason = v;
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    storage.updateStatus(args[0], "closed", now, now, reason) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{args[0]}),
        else => return err,
    };
}

fn cmdRm(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot rm <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    storage.deleteIssue(args[0]) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{args[0]}),
        else => return err,
    };
}

fn cmdShow(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot show <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const iss = try storage.getIssue(args[0]) orelse fatal("Issue not found: {s}\n", .{args[0]});
    defer iss.deinit(allocator);

    const w = stdout();
    try w.print("ID:       {s}\nTitle:    {s}\nStatus:   {s}\nPriority: {d}\n", .{ iss.id, iss.title, displayStatus(iss.status), iss.priority });
    if (iss.description.len > 0) try w.print("Desc:     {s}\n", .{iss.description});
    try w.print("Created:  {s}\n", .{iss.created_at});
    if (iss.closed_at) |ca| try w.print("Closed:   {s}\n", .{ca});
    if (iss.close_reason) |r| try w.print("Reason:   {s}\n", .{r});
}

fn cmdTree(allocator: Allocator, args: []const []const u8) !void {
    _ = args;

    var storage = try openStorage(allocator);
    defer storage.close();

    const roots = try storage.getRootIssues();
    defer sqlite.freeIssues(allocator, roots);

    const w = stdout();
    for (roots) |root| {
        try w.print("[{s}] {s} {s}\n", .{ root.id, statusSym(root.status), root.title });

        const children = try storage.getChildren(root.id);
        defer sqlite.freeChildIssues(allocator, children);

        for (children) |child| {
            const blocked_msg: []const u8 = if (child.blocked) " (blocked)" else "";
            try w.print(
                "  └─ [{s}] {s} {s}{s}\n",
                .{ child.issue.id, statusSym(child.issue.status), child.issue.title, blocked_msg },
            );
        }
    }
}

fn cmdFind(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot find <query>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.searchIssues(args[0]);
    defer sqlite.freeIssues(allocator, issues);

    const w = stdout();
    for (issues) |issue| {
        try w.print("[{s}] {c} {s}\n", .{ issue.id, statusChar(issue.status), issue.title });
    }
}

fn cmdBeadsUpdate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot update <id> [--status S]\n", .{});

    var new_status: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| new_status = parseStatusArg(v);
    }

    const status = new_status orelse fatal("--status required\n", .{});

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    const closed_at: ?[]const u8 = if (std.mem.eql(u8, status, "closed")) now else null;
    storage.updateStatus(args[0], status, now, closed_at, null) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{args[0]}),
        else => return err,
    };
}

fn cmdBeadsClose(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot close <id> [--reason R]\n", .{});

    var reason: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--reason")) |v| reason = v;
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    storage.updateStatus(args[0], "closed", now, now, reason) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{args[0]}),
        else => return err,
    };
}

fn generateId(allocator: Allocator, prefix: []const u8) ![]u8 {
    // Use microseconds (48-bit) + random (16-bit) for collision resistance
    const ts = std.time.microTimestamp();
    if (ts < 0) return error.InvalidTimestamp;
    const micros: u48 = @truncate(@as(u64, @intCast(ts)));
    const rand: u16 = std.crypto.random.int(u16);
    return std.fmt.allocPrint(allocator, "{s}-{x}{x:0>4}", .{ prefix, micros, rand });
}

fn getOrCreatePrefix(allocator: Allocator, storage: *sqlite.Storage) ![]const u8 {
    // Try to get prefix from database config
    if (try storage.getConfig("issue_prefix")) |prefix| {
        return prefix;
    }

    // Auto-detect from directory name (like beads does)
    const cwd = std.fs.cwd();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &path_buf);
    const basename = std.fs.path.basename(path);

    // Strip trailing hyphens like beads does
    var prefix = std.mem.trimRight(u8, basename, "-");
    if (prefix.len == 0) prefix = "dot";

    // Store it in config for future use
    try storage.setConfig("issue_prefix", prefix);

    return allocator.dupe(u8, prefix);
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
    updated_at: []const u8,
    closed_at: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
};

fn writeIssueJson(issue: sqlite.Issue, w: *std.Io.Writer) !void {
    const json_issue = JsonIssue{
        .id = issue.id,
        .title = issue.title,
        .description = if (issue.description.len > 0) issue.description else null,
        .status = displayStatus(issue.status),
        .priority = issue.priority,
        .issue_type = issue.issue_type,
        .created_at = issue.created_at,
        .updated_at = issue.updated_at,
        .closed_at = issue.closed_at,
        .close_reason = issue.close_reason,
    };
    try std.json.Stringify.value(json_issue, .{}, w);
}

// Claude Code hook handlers
fn cmdHook(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot hook <session|sync>\n", .{});

    if (std.mem.eql(u8, args[0], "session")) {
        try hookSession(allocator);
    } else if (std.mem.eql(u8, args[0], "sync")) {
        try hookSync(allocator);
    } else {
        fatal("Unknown hook: {s}\n", .{args[0]});
    }
}

fn hookSession(allocator: Allocator) !void {
    // Check if .beads exists
    fs.cwd().access(BEADS_DIR, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    var storage = try openStorage(allocator);
    defer storage.close();

    const active = try storage.listIssues("active");
    defer sqlite.freeIssues(allocator, active);

    const ready = try storage.getReadyIssues();
    defer sqlite.freeIssues(allocator, ready);

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

const MAPPING_FILE = ".beads/todo-mapping.json";
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

fn validateHookStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "in_progress") or std.mem.eql(u8, status, "completed");
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
        .{ .ignore_unknown_fields = false },
    );
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.tool_name, "TodoWrite")) return;
    const tool_input = parsed.value.tool_input orelse return error.InvalidHookInput;

    const parsed_input = try parseJsonValueOrError(
        HookTodoInput,
        allocator,
        tool_input,
        error.InvalidHookInput,
        .{ .ignore_unknown_fields = false },
    );
    defer parsed_input.deinit();
    const todos = parsed_input.value.todos;

    // Validate all todos before any DB operations
    for (todos) |todo| {
        if (todo.content.len == 0) return error.InvalidHookInput;
        if (!validateHookStatus(todo.status)) return error.InvalidHookInput;
    }

    // Ensure .beads exists
    fs.cwd().makeDir(BEADS_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var storage = try openStorage(allocator);
    defer storage.close();

    // Get prefix for ID generation
    const prefix = try getOrCreatePrefix(allocator, &storage);
    defer allocator.free(prefix);

    // Load mapping
    var mapping = try loadMapping(allocator);
    defer mapping_util.deinit(allocator, &mapping);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    // Begin transaction for atomicity
    try storage.db.exec("BEGIN TRANSACTION");
    errdefer storage.db.exec("ROLLBACK") catch {};

    // Process todos
    for (todos) |todo| {
        const content = todo.content;
        const status = todo.status;

        if (std.mem.eql(u8, status, "completed")) {
            // Mark as done if we have mapping - only remove on success
            const dot_id = mapping.map.get(content) orelse return error.MissingTodoMapping;
            try storage.updateStatusNoTransaction(dot_id, "closed", now, now, "Completed via TodoWrite");
            if (mapping.map.fetchOrderedRemove(content)) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
        } else if (mapping.map.get(content)) |dot_id| {
            // Update status if changed (pending <-> in_progress)
            const new_db_status: []const u8 = if (std.mem.eql(u8, status, "in_progress")) "active" else "open";
            try storage.updateStatusNoTransaction(dot_id, new_db_status, now, null, null);
        } else {
            // Create new dot
            const id = try generateId(allocator, prefix);
            defer allocator.free(id);
            const desc = todo.activeForm orelse "";
            const priority: i64 = if (std.mem.eql(u8, status, "in_progress")) 1 else default_priority;

            const issue = sqlite.Issue{
                .id = id,
                .title = content,
                .description = desc,
                .status = if (std.mem.eql(u8, status, "in_progress")) "active" else "open",
                .priority = priority,
                .issue_type = "task",
                .assignee = null,
                .created_at = now,
                .updated_at = now,
                .closed_at = null,
                .close_reason = null,
                .after = null,
                .parent = null,
            };

            try storage.createIssueNoTransaction(issue);

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

    // Commit transaction first (DB is source of truth)
    try storage.db.exec("COMMIT");

    // Save mapping after DB commit succeeds
    // If this fails, mapping can be rebuilt from DB on next run
    try saveMappingAtomic(allocator, mapping);
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

fn saveMapping(allocator: Allocator, map: Mapping) !void {
    const file = try fs.cwd().createFile(MAPPING_FILE, .{});
    defer file.close();

    const json = try std.json.Stringify.valueAlloc(allocator, map, .{});
    defer allocator.free(json);

    try file.writeAll(json);
    try file.sync();
}

fn saveMappingAtomic(allocator: Allocator, map: Mapping) !void {
    const tmp_file = MAPPING_FILE ++ ".tmp";

    // Write to temp file
    const file = try fs.cwd().createFile(tmp_file, .{});
    errdefer fs.cwd().deleteFile(tmp_file) catch {};

    const json = try std.json.Stringify.valueAlloc(allocator, map, .{});
    defer allocator.free(json);

    try file.writeAll(json);
    try file.sync();
    file.close();

    // Atomic rename
    try fs.cwd().rename(tmp_file, MAPPING_FILE);
}
