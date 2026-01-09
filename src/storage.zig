const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

const DOTS_DIR = ".dots";
const ARCHIVE_DIR = ".dots/archive";

// Buffer size constants
const MAX_PATH_LEN = 512; // Maximum path length for file operations
const MAX_ID_LEN = 128; // Maximum ID length (validated in validateId)
const MAX_SLUG_LEN = 40; // Maximum slug length for human-readable IDs

// Errors
pub const StorageError = error{
    IssueNotFound,
    IssueAlreadyExists,
    AmbiguousId,
    DependencyNotFound,
    DependencyCycle,
    DependencyConflict,
    ChildrenNotClosed,
    InvalidFrontmatter,
    InvalidStatus,
    InvalidId,
    IoError,
};

/// Validates that an ID is safe for use in paths and YAML
pub fn validateId(id: []const u8) StorageError!void {
    if (id.len == 0) return StorageError.InvalidId;
    if (id.len > 128) return StorageError.InvalidId;
    // Reject path traversal attempts
    if (std.mem.indexOf(u8, id, "/") != null) return StorageError.InvalidId;
    if (std.mem.indexOf(u8, id, "\\") != null) return StorageError.InvalidId;
    if (std.mem.indexOf(u8, id, "..") != null) return StorageError.InvalidId;
    if (std.mem.eql(u8, id, ".")) return StorageError.InvalidId;
    // Reject control characters and YAML-sensitive characters
    for (id) |c| {
        if (c < 0x20 or c == 0x7F) return StorageError.InvalidId;
        if (c == '#' or c == ':' or c == '\'' or c == '"') return StorageError.InvalidId;
    }
}

/// Convert a title to a URL-safe slug
/// - Lowercase, replace spaces with hyphens
/// - Remove special characters except hyphens
/// - Collapse multiple hyphens
/// - Truncate to MAX_SLUG_LEN chars at word boundary
pub fn slugify(allocator: Allocator, title: []const u8) ![]u8 {
    if (title.len == 0) {
        return allocator.dupe(u8, "untitled");
    }

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var last_was_hyphen = true; // Start true to skip leading hyphens

    for (title) |c| {
        const lower = std.ascii.toLower(c);

        if (std.ascii.isAlphanumeric(lower)) {
            try result.append(allocator, lower);
            last_was_hyphen = false;
        } else if (c == ' ' or c == '-' or c == '_') {
            if (!last_was_hyphen) {
                try result.append(allocator, '-');
                last_was_hyphen = true;
            }
        }
        // Skip all other characters

        // Check length - truncate at word boundary
        if (result.items.len >= MAX_SLUG_LEN) {
            // Find last hyphen for word boundary
            var truncate_at = result.items.len;
            if (truncate_at > MAX_SLUG_LEN) {
                truncate_at = MAX_SLUG_LEN;
                // Look for word boundary (hyphen) to truncate cleanly
                var i: usize = truncate_at;
                while (i > MAX_SLUG_LEN - 10 and i > 0) : (i -= 1) {
                    if (result.items[i - 1] == '-') {
                        truncate_at = i - 1; // Don't include the hyphen
                        break;
                    }
                }
            }
            result.shrinkRetainingCapacity(truncate_at);
            break;
        }
    }

    // Remove trailing hyphen
    while (result.items.len > 0 and result.items[result.items.len - 1] == '-') {
        result.shrinkRetainingCapacity(result.items.len - 1);
    }

    if (result.items.len == 0) {
        result.deinit(allocator);
        return allocator.dupe(u8, "untitled");
    }

    return result.toOwnedSlice(allocator);
}

/// Get the next incremental ID number for a given type prefix in a directory
/// Scans for existing {prefix}{n}-* entries and returns max(n) + 1, or 1 if none exist
pub fn getNextId(dir: fs.Dir, type_prefix: []const u8) !u32 {
    var max_id: u32 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Check if entry starts with the type prefix
        if (!std.mem.startsWith(u8, entry.name, type_prefix)) continue;

        // Extract the number after the prefix
        const after_prefix = entry.name[type_prefix.len..];
        // Find where the number ends (at the hyphen)
        const hyphen_idx = std.mem.indexOf(u8, after_prefix, "-") orelse continue;
        const num_str = after_prefix[0..hyphen_idx];

        const num = std.fmt.parseInt(u32, num_str, 10) catch continue;
        if (num > max_id) {
            max_id = num;
        }
    }

    return max_id + 1;
}

/// Issue type prefixes for hierarchical IDs
pub const IssueTypePrefix = enum {
    plan,
    milestone,
    task,

    const map = std.StaticStringMap(IssueTypePrefix).initComptime(.{
        .{ "plan", .plan },
        .{ "milestone", .milestone },
        .{ "task", .task },
    });

    pub fn fromString(s: []const u8) ?IssueTypePrefix {
        return map.get(s);
    }

    pub fn prefix(self: IssueTypePrefix) []const u8 {
        return switch (self) {
            .plan => "p",
            .milestone => "m",
            .task => "t",
        };
    }
};

/// Generate a hierarchical ID: {type_prefix}{n}-{slug}
/// For plans: p1-user-auth, p2-api-rate-limiting
/// For milestones: m1-backend-setup, m2-frontend
/// For tasks: t1-create-user-model, t2-add-password-hashing
pub fn generateHierarchicalId(allocator: Allocator, dir: fs.Dir, issue_type: []const u8, title: []const u8) ![]u8 {
    const type_prefix_enum = IssueTypePrefix.fromString(issue_type);
    const type_prefix = if (type_prefix_enum) |tp| tp.prefix() else "d"; // default prefix for unknown types

    const next_num = try getNextId(dir, type_prefix);
    const slug = try slugify(allocator, title);
    defer allocator.free(slug);

    return std.fmt.allocPrint(allocator, "{s}{d}-{s}", .{ type_prefix, next_num, slug });
}

/// Write content to file atomically (write to .tmp, sync, rename)
fn writeFileAtomic(dir: fs.Dir, path: []const u8, content: []const u8) !void {
    var tmp_path_buf: [MAX_PATH_LEN + 4]u8 = undefined; // +4 for ".tmp" suffix
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch return StorageError.IoError;

    const tmp_file = try dir.createFile(tmp_path, .{});
    defer tmp_file.close();
    errdefer dir.deleteFile(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {}, // Already deleted, that's fine
        else => {}, // Best effort cleanup, can't propagate from errdefer
    };
    try tmp_file.writeAll(content);
    try tmp_file.sync();

    try dir.rename(tmp_path, path);
}

// Status enum with comptime string map
pub const Status = enum {
    open,
    active,
    closed,

    const map = std.StaticStringMap(Status).initComptime(.{
        .{ "open", .open },
        .{ "active", .active },
        .{ "closed", .closed },
        .{ "done", .closed }, // alias
    });

    pub fn parse(s: []const u8) ?Status {
        return map.get(s);
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .open => "open",
            .active => "active",
            .closed => "closed",
        };
    }

    pub fn display(self: Status) []const u8 {
        return switch (self) {
            .open => "open",
            .active => "active",
            .closed => "done",
        };
    }

    pub fn char(self: Status) u8 {
        return switch (self) {
            .open => 'o',
            .active => '>',
            .closed => 'x',
        };
    }

    pub fn symbol(self: Status) []const u8 {
        return switch (self) {
            .open => "○",
            .active => ">",
            .closed => "✓",
        };
    }
};

pub const Issue = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: Status,
    priority: i64,
    issue_type: []const u8,
    assignee: ?[]const u8,
    created_at: []const u8,
    closed_at: ?[]const u8,
    close_reason: ?[]const u8,
    blocks: []const []const u8,
    // ExecPlan extensions
    scope: ?[]const u8 = null,
    acceptance: ?[]const u8 = null,
    // Computed from path, not stored in frontmatter
    parent: ?[]const u8 = null,

    /// Compare issues by priority (ascending) then created_at (ascending)
    pub fn order(_: void, a: Issue, b: Issue) bool {
        if (a.priority != b.priority) return a.priority < b.priority;
        return std.mem.order(u8, a.created_at, b.created_at) == .lt;
    }

    /// Create a copy with updated status fields (borrows all strings)
    pub fn withStatus(self: Issue, status: Status, closed_at: ?[]const u8, close_reason: ?[]const u8) Issue {
        return .{
            .id = self.id,
            .title = self.title,
            .description = self.description,
            .status = status,
            .priority = self.priority,
            .issue_type = self.issue_type,
            .assignee = self.assignee,
            .created_at = self.created_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .blocks = self.blocks,
            .scope = self.scope,
            .acceptance = self.acceptance,
            .parent = self.parent,
        };
    }

    /// Create a copy with updated blocks (borrows all strings)
    pub fn withBlocks(self: Issue, blocks: []const []const u8) Issue {
        return .{
            .id = self.id,
            .title = self.title,
            .description = self.description,
            .status = self.status,
            .priority = self.priority,
            .issue_type = self.issue_type,
            .assignee = self.assignee,
            .created_at = self.created_at,
            .closed_at = self.closed_at,
            .close_reason = self.close_reason,
            .blocks = blocks,
            .scope = self.scope,
            .acceptance = self.acceptance,
            .parent = self.parent,
        };
    }

    /// Create a deep copy of this issue with all strings duplicated
    pub fn clone(self: Issue, allocator: Allocator) !Issue {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);

        const title = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title);

        const description = try allocator.dupe(u8, self.description);
        errdefer allocator.free(description);

        const issue_type = try allocator.dupe(u8, self.issue_type);
        errdefer allocator.free(issue_type);

        const assignee = if (self.assignee) |a| try allocator.dupe(u8, a) else null;
        errdefer if (assignee) |a| allocator.free(a);

        const created_at = try allocator.dupe(u8, self.created_at);
        errdefer allocator.free(created_at);

        const closed_at = if (self.closed_at) |c| try allocator.dupe(u8, c) else null;
        errdefer if (closed_at) |c| allocator.free(c);

        const close_reason = if (self.close_reason) |r| try allocator.dupe(u8, r) else null;
        errdefer if (close_reason) |r| allocator.free(r);

        var blocks: std.ArrayList([]const u8) = .{};
        errdefer {
            for (blocks.items) |b| allocator.free(b);
            blocks.deinit(allocator);
        }
        for (self.blocks) |b| {
            const duped = try allocator.dupe(u8, b);
            try blocks.append(allocator, duped);
        }

        const parent = if (self.parent) |p| try allocator.dupe(u8, p) else null;
        errdefer if (parent) |p| allocator.free(p);

        const scope = if (self.scope) |s| try allocator.dupe(u8, s) else null;
        errdefer if (scope) |s| allocator.free(s);

        const acceptance = if (self.acceptance) |a| try allocator.dupe(u8, a) else null;
        errdefer if (acceptance) |a| allocator.free(a);

        return Issue{
            .id = id,
            .title = title,
            .description = description,
            .status = self.status,
            .priority = self.priority,
            .issue_type = issue_type,
            .assignee = assignee,
            .created_at = created_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .blocks = try blocks.toOwnedSlice(allocator),
            .scope = scope,
            .acceptance = acceptance,
            .parent = parent,
        };
    }

    pub fn deinit(self: *const Issue, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.issue_type);
        if (self.assignee) |s| allocator.free(s);
        allocator.free(self.created_at);
        if (self.closed_at) |s| allocator.free(s);
        if (self.close_reason) |s| allocator.free(s);
        for (self.blocks) |b| allocator.free(b);
        allocator.free(self.blocks);
        if (self.scope) |s| allocator.free(s);
        if (self.acceptance) |a| allocator.free(a);
        if (self.parent) |p| allocator.free(p);
    }
};

const StatusMap = std.StringHashMap(Status);

pub fn freeIssues(allocator: Allocator, issues: []const Issue) void {
    for (issues) |*issue| {
        issue.deinit(allocator);
    }
    allocator.free(issues);
}

pub const ChildIssue = struct {
    issue: Issue,
    blocked: bool,

    /// Compare child issues by their inner issue order
    pub fn order(_: void, a: ChildIssue, b: ChildIssue) bool {
        return Issue.order({}, a.issue, b.issue);
    }

    pub fn deinit(self: *const ChildIssue, allocator: Allocator) void {
        self.issue.deinit(allocator);
    }
};

pub fn freeChildIssues(allocator: Allocator, issues: []const ChildIssue) void {
    for (issues) |*issue| {
        issue.deinit(allocator);
    }
    allocator.free(issues);
}

// YAML Frontmatter parsing
const Frontmatter = struct {
    title: []const u8 = "",
    status: Status = .open,
    priority: i64 = 2,
    issue_type: []const u8 = "task",
    assignee: ?[]const u8 = null,
    created_at: []const u8 = "",
    closed_at: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
    blocks: []const []const u8 = &.{},
    // ExecPlan extensions
    scope: ?[]const u8 = null,
    acceptance: ?[]const u8 = null,
};

const ParseResult = struct {
    frontmatter: Frontmatter,
    description: []const u8,
    // Track allocated strings for cleanup
    allocated_blocks: [][]const u8,
    allocated_title: ?[]const u8 = null,

    pub fn deinit(self: *const ParseResult, allocator: Allocator) void {
        if (self.allocated_title) |t| allocator.free(t);
        for (self.allocated_blocks) |b| allocator.free(b);
        allocator.free(self.allocated_blocks);
    }
};

// Frontmatter field enum and map (file-scope for efficiency)
const FrontmatterField = enum {
    title,
    status,
    priority,
    issue_type,
    assignee,
    created_at,
    closed_at,
    close_reason,
    blocks,
    // ExecPlan extensions
    scope,
    acceptance,
};

const frontmatter_field_map = std.StaticStringMap(FrontmatterField).initComptime(.{
    .{ "title", .title },
    .{ "status", .status },
    .{ "priority", .priority },
    .{ "issue-type", .issue_type },
    .{ "assignee", .assignee },
    .{ "created-at", .created_at },
    .{ "closed-at", .closed_at },
    .{ "close-reason", .close_reason },
    .{ "blocks", .blocks },
    // ExecPlan extensions
    .{ "scope", .scope },
    .{ "acceptance", .acceptance },
});

/// Result of parsing a YAML value - clearly indicates ownership
const YamlValue = union(enum) {
    borrowed: []const u8, // Points to input, caller must NOT free
    owned: []const u8, // Allocated, caller MUST free

    fn slice(self: YamlValue) []const u8 {
        return switch (self) {
            .borrowed => |s| s,
            .owned => |s| s,
        };
    }

    fn getOwned(self: YamlValue) ?[]const u8 {
        return switch (self) {
            .borrowed => null,
            .owned => |s| s,
        };
    }
};

/// Parse a YAML value, handling quoted strings with escape sequences
fn parseYamlValue(allocator: Allocator, value: []const u8) !YamlValue {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        // Unquoted value, use as-is (caller should not free)
        return .{ .borrowed = value };
    }
    // Quoted value - unescape it
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 1; // Skip opening quote
    while (i < value.len - 1) { // Stop before closing quote
        if (value[i] == '\\' and i + 1 < value.len - 1) {
            const next = value[i + 1];
            switch (next) {
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, next);
                },
            }
            i += 2; // Skip backslash and escaped char
        } else {
            try result.append(allocator, value[i]);
            i += 1;
        }
    }
    return .{ .owned = try result.toOwnedSlice(allocator) };
}

fn parseFrontmatter(allocator: Allocator, content: []const u8) !ParseResult {
    // Find YAML delimiters
    if (!std.mem.startsWith(u8, content, "---\n")) {
        return StorageError.InvalidFrontmatter;
    }

    const end_marker = std.mem.indexOf(u8, content[4..], "\n---");
    if (end_marker == null) {
        return StorageError.InvalidFrontmatter;
    }

    const yaml_content = content[4 .. 4 + end_marker.?];
    const description_start = 4 + end_marker.? + 4; // skip "\n---"
    const description = if (description_start < content.len)
        std.mem.trim(u8, content[description_start..], "\n\r\t ")
    else
        "";

    var fm = Frontmatter{};
    var blocks_list: std.ArrayList([]const u8) = .{};
    var allocated_title: ?[]const u8 = null;
    errdefer {
        if (allocated_title) |t| allocator.free(t);
        for (blocks_list.items) |b| allocator.free(b);
        blocks_list.deinit(allocator);
    }

    var in_blocks = false;
    var lines = std.mem.splitScalar(u8, yaml_content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r\t ");

        // Handle blocks array items
        if (in_blocks) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                const block_id = std.mem.trim(u8, trimmed[2..], " ");
                // Validate block ID to prevent path traversal attacks
                validateId(block_id) catch continue; // Skip invalid block IDs silently
                const duped = try allocator.dupe(u8, block_id);
                try blocks_list.append(allocator, duped);
                continue;
            } else if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, " ")) {
                in_blocks = false;
            } else {
                continue;
            }
        }

        // Parse key: value
        const colon_idx = std.mem.indexOf(u8, trimmed, ":") orelse continue;
        const key = trimmed[0..colon_idx];
        const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " ");

        const field = frontmatter_field_map.get(key) orelse continue;

        switch (field) {
            .title => {
                const parsed = try parseYamlValue(allocator, value);
                fm.title = parsed.slice();
                allocated_title = parsed.getOwned();
            },
            .status => fm.status = Status.parse(value) orelse return StorageError.InvalidStatus,
            .priority => fm.priority = std.fmt.parseInt(i64, value, 10) catch return StorageError.InvalidFrontmatter,
            .issue_type => fm.issue_type = value,
            .assignee => fm.assignee = if (value.len > 0) value else null,
            .created_at => fm.created_at = value,
            .closed_at => fm.closed_at = if (value.len > 0) value else null,
            .close_reason => fm.close_reason = if (value.len > 0) value else null,
            .blocks => in_blocks = true,
            // ExecPlan extensions
            .scope => fm.scope = if (value.len > 0) value else null,
            .acceptance => fm.acceptance = if (value.len > 0) value else null,
        }
    }

    const allocated_blocks = try blocks_list.toOwnedSlice(allocator);
    fm.blocks = allocated_blocks;

    return ParseResult{
        .frontmatter = fm,
        .description = description,
        .allocated_blocks = allocated_blocks,
        .allocated_title = allocated_title,
    };
}

/// Returns true if string needs YAML quoting
fn needsYamlQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    // Check for characters that need quoting
    for (s) |c| {
        if (c == '\n' or c == '\r' or c == ':' or c == '#' or c == '"' or c == '\'' or c == '\\') return true;
    }
    // Leading/trailing whitespace
    if (s[0] == ' ' or s[0] == '\t' or s[s.len - 1] == ' ' or s[s.len - 1] == '\t') return true;
    return false;
}

/// Write a YAML-safe string value, quoting and escaping as needed
fn writeYamlValue(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    if (!needsYamlQuoting(value)) {
        try buf.appendSlice(allocator, value);
        return;
    }
    // Use double quotes and escape special characters
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn serializeFrontmatter(allocator: Allocator, issue: Issue) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "---\n");
    try buf.appendSlice(allocator, "title: ");
    try writeYamlValue(&buf, allocator, issue.title);
    try buf.appendSlice(allocator, "\nstatus: ");
    try buf.appendSlice(allocator, issue.status.toString());
    try buf.appendSlice(allocator, "\npriority: ");

    var priority_buf: [21]u8 = undefined; // i64 max is 19 digits + sign
    const priority_str = std.fmt.bufPrint(&priority_buf, "{d}", .{issue.priority}) catch return error.OutOfMemory;
    try buf.appendSlice(allocator, priority_str);

    try buf.appendSlice(allocator, "\nissue-type: ");
    try writeYamlValue(&buf, allocator, issue.issue_type);

    if (issue.assignee) |assignee| {
        try buf.appendSlice(allocator, "\nassignee: ");
        try writeYamlValue(&buf, allocator, assignee);
    }

    try buf.appendSlice(allocator, "\ncreated-at: ");
    try writeYamlValue(&buf, allocator, issue.created_at);

    if (issue.closed_at) |closed_at| {
        try buf.appendSlice(allocator, "\nclosed-at: ");
        try writeYamlValue(&buf, allocator, closed_at);
    }

    if (issue.close_reason) |reason| {
        try buf.appendSlice(allocator, "\nclose-reason: ");
        try writeYamlValue(&buf, allocator, reason);
    }

    if (issue.blocks.len > 0) {
        try buf.appendSlice(allocator, "\nblocks:");
        for (issue.blocks) |block_id| {
            try buf.appendSlice(allocator, "\n  - ");
            try buf.appendSlice(allocator, block_id);
        }
    }

    // ExecPlan extensions
    if (issue.scope) |scope| {
        try buf.appendSlice(allocator, "\nscope: ");
        try writeYamlValue(&buf, allocator, scope);
    }

    if (issue.acceptance) |acceptance| {
        try buf.appendSlice(allocator, "\nacceptance: ");
        try writeYamlValue(&buf, allocator, acceptance);
    }

    try buf.appendSlice(allocator, "\n---\n");

    if (issue.description.len > 0) {
        try buf.appendSlice(allocator, "\n");
        try buf.appendSlice(allocator, issue.description);
        try buf.appendSlice(allocator, "\n");
    }

    return buf.toOwnedSlice(allocator);
}

// ID generation - {prefix}-{16 random hex chars}
pub fn generateId(allocator: Allocator, prefix: []const u8) ![]u8 {
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, hex });
}

pub fn getOrCreatePrefix(allocator: Allocator, storage: *Storage) ![]const u8 {
    // Try to get prefix from config
    if (try storage.getConfig("prefix")) |prefix| {
        return prefix;
    }

    // Auto-detect from directory name
    const cwd = fs.cwd();
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = try cwd.realpath(".", &path_buf);
    const basename = fs.path.basename(path);

    // Strip trailing hyphens
    var prefix = std.mem.trimRight(u8, basename, "-");
    if (prefix.len == 0) prefix = "dot";

    // Store it in config for future use
    try storage.setConfig("prefix", prefix);

    return allocator.dupe(u8, prefix);
}

pub const Storage = struct {
    allocator: Allocator,
    dots_dir: fs.Dir,

    const Self = @This();

    pub fn open(allocator: Allocator) !Self {
        // Create .dots directory if needed
        fs.cwd().makeDir(DOTS_DIR) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create archive directory if needed
        fs.cwd().makeDir(ARCHIVE_DIR) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const dots_dir = try fs.cwd().openDir(DOTS_DIR, .{ .iterate = true });

        return Self{
            .allocator = allocator,
            .dots_dir = dots_dir,
        };
    }

    pub fn close(self: *Self) void {
        self.dots_dir.close();
    }

    // Resolve a short ID prefix to full ID
    pub fn resolveId(self: *Self, prefix: []const u8) ![]const u8 {
        var matches: std.ArrayList([]const u8) = .{};
        defer {
            for (matches.items) |m| self.allocator.free(m);
            matches.deinit(self.allocator);
        }

        // Search in .dots and .dots/archive
        try self.findMatchingIds(self.dots_dir, prefix, &matches);

        const archive_dir = self.dots_dir.openDir("archive", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (archive_dir) |*dir| {
            var d = dir.*;
            defer d.close();
            try self.findMatchingIds(d, prefix, &matches);
        }

        if (matches.items.len == 0) return StorageError.IssueNotFound;
        if (matches.items.len > 1) return StorageError.AmbiguousId;

        return self.allocator.dupe(u8, matches.items[0]);
    }

    fn findMatchingIds(self: *Self, dir: fs.Dir, prefix: []const u8, matches: *std.ArrayList([]const u8)) !void {
        try self.findMatchingIdsInner(dir, prefix, matches, null);
    }

    fn findMatchingIdsInner(self: *Self, dir: fs.Dir, prefix: []const u8, matches: *std.ArrayList([]const u8), parent_folder: ?[]const u8) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                const id = entry.name[0 .. entry.name.len - 3];
                // Skip if this file matches parent folder name (already counted)
                if (parent_folder) |pf| {
                    if (std.mem.eql(u8, id, pf)) continue;
                }
                if (std.mem.startsWith(u8, id, prefix)) {
                    const duped = try self.allocator.dupe(u8, id);
                    try matches.append(self.allocator, duped);
                }
            } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "archive")) {
                // Check folder name as potential ID
                if (std.mem.startsWith(u8, entry.name, prefix)) {
                    const duped = try self.allocator.dupe(u8, entry.name);
                    try matches.append(self.allocator, duped);
                }
                // Recurse into folder, passing folder name to skip self-reference
                var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                defer subdir.close();
                try self.findMatchingIdsInner(subdir, prefix, matches, entry.name);
            }
        }
    }

    pub fn issueExists(self: *Self, id: []const u8) bool {
        const path = self.findIssuePath(id) catch return false;
        self.allocator.free(path);
        return true;
    }

    fn findIssuePath(self: *Self, id: []const u8) ![]const u8 {
        // Try direct file: .dots/{id}.md
        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const direct_path = std.fmt.bufPrint(&path_buf, "{s}.md", .{id}) catch return StorageError.IoError;

        if (self.dots_dir.statFile(direct_path)) |_| {
            return self.allocator.dupe(u8, direct_path);
        } else |_| {}

        // Try folder: .dots/{id}/{id}.md
        const folder_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ id, id }) catch return StorageError.IoError;
        if (self.dots_dir.statFile(folder_path)) |_| {
            return self.allocator.dupe(u8, folder_path);
        } else |_| {}

        // Try in archive: .dots/archive/{id}.md
        const archive_path = std.fmt.bufPrint(&path_buf, "archive/{s}.md", .{id}) catch return StorageError.IoError;
        if (self.dots_dir.statFile(archive_path)) |_| {
            return self.allocator.dupe(u8, archive_path);
        } else |_| {}

        // Try archive folder: .dots/archive/{id}/{id}.md
        const archive_folder_path = std.fmt.bufPrint(&path_buf, "archive/{s}/{s}.md", .{ id, id }) catch return StorageError.IoError;
        if (self.dots_dir.statFile(archive_folder_path)) |_| {
            return self.allocator.dupe(u8, archive_folder_path);
        } else |_| {}

        // Search recursively in all subdirectories
        return try self.searchForIssue(self.dots_dir, id) orelse StorageError.IssueNotFound;
    }

    fn searchForIssue(self: *Self, dir: fs.Dir, id: []const u8) !?[]const u8 {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "archive")) {
                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch |err| switch (err) {
                    error.FileNotFound, error.AccessDenied => continue, // Skip inaccessible dirs
                    else => return err,
                };
                defer subdir.close();

                // Check for {id}.md in this directory
                var path_buf: [MAX_PATH_LEN]u8 = undefined;
                const filename = std.fmt.bufPrint(&path_buf, "{s}.md", .{id}) catch return StorageError.IoError;
                if (subdir.statFile(filename)) |_| {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ entry.name, filename });
                    return full_path;
                } else |_| {}

                // Recurse
                if (try self.searchForIssue(subdir, id)) |path| {
                    const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ entry.name, path }) catch |err| {
                        self.allocator.free(path);
                        return err;
                    };
                    self.allocator.free(path);
                    return full_path;
                }
            }
        }
        return null;
    }

    pub fn getIssue(self: *Self, id: []const u8) !?Issue {
        // Validate ID to prevent path traversal attacks
        try validateId(id);

        const path = self.findIssuePath(id) catch |err| switch (err) {
            StorageError.IssueNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(path);

        return try self.readIssueFromPath(path, id);
    }

    fn readIssueFromPath(self: *Self, path: []const u8, id: []const u8) !Issue {
        const file = try self.dots_dir.openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        const parsed = try parseFrontmatter(self.allocator, content);
        // Free allocated_title after duping
        defer if (parsed.allocated_title) |t| self.allocator.free(t);
        // Free allocated_blocks on error (transferred to Issue on success)
        var blocks_transferred = false;
        errdefer if (!blocks_transferred) {
            for (parsed.allocated_blocks) |b| self.allocator.free(b);
            self.allocator.free(parsed.allocated_blocks);
        };

        // Determine parent from path
        const parent = try self.extractParentFromPath(path);
        errdefer if (parent) |p| self.allocator.free(p);

        const issue_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(issue_id);

        const title = try self.allocator.dupe(u8, parsed.frontmatter.title);
        errdefer self.allocator.free(title);

        const description = try self.allocator.dupe(u8, parsed.description);
        errdefer self.allocator.free(description);

        const issue_type = try self.allocator.dupe(u8, parsed.frontmatter.issue_type);
        errdefer self.allocator.free(issue_type);

        const assignee = if (parsed.frontmatter.assignee) |a| try self.allocator.dupe(u8, a) else null;
        errdefer if (assignee) |a| self.allocator.free(a);

        const created_at = try self.allocator.dupe(u8, parsed.frontmatter.created_at);
        errdefer self.allocator.free(created_at);

        const closed_at = if (parsed.frontmatter.closed_at) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (closed_at) |c| self.allocator.free(c);

        const close_reason = if (parsed.frontmatter.close_reason) |r| try self.allocator.dupe(u8, r) else null;
        errdefer if (close_reason) |r| self.allocator.free(r);

        // ExecPlan extensions
        const scope = if (parsed.frontmatter.scope) |s| try self.allocator.dupe(u8, s) else null;
        errdefer if (scope) |s| self.allocator.free(s);

        const acceptance = if (parsed.frontmatter.acceptance) |a| try self.allocator.dupe(u8, a) else null;
        errdefer if (acceptance) |a| self.allocator.free(a);

        // Mark blocks as transferred (will be owned by Issue)
        blocks_transferred = true;
        return Issue{
            .id = issue_id,
            .title = title,
            .description = description,
            .status = parsed.frontmatter.status,
            .priority = parsed.frontmatter.priority,
            .issue_type = issue_type,
            .assignee = assignee,
            .created_at = created_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .blocks = parsed.allocated_blocks,
            .scope = scope,
            .acceptance = acceptance,
            .parent = parent,
        };
    }

    fn extractParentFromPath(self: *Self, path: []const u8) !?[]const u8 {
        // Path like "parent_id/child_id.md" means parent_id is the parent
        // Path like "child_id.md" means no parent
        const slash_idx = std.mem.indexOf(u8, path, "/");
        if (slash_idx) |idx| {
            const potential_parent = path[0..idx];
            // Skip "archive" directory
            if (std.mem.eql(u8, potential_parent, "archive")) {
                // Check for archive/parent/child pattern
                const rest = path[idx + 1 ..];
                const next_slash = std.mem.indexOf(u8, rest, "/");
                if (next_slash) |next_idx| {
                    return try self.allocator.dupe(u8, rest[0..next_idx]);
                }
                return null;
            }
            // Check if this is parent/parent.md (self) or parent/child.md
            const filename = std.fs.path.basename(path);
            const file_id = filename[0 .. filename.len - 3]; // strip .md
            if (!std.mem.eql(u8, file_id, potential_parent)) {
                return try self.allocator.dupe(u8, potential_parent);
            }
        }
        return null;
    }

    pub fn createIssue(self: *Self, issue: Issue, parent_id: ?[]const u8) !void {
        // Validate IDs to prevent path traversal
        try validateId(issue.id);
        if (parent_id) |pid| try validateId(pid);
        for (issue.blocks) |b| try validateId(b);

        // Prevent overwriting existing issues
        if (self.issueExists(issue.id)) {
            return StorageError.IssueAlreadyExists;
        }

        const content = try serializeFrontmatter(self.allocator, issue);
        defer self.allocator.free(content);

        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const path = if (parent_id) |pid| blk: {
            try self.ensureParentFolder(pid);
            break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ pid, issue.id }) catch return StorageError.IoError;
        } else blk: {
            // Check if a folder with this ID exists (child created before parent)
            const stat = self.dots_dir.statFile(issue.id) catch |err| switch (err) {
                error.FileNotFound => break :blk std.fmt.bufPrint(&path_buf, "{s}.md", .{issue.id}) catch return StorageError.IoError,
                else => return err,
            };
            if (stat.kind == .directory) {
                // Folder exists - write to {id}/{id}.md
                break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ issue.id, issue.id }) catch return StorageError.IoError;
            }
            break :blk std.fmt.bufPrint(&path_buf, "{s}.md", .{issue.id}) catch return StorageError.IoError;
        };

        try writeFileAtomic(self.dots_dir, path, content);
    }

    fn ensureParentFolder(self: *Self, parent_id: []const u8) !void {
        var path_buf: [MAX_PATH_LEN]u8 = undefined;

        // Check if parent is already a folder
        self.dots_dir.makeDir(parent_id) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Folder exists - check if parent.md exists in root and move it
                const old_path = std.fmt.bufPrint(&path_buf, "{s}.md", .{parent_id}) catch return StorageError.IoError;

                var new_path_buf: [MAX_PATH_LEN]u8 = undefined;
                const new_path = std.fmt.bufPrint(&new_path_buf, "{s}/{s}.md", .{ parent_id, parent_id }) catch return StorageError.IoError;

                self.dots_dir.rename(old_path, new_path) catch |err2| switch (err2) {
                    error.FileNotFound => {}, // Parent file not in root, already correct
                    else => return err2,
                };
                return;
            },
            else => return err,
        };

        // Folder created - need to move parent.md into it
        const old_path = std.fmt.bufPrint(&path_buf, "{s}.md", .{parent_id}) catch return StorageError.IoError;

        var new_path_buf: [MAX_PATH_LEN]u8 = undefined;
        const new_path = std.fmt.bufPrint(&new_path_buf, "{s}/{s}.md", .{ parent_id, parent_id }) catch return StorageError.IoError;

        self.dots_dir.rename(old_path, new_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Parent file doesn't exist yet, that's fine
            else => return err,
        };
    }

    pub fn updateStatus(self: *Self, id: []const u8, status: Status, closed_at: ?[]const u8, close_reason: ?[]const u8) !void {
        const path = try self.findIssuePath(id);
        defer self.allocator.free(path);

        var issue = try self.readIssueFromPath(path, id);
        defer issue.deinit(self.allocator);

        // If closing, check that all children are closed first
        if (status == .closed) {
            const children = try self.getChildren(id);
            defer freeChildIssues(self.allocator, children);
            for (children) |child| {
                if (child.issue.status != .closed) {
                    return StorageError.ChildrenNotClosed;
                }
            }
        }

        // When not closing, clear closed_at; when closing, use provided or keep existing
        const effective_closed_at: ?[]const u8 = if (status == .closed)
            (closed_at orelse issue.closed_at)
        else
            null;

        const effective_close_reason: ?[]const u8 = if (status == .closed)
            (close_reason orelse issue.close_reason)
        else
            null;

        const content = try serializeFrontmatter(self.allocator, issue.withStatus(status, effective_closed_at, effective_close_reason));
        defer self.allocator.free(content);

        try writeFileAtomic(self.dots_dir, path, content);

        // Handle archiving if closed
        if (status == .closed) {
            try self.maybeArchive(id, path);
        }
    }

    /// Archive an issue by ID (for migration of already-closed issues)
    pub fn archiveIssue(self: *Self, id: []const u8) !void {
        const path = self.findIssuePath(id) catch |err| switch (err) {
            StorageError.IssueNotFound => return StorageError.IssueNotFound,
            else => return err,
        };
        defer self.allocator.free(path);
        try self.maybeArchive(id, path);
    }

    fn maybeArchive(self: *Self, id: []const u8, path: []const u8) !void {
        // Don't archive if already in archive
        if (std.mem.startsWith(u8, path, "archive/")) return;

        // Check if this is a child (has parent in path)
        const parent = try self.extractParentFromPath(path);
        if (parent) |p| {
            self.allocator.free(p);
            // Child issue - don't move, parent will move the whole folder
            return;
        }

        // Check if this is a parent with children
        const is_folder = std.mem.indexOf(u8, path, "/") != null;
        if (is_folder) {
            // Check all children are closed
            const folder_name = path[0..std.mem.indexOf(u8, path, "/").?];
            var folder = try self.dots_dir.openDir(folder_name, .{ .iterate = true });
            defer folder.close();

            var iter = folder.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                    const child_id = entry.name[0 .. entry.name.len - 3];
                    if (std.mem.eql(u8, child_id, id)) continue; // Skip self

                    const child_issue = try self.getIssue(child_id) orelse continue;
                    defer child_issue.deinit(self.allocator);

                    if (child_issue.status != .closed) {
                        return StorageError.ChildrenNotClosed;
                    }
                }
            }

            // All children closed, move entire folder
            var archive_path_buf: [MAX_PATH_LEN]u8 = undefined;
            const archive_path = std.fmt.bufPrint(&archive_path_buf, "archive/{s}", .{folder_name}) catch return StorageError.IoError;
            try self.dots_dir.rename(folder_name, archive_path);
        } else {
            // Simple file, move to archive
            var archive_path_buf: [MAX_PATH_LEN]u8 = undefined;
            const archive_path = std.fmt.bufPrint(&archive_path_buf, "archive/{s}", .{path}) catch return StorageError.IoError;
            try self.dots_dir.rename(path, archive_path);
        }
    }

    pub fn deleteIssue(self: *Self, id: []const u8) !void {
        const path = try self.findIssuePath(id);
        defer self.allocator.free(path);

        // Clean up dangling dependency references before deleting
        try self.removeDependencyReferences(id);

        // Check if it's a folder (has children)
        if (std.mem.indexOf(u8, path, "/")) |slash_idx| {
            const folder_name = path[0..slash_idx];
            const filename = std.fs.path.basename(path);
            const file_id = filename[0 .. filename.len - 3];

            // If deleting parent, delete entire folder
            if (std.mem.eql(u8, file_id, folder_name)) {
                try self.dots_dir.deleteTree(folder_name);
                return;
            }
        }

        // Simple file deletion
        try self.dots_dir.deleteFile(path);
    }

    /// Remove all references to the given ID from other issues' blocks arrays
    /// Optimized: uses already-loaded issues instead of re-reading from disk
    fn removeDependencyReferences(self: *Self, deleted_id: []const u8) !void {
        // Get all issues (including archived)
        const issues = try self.listAllIssuesIncludingArchived();
        defer freeIssues(self.allocator, issues);

        for (issues) |issue| {
            // Check if this issue references the deleted ID
            var has_reference = false;
            for (issue.blocks) |b| {
                if (std.mem.eql(u8, b, deleted_id)) {
                    has_reference = true;
                    break;
                }
            }

            if (!has_reference) continue;

            // Build new blocks without the removed dependency (using already-loaded issue)
            var new_blocks: std.ArrayList([]const u8) = .{};
            errdefer {
                for (new_blocks.items) |b| self.allocator.free(b);
                new_blocks.deinit(self.allocator);
            }

            for (issue.blocks) |b| {
                if (!std.mem.eql(u8, b, deleted_id)) {
                    const duped = try self.allocator.dupe(u8, b);
                    try new_blocks.append(self.allocator, duped);
                }
            }

            const blocks_slice = try new_blocks.toOwnedSlice(self.allocator);
            defer {
                for (blocks_slice) |b| self.allocator.free(b);
                self.allocator.free(blocks_slice);
            }

            // Find path and write directly (no re-read needed)
            const path = try self.findIssuePath(issue.id);
            defer self.allocator.free(path);

            const content = try serializeFrontmatter(self.allocator, issue.withBlocks(blocks_slice));
            defer self.allocator.free(content);

            try writeFileAtomic(self.dots_dir, path, content);
        }
    }

    fn listAllIssuesIncludingArchived(self: *Self) ![]Issue {
        var issues: std.ArrayList(Issue) = .{};
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        // Collect from main dots dir
        try self.collectIssuesFromDir(self.dots_dir, "", null, &issues);

        // Also collect from archive
        if (self.dots_dir.openDir("archive", .{ .iterate = true })) |archive_dir| {
            var ad = archive_dir;
            defer ad.close();
            try self.collectIssuesFromDir(ad, "archive", null, &issues);
        } else |err| switch (err) {
            error.FileNotFound => {}, // Archive doesn't exist yet, that's fine
            else => return err,
        }

        return issues.toOwnedSlice(self.allocator);
    }

    pub fn listIssues(self: *Self, status_filter: ?Status) ![]Issue {
        var issues: std.ArrayList(Issue) = .{};
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        try self.collectIssuesFromDir(self.dots_dir, "", status_filter, &issues);

        // Sort by priority, then created_at
        std.mem.sort(Issue, issues.items, {}, Issue.order);

        return issues.toOwnedSlice(self.allocator);
    }

    fn collectIssuesFromDir(self: *Self, dir: fs.Dir, prefix: []const u8, status_filter: ?Status, issues: *std.ArrayList(Issue)) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                const id = entry.name[0 .. entry.name.len - 3];
                var path_buf: [MAX_PATH_LEN]u8 = undefined;
                const path = if (prefix.len > 0)
                    std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ prefix, entry.name }) catch return StorageError.IoError
                else
                    entry.name;

                // Only skip expected parsing errors; propagate IO/allocation errors
                const issue = self.readIssueFromPath(path, id) catch |err| switch (err) {
                    StorageError.InvalidFrontmatter, StorageError.InvalidStatus => continue, // Malformed file, skip
                    else => return err, // IO/allocation errors must propagate
                };

                if (status_filter) |filter| {
                    if (issue.status != filter) {
                        issue.deinit(self.allocator);
                        continue;
                    }
                }

                issues.append(self.allocator, issue) catch |err| {
                    issue.deinit(self.allocator);
                    return err;
                };
            } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "archive")) {
                var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                defer subdir.close();

                var sub_prefix_buf: [MAX_PATH_LEN]u8 = undefined;
                const sub_prefix = if (prefix.len > 0)
                    std.fmt.bufPrint(&sub_prefix_buf, "{s}/{s}", .{ prefix, entry.name }) catch return StorageError.IoError
                else
                    entry.name;

                try self.collectIssuesFromDir(subdir, sub_prefix, status_filter, issues);
            }
        }
    }

    pub fn getReadyIssues(self: *Self) ![]Issue {
        const all_issues = try self.listIssues(null);
        defer freeIssues(self.allocator, all_issues);

        var status_by_id = StatusMap.init(self.allocator);
        defer status_by_id.deinit();
        if (all_issues.len <= std.math.maxInt(u32)) {
            try status_by_id.ensureTotalCapacity(@intCast(all_issues.len));
        }
        for (all_issues) |issue| {
            try status_by_id.put(issue.id, issue.status);
        }

        var ready: std.ArrayList(Issue) = .{};
        errdefer {
            for (ready.items) |*iss| iss.deinit(self.allocator);
            ready.deinit(self.allocator);
        }

        for (all_issues) |issue| {
            if (issue.status != .open) continue;
            if (isBlockedByStatusMap(issue.blocks, &status_by_id)) continue;

            // Clone the issue since we're freeing all_issues
            const cloned = try self.cloneIssue(issue);
            try ready.append(self.allocator, cloned);
        }

        return ready.toOwnedSlice(self.allocator);
    }

    fn isBlockedByStatusMap(blocks: []const []const u8, status_by_id: *const StatusMap) bool {
        for (blocks) |blocker_id| {
            const status = status_by_id.get(blocker_id) orelse continue;
            if (status == .open or status == .active) return true;
        }
        return false;
    }

    fn isBlocked(self: *Self, issue: Issue) !bool {
        for (issue.blocks) |blocker_id| {
            const blocker = try self.getIssue(blocker_id) orelse continue;
            defer blocker.deinit(self.allocator);

            if (blocker.status == .open or blocker.status == .active) {
                return true;
            }
        }
        return false;
    }

    fn cloneIssue(self: *Self, issue: Issue) !Issue {
        return issue.clone(self.allocator);
    }

    pub fn getRootIssues(self: *Self) ![]Issue {
        var issues: std.ArrayList(Issue) = .{};
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        // Only collect from root level of .dots (not archive, not subdirs for children)
        var iter = self.dots_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                const id = entry.name[0 .. entry.name.len - 3];
                const issue = self.readIssueFromPath(entry.name, id) catch |err| switch (err) {
                    StorageError.InvalidFrontmatter, StorageError.InvalidStatus => continue,
                    else => return err,
                };

                if (issue.status != .closed) {
                    try issues.append(self.allocator, issue);
                } else {
                    issue.deinit(self.allocator);
                }
            } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "archive")) {
                // Folder = parent issue
                var path_buf: [MAX_PATH_LEN]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ entry.name, entry.name }) catch return StorageError.IoError;
                const issue = self.readIssueFromPath(path, entry.name) catch |err| switch (err) {
                    StorageError.InvalidFrontmatter, StorageError.InvalidStatus => continue,
                    else => return err,
                };

                if (issue.status != .closed) {
                    try issues.append(self.allocator, issue);
                } else {
                    issue.deinit(self.allocator);
                }
            }
        }

        // Sort by priority, then created_at
        std.mem.sort(Issue, issues.items, {}, Issue.order);

        return issues.toOwnedSlice(self.allocator);
    }

    pub fn getChildren(self: *Self, parent_id: []const u8) ![]ChildIssue {
        var children: std.ArrayList(ChildIssue) = .{};
        errdefer {
            for (children.items) |*c| c.deinit(self.allocator);
            children.deinit(self.allocator);
        }

        // Open parent folder
        var folder = self.dots_dir.openDir(parent_id, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return children.toOwnedSlice(self.allocator),
            else => return err,
        };
        defer folder.close();

        var iter = folder.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                const id = entry.name[0 .. entry.name.len - 3];
                if (std.mem.eql(u8, id, parent_id)) continue; // Skip parent itself

                var path_buf: [MAX_PATH_LEN]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ parent_id, entry.name }) catch return StorageError.IoError;

                const issue = self.readIssueFromPath(path, id) catch |err| switch (err) {
                    StorageError.InvalidFrontmatter, StorageError.InvalidStatus => continue,
                    else => return err,
                };
                const blocked = try self.isBlocked(issue);

                try children.append(self.allocator, .{
                    .issue = issue,
                    .blocked = blocked,
                });
            }
        }

        // Sort by priority, then created_at
        std.mem.sort(ChildIssue, children.items, {}, ChildIssue.order);

        return children.toOwnedSlice(self.allocator);
    }

    pub fn searchIssues(self: *Self, query: []const u8) ![]Issue {
        const all_issues = try self.listIssues(null);
        defer freeIssues(self.allocator, all_issues);

        var matches: std.ArrayList(Issue) = .{};
        errdefer {
            for (matches.items) |*iss| iss.deinit(self.allocator);
            matches.deinit(self.allocator);
        }

        for (all_issues) |issue| {
            if (containsIgnoreCase(issue.title, query) or containsIgnoreCase(issue.description, query)) {
                const cloned = try self.cloneIssue(issue);
                try matches.append(self.allocator, cloned);
            }
        }

        return matches.toOwnedSlice(self.allocator);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (asciiEqualIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ac, bc| {
            if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
        }
        return true;
    }

    pub fn addDependency(self: *Self, issue_id: []const u8, depends_on_id: []const u8, dep_type: []const u8) !void {
        // Validate IDs to prevent path traversal
        try validateId(issue_id);
        try validateId(depends_on_id);

        // Verify the dependency target exists
        if (!self.issueExists(depends_on_id)) {
            return StorageError.DependencyNotFound;
        }

        // For "blocks" type, add to the issue's blocks array
        if (std.mem.eql(u8, dep_type, "blocks")) {
            // Check for cycle
            if (try self.wouldCreateCycle(issue_id, depends_on_id)) {
                return StorageError.DependencyCycle;
            }

            const path = try self.findIssuePath(issue_id);
            defer self.allocator.free(path);

            var issue = try self.readIssueFromPath(path, issue_id);
            defer issue.deinit(self.allocator);

            // Check if already in blocks
            for (issue.blocks) |b| {
                if (std.mem.eql(u8, b, depends_on_id)) return; // Already exists
            }

            // Add to blocks array
            var new_blocks: std.ArrayList([]const u8) = .{};
            errdefer {
                for (new_blocks.items) |b| self.allocator.free(b);
                new_blocks.deinit(self.allocator);
            }

            for (issue.blocks) |b| {
                const duped = try self.allocator.dupe(u8, b);
                try new_blocks.append(self.allocator, duped);
            }
            const new_dep = try self.allocator.dupe(u8, depends_on_id);
            try new_blocks.append(self.allocator, new_dep);

            const blocks_slice = try new_blocks.toOwnedSlice(self.allocator);
            defer {
                for (blocks_slice) |b| self.allocator.free(b);
                self.allocator.free(blocks_slice);
            }

            const content = try serializeFrontmatter(self.allocator, issue.withBlocks(blocks_slice));
            defer self.allocator.free(content);

            try writeFileAtomic(self.dots_dir, path, content);
        }
        // "parent-child" type is handled by file location, not frontmatter
    }

    fn wouldCreateCycle(self: *Self, from_id: []const u8, to_id: []const u8) !bool {
        // BFS from to_id following blocks dependencies
        // If we reach from_id, cycle would be created
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var queue: std.ArrayList([]const u8) = .{};
        defer {
            for (queue.items) |item| self.allocator.free(item);
            queue.deinit(self.allocator);
        }

        const start = try self.allocator.dupe(u8, to_id);
        try queue.append(self.allocator, start);

        // Use index instead of orderedRemove(0) for O(1) dequeue
        var head: usize = 0;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;

            if (std.mem.eql(u8, current, from_id)) {
                return true; // Cycle detected
            }

            if (visited.contains(current)) continue;
            try visited.put(current, {});

            const issue = try self.getIssue(current) orelse continue;
            defer issue.deinit(self.allocator);

            for (issue.blocks) |blocker| {
                if (!visited.contains(blocker)) {
                    const duped = try self.allocator.dupe(u8, blocker);
                    try queue.append(self.allocator, duped);
                }
            }
        }

        return false;
    }

    pub fn purgeArchive(self: *Self) !void {
        // deleteTree succeeds silently if the directory doesn't exist
        try self.dots_dir.deleteTree("archive");

        // Recreate empty archive directory (handle race if another process recreated it)
        self.dots_dir.makeDir("archive") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Config stored in .dots/config as simple key=value lines
    pub fn getConfig(self: *Self, key: []const u8) !?[]const u8 {
        const file = self.dots_dir.openFile("config", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 64 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const eq_idx = std.mem.indexOf(u8, line, "=") orelse continue;
            if (std.mem.eql(u8, line[0..eq_idx], key)) {
                return try self.allocator.dupe(u8, line[eq_idx + 1 ..]);
            }
        }

        return null;
    }

    pub fn setConfig(self: *Self, key: []const u8, value: []const u8) !void {
        // Read existing config
        var config = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var iter = config.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            config.deinit();
        }

        const file = self.dots_dir.openFile("config", .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        if (file) |f| {
            defer f.close();
            const content = try f.readToEndAlloc(self.allocator, 64 * 1024);
            defer self.allocator.free(content);

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const eq_idx = std.mem.indexOf(u8, line, "=") orelse continue;
                const k = try self.allocator.dupe(u8, line[0..eq_idx]);
                const v = try self.allocator.dupe(u8, line[eq_idx + 1 ..]);
                try config.put(k, v);
            }
        }

        // Update or add key
        if (config.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try config.put(k, v);

        // Build config content
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        var iter = config.iterator();
        while (iter.next()) |entry| {
            try buf.appendSlice(self.allocator, entry.key_ptr.*);
            try buf.append(self.allocator, '=');
            try buf.appendSlice(self.allocator, entry.value_ptr.*);
            try buf.append(self.allocator, '\n');
        }

        try writeFileAtomic(self.dots_dir, "config", buf.items);
    }

    /// Create a plan with its folder structure and artifacts subfolder
    pub fn createPlanWithArtifacts(self: *Self, issue: Issue) !void {
        validateId(issue.id) catch return StorageError.InvalidId;

        // Create plan folder: {id}/
        self.dots_dir.makeDir(issue.id) catch |err| switch (err) {
            error.PathAlreadyExists => return StorageError.IssueAlreadyExists,
            else => return StorageError.IoError,
        };
        errdefer self.dots_dir.deleteTree(issue.id) catch {};

        // Create artifacts subfolder: {id}/artifacts/
        var plan_dir = self.dots_dir.openDir(issue.id, .{}) catch return StorageError.IoError;
        defer plan_dir.close();

        plan_dir.makeDir("artifacts") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return StorageError.IoError,
        };

        // Create plan file: {id}/{id}.md
        const content = try serializeFrontmatter(self.allocator, issue);
        defer self.allocator.free(content);

        var path_buf: [MAX_PATH_LEN]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ issue.id, issue.id }) catch return StorageError.IoError;

        try writeFileAtomic(self.dots_dir, path, content);
    }

    /// Update an existing issue's content (preserves location/parent)
    pub fn updateIssue(self: *Self, issue: Issue) !void {
        const path = try self.findIssuePath(issue.id);
        defer self.allocator.free(path);

        const content = try serializeFrontmatter(self.allocator, issue);
        defer self.allocator.free(content);

        try writeFileAtomic(self.dots_dir, path, content);
    }

    /// Move a plan (and its children) to the backlog directory
    pub fn moveToBacklog(self: *Self, id: []const u8) !void {
        const path = try self.findIssuePath(id);
        defer self.allocator.free(path);

        // Ensure backlog directory exists
        self.dots_dir.makeDir("backlog") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Check if it's a folder (parent with children)
        if (std.mem.indexOf(u8, path, "/")) |slash_idx| {
            const folder_name = path[0..slash_idx];
            const filename = std.fs.path.basename(path);
            const file_id = filename[0 .. filename.len - 3];

            // Only move parent folder (not individual children)
            if (std.mem.eql(u8, file_id, folder_name)) {
                var dest_path_buf: [MAX_PATH_LEN]u8 = undefined;
                const dest_path = std.fmt.bufPrint(&dest_path_buf, "backlog/{s}", .{folder_name}) catch return StorageError.IoError;
                try self.dots_dir.rename(folder_name, dest_path);
                return;
            }
        }

        // Simple file, move to backlog
        var dest_path_buf: [MAX_PATH_LEN]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "backlog/{s}", .{path}) catch return StorageError.IoError;
        try self.dots_dir.rename(path, dest_path);
    }

    /// Move a plan from backlog back to active (root of .dots)
    pub fn activateFromBacklog(self: *Self, id: []const u8) !void {
        // Look for the issue in backlog
        var backlog_dir = self.dots_dir.openDir("backlog", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return StorageError.IssueNotFound,
            else => return err,
        };
        defer backlog_dir.close();

        // Check for direct file
        var file_path_buf: [MAX_PATH_LEN]u8 = undefined;
        const file_name = std.fmt.bufPrint(&file_path_buf, "{s}.md", .{id}) catch return StorageError.IoError;

        backlog_dir.access(file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Check for folder
                backlog_dir.access(id, .{}) catch return StorageError.IssueNotFound;

                // Move folder from backlog to root
                var src_buf: [MAX_PATH_LEN]u8 = undefined;
                const src = std.fmt.bufPrint(&src_buf, "backlog/{s}", .{id}) catch return StorageError.IoError;
                try self.dots_dir.rename(src, id);
                return;
            },
            else => return err,
        };

        // Move file from backlog to root
        var src_buf: [MAX_PATH_LEN]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "backlog/{s}", .{file_name}) catch return StorageError.IoError;
        try self.dots_dir.rename(src, file_name);
    }
};

// ============================================================================
// Unit Tests for slugify and ID generation
// ============================================================================

test "slugify: basic title conversion" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "Hello World");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("hello-world", slug);
}

test "slugify: removes special characters" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "Fix bug! @user: it's broken!!!");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("fix-bug-user-its-broken", slug);
}

test "slugify: collapses multiple hyphens" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "foo - - bar --- baz");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("foo-bar-baz", slug);
}

test "slugify: trims leading and trailing hyphens" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "   Hello World   ");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("hello-world", slug);
}

test "slugify: handles empty string" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("untitled", slug);
}

test "slugify: handles all special characters" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "!@#$%^&*()");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("untitled", slug);
}

test "slugify: truncates long titles" {
    const allocator = std.testing.allocator;

    const long_title = "This is a very long title that should be truncated at a word boundary to stay within the limit";
    const slug = try slugify(allocator, long_title);
    defer allocator.free(slug);

    // Should be <= MAX_SLUG_LEN (40 characters)
    try std.testing.expect(slug.len <= MAX_SLUG_LEN);
    // Should not end with hyphen
    try std.testing.expect(slug[slug.len - 1] != '-');
}

test "slugify: preserves numbers" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "Fix bug #123");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("fix-bug-123", slug);
}

test "slugify: handles underscores" {
    const allocator = std.testing.allocator;

    const slug = try slugify(allocator, "fix_authentication_bug");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("fix-authentication-bug", slug);
}

test "getNextId: empty directory returns 1" {
    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const next = try getNextId(tmp_dir.dir, "t");
    try std.testing.expectEqual(@as(u32, 1), next);
}

test "getNextId: returns max + 1" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    // Create some files with prefixed names
    const files_to_create = [_][]const u8{ "t1-task.md", "t2-task.md", "t5-task.md" };
    for (files_to_create) |name| {
        const file = try tmp_dir.dir.createFile(name, .{});
        file.close();
    }

    const next = try getNextId(tmp_dir.dir, "t");
    try std.testing.expectEqual(@as(u32, 6), next);
}

test "getNextId: ignores other prefixes" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    // Create files with different prefixes
    const files_to_create = [_][]const u8{ "t1-task.md", "m1-milestone.md", "p1-plan.md" };
    for (files_to_create) |name| {
        const file = try tmp_dir.dir.createFile(name, .{});
        file.close();
    }

    const next_t = try getNextId(tmp_dir.dir, "t");
    try std.testing.expectEqual(@as(u32, 2), next_t);

    const next_m = try getNextId(tmp_dir.dir, "m");
    try std.testing.expectEqual(@as(u32, 2), next_m);

    const next_p = try getNextId(tmp_dir.dir, "p");
    try std.testing.expectEqual(@as(u32, 2), next_p);
}

test "getNextId: handles directories" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    // Create directories (folders for plans/milestones)
    try tmp_dir.dir.makeDir("p1-first-plan");
    try tmp_dir.dir.makeDir("p3-third-plan");

    const next = try getNextId(tmp_dir.dir, "p");
    try std.testing.expectEqual(@as(u32, 4), next);
}

test "generateHierarchicalId: creates correct format" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const id = try generateHierarchicalId(allocator, tmp_dir.dir, "task", "Fix authentication bug");
    defer allocator.free(id);

    // Should be t1-fix-authentication-bug
    try std.testing.expectEqualStrings("t1-fix-authentication-bug", id);
}

test "generateHierarchicalId: increments correctly" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    // Create a task file
    const file = try tmp_dir.dir.createFile("t1-existing.md", .{});
    file.close();

    const id = try generateHierarchicalId(allocator, tmp_dir.dir, "task", "New task");
    defer allocator.free(id);

    // Should be t2-new-task (after t1)
    try std.testing.expectEqualStrings("t2-new-task", id);
}

test "generateHierarchicalId: handles plan type" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const id = try generateHierarchicalId(allocator, tmp_dir.dir, "plan", "User Authentication");
    defer allocator.free(id);

    try std.testing.expectEqualStrings("p1-user-authentication", id);
}

test "generateHierarchicalId: handles milestone type" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const id = try generateHierarchicalId(allocator, tmp_dir.dir, "milestone", "Backend Setup");
    defer allocator.free(id);

    try std.testing.expectEqualStrings("m1-backend-setup", id);
}

test "IssueTypePrefix: maps correctly" {
    try std.testing.expectEqual(IssueTypePrefix.plan, IssueTypePrefix.fromString("plan").?);
    try std.testing.expectEqual(IssueTypePrefix.milestone, IssueTypePrefix.fromString("milestone").?);
    try std.testing.expectEqual(IssueTypePrefix.task, IssueTypePrefix.fromString("task").?);
    try std.testing.expectEqual(@as(?IssueTypePrefix, null), IssueTypePrefix.fromString("unknown"));
}

test "IssueTypePrefix: returns correct prefix" {
    try std.testing.expectEqualStrings("p", IssueTypePrefix.plan.prefix());
    try std.testing.expectEqualStrings("m", IssueTypePrefix.milestone.prefix());
    try std.testing.expectEqualStrings("t", IssueTypePrefix.task.prefix());
}
