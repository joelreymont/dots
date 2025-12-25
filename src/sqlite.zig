const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sqlite3.h");
});

// Use SQLITE_STATIC (null) since we always pass string slices that outlive statement execution

pub const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ExecFailed,
};

pub const Db = struct {
    handle: *c.sqlite3,
    allocator: Allocator,

    const Self = @This();

    pub fn open(allocator: Allocator, path: [:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return SqliteError.OpenFailed;
        }
        errdefer _ = c.sqlite3_close(db.?);

        const self = Self{
            .handle = db.?,
            .allocator = allocator,
        };

        // Enable WAL mode for better concurrency
        try self.exec("PRAGMA journal_mode=WAL");
        try self.exec("PRAGMA foreign_keys=ON");
        try self.exec("PRAGMA busy_timeout=5000");

        return self;
    }

    pub fn close(self: *Self) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: Self, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return SqliteError.ExecFailed;
        }
    }

    pub fn prepare(self: Self, sql: [:0]const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            return SqliteError.PrepareFailed;
        }
        return Statement{ .handle = stmt.?, .allocator = self.allocator };
    }

    pub fn lastInsertRowId(self: Self) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    allocator: Allocator,

    const Self = @This();

    pub fn finalize(self: *Self) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn reset(self: *Self) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn bindText(self: *Self, idx: c_int, text: []const u8) !void {
        const rc = c.sqlite3_bind_text(self.handle, idx, text.ptr, @intCast(text.len), null);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindInt(self: *Self, idx: c_int, val: i64) !void {
        const rc = c.sqlite3_bind_int64(self.handle, idx, val);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn bindNull(self: *Self, idx: c_int) !void {
        const rc = c.sqlite3_bind_null(self.handle, idx);
        if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
    }

    pub fn step(self: *Self) !bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return SqliteError.StepFailed;
    }

    pub fn columnText(self: *Self, idx: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.handle, idx);
        return ptr[0..@intCast(len)];
    }

    pub fn columnInt(self: *Self, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }
};

// Beads-compatible schema
const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS issues (
    \\    id TEXT PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    status TEXT NOT NULL DEFAULT 'open',
    \\    priority INTEGER NOT NULL DEFAULT 2,
    \\    issue_type TEXT NOT NULL DEFAULT 'task',
    \\    assignee TEXT,
    \\    created_at TEXT NOT NULL,
    \\    updated_at TEXT NOT NULL,
    \\    closed_at TEXT,
    \\    close_reason TEXT
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_issues_status ON issues(status);
    \\CREATE INDEX IF NOT EXISTS idx_issues_priority ON issues(priority);
    \\
    \\CREATE TABLE IF NOT EXISTS dependencies (
    \\    issue_id TEXT NOT NULL,
    \\    depends_on_id TEXT NOT NULL,
    \\    type TEXT NOT NULL DEFAULT 'blocks',
    \\    created_at TEXT NOT NULL,
    \\    created_by TEXT NOT NULL DEFAULT '',
    \\    PRIMARY KEY (issue_id, depends_on_id),
    \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE,
    \\    FOREIGN KEY (depends_on_id) REFERENCES issues(id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_deps_issue ON dependencies(issue_id);
    \\CREATE INDEX IF NOT EXISTS idx_deps_depends_on ON dependencies(depends_on_id);
    \\
    \\CREATE TABLE IF NOT EXISTS dirty_issues (
    \\    issue_id TEXT PRIMARY KEY,
    \\    marked_at TEXT NOT NULL,
    \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS config (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
;

pub const Issue = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: []const u8,
    priority: i64,
    issue_type: []const u8,
    assignee: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    closed_at: ?[]const u8,
    close_reason: ?[]const u8,
    // Dependency (for ready check)
    after: ?[]const u8,
    parent: ?[]const u8,

    pub fn deinit(self: *const Issue, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.status);
        allocator.free(self.issue_type);
        if (self.assignee) |s| allocator.free(s);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        if (self.closed_at) |s| allocator.free(s);
        if (self.close_reason) |s| allocator.free(s);
        if (self.after) |s| allocator.free(s);
        if (self.parent) |s| allocator.free(s);
    }
};

pub fn freeIssues(allocator: Allocator, issues: []const Issue) void {
    for (issues) |*issue| {
        issue.deinit(allocator);
    }
    allocator.free(issues);
}

pub const Storage = struct {
    db: Db,
    allocator: Allocator,

    // Prepared statements
    insert_stmt: Statement,
    update_status_stmt: Statement,
    delete_stmt: Statement,
    get_by_id_stmt: Statement,
    list_stmt: Statement,
    add_dep_stmt: Statement,
    get_blockers_stmt: Statement,

    const Self = @This();

    pub fn open(allocator: Allocator, path: [:0]const u8) !Self {
        var db = try Db.open(allocator, path);
        errdefer db.close();

        // Create schema
        var iter = std.mem.splitSequence(u8, SCHEMA, ";");
        while (iter.next()) |sql| {
            const trimmed = std.mem.trim(u8, sql, " \n\r\t");
            if (trimmed.len == 0) continue;

            // Create null-terminated copy
            const sql_z = try allocator.allocSentinel(u8, trimmed.len, 0);
            defer allocator.free(sql_z);
            @memcpy(sql_z, trimmed);

            db.exec(sql_z) catch |err| {
                std.debug.print("SQL error at: {s}\n", .{trimmed});
                return err;
            };
        }

        // Prepare statements with proper cleanup on failure
        var insert_stmt = try db.prepare(
            "INSERT INTO issues (id, title, description, status, priority, issue_type, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        );
        errdefer insert_stmt.finalize();

        var update_status_stmt = try db.prepare(
            "UPDATE issues SET status = ?2, updated_at = ?3, closed_at = ?4, close_reason = ?5 WHERE id = ?1",
        );
        errdefer update_status_stmt.finalize();

        var delete_stmt = try db.prepare("DELETE FROM issues WHERE id = ?1");
        errdefer delete_stmt.finalize();

        var get_by_id_stmt = try db.prepare("SELECT id, title, description, status, priority, issue_type, assignee, created_at, updated_at, closed_at, close_reason FROM issues WHERE id = ?1");
        errdefer get_by_id_stmt.finalize();

        var list_stmt = try db.prepare("SELECT id, title, description, status, priority, issue_type, assignee, created_at, updated_at, closed_at, close_reason FROM issues ORDER BY priority, created_at");
        errdefer list_stmt.finalize();

        var add_dep_stmt = try db.prepare(
            "INSERT OR REPLACE INTO dependencies (issue_id, depends_on_id, type, created_at, created_by) VALUES (?1, ?2, ?3, ?4, ?5)",
        );
        errdefer add_dep_stmt.finalize();

        var get_blockers_stmt = try db.prepare(
            "SELECT depends_on_id FROM dependencies WHERE issue_id = ?1 AND type = 'blocks'",
        );
        errdefer get_blockers_stmt.finalize();

        return Self{
            .db = db,
            .allocator = allocator,
            .insert_stmt = insert_stmt,
            .update_status_stmt = update_status_stmt,
            .delete_stmt = delete_stmt,
            .get_by_id_stmt = get_by_id_stmt,
            .list_stmt = list_stmt,
            .add_dep_stmt = add_dep_stmt,
            .get_blockers_stmt = get_blockers_stmt,
        };
    }

    pub fn close(self: *Self) void {
        self.insert_stmt.finalize();
        self.update_status_stmt.finalize();
        self.delete_stmt.finalize();
        self.get_by_id_stmt.finalize();
        self.list_stmt.finalize();
        self.add_dep_stmt.finalize();
        self.get_blockers_stmt.finalize();
        self.db.close();
    }

    pub fn createIssue(self: *Self, issue: Issue) !void {
        try self.db.exec("BEGIN TRANSACTION");
        errdefer self.db.exec("ROLLBACK") catch {};

        self.insert_stmt.reset();
        try self.insert_stmt.bindText(1, issue.id);
        try self.insert_stmt.bindText(2, issue.title);
        try self.insert_stmt.bindText(3, issue.description);
        try self.insert_stmt.bindText(4, issue.status);
        try self.insert_stmt.bindInt(5, issue.priority);
        try self.insert_stmt.bindText(6, issue.issue_type);
        try self.insert_stmt.bindText(7, issue.created_at);
        try self.insert_stmt.bindText(8, issue.updated_at);
        _ = try self.insert_stmt.step();

        // Add dependencies
        if (issue.after) |after_id| {
            try self.addDependency(issue.id, after_id, "blocks", issue.created_at);
        }
        if (issue.parent) |parent_id| {
            try self.addDependency(issue.id, parent_id, "parent-child", issue.created_at);
        }

        try self.markDirty(issue.id, issue.created_at);
        try self.db.exec("COMMIT");
    }

    pub fn updateStatus(self: *Self, id: []const u8, status: []const u8, updated_at: []const u8, closed_at: ?[]const u8, reason: ?[]const u8) !void {
        self.update_status_stmt.reset();
        try self.update_status_stmt.bindText(1, id);
        try self.update_status_stmt.bindText(2, status);
        try self.update_status_stmt.bindText(3, updated_at);
        if (closed_at) |ca| {
            try self.update_status_stmt.bindText(4, ca);
        } else {
            try self.update_status_stmt.bindNull(4);
        }
        if (reason) |r| {
            try self.update_status_stmt.bindText(5, r);
        } else {
            try self.update_status_stmt.bindNull(5);
        }
        _ = try self.update_status_stmt.step();
        try self.markDirty(id, updated_at);
    }

    pub fn deleteIssue(self: *Self, id: []const u8) !void {
        self.delete_stmt.reset();
        try self.delete_stmt.bindText(1, id);
        _ = try self.delete_stmt.step();
    }

    pub fn getIssue(self: *Self, id: []const u8) !?Issue {
        self.get_by_id_stmt.reset();
        try self.get_by_id_stmt.bindText(1, id);
        if (try self.get_by_id_stmt.step()) {
            return try self.rowToIssue(&self.get_by_id_stmt);
        }
        return null;
    }

    pub fn listIssues(self: *Self, status_filter: ?[]const u8) ![]Issue {
        var issues: std.ArrayList(Issue) = .empty;
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        self.list_stmt.reset();
        while (try self.list_stmt.step()) {
            const issue = try self.rowToIssue(&self.list_stmt);
            if (status_filter) |filter| {
                if (!std.mem.eql(u8, issue.status, filter)) {
                    issue.deinit(self.allocator);
                    continue;
                }
            }
            try issues.append(self.allocator, issue);
        }

        return issues.toOwnedSlice(self.allocator);
    }

    pub fn getReadyIssues(self: *Self) ![]Issue {
        // Get all open issues that have no open blockers
        const sql =
            \\SELECT i.id, i.title, i.description, i.status, i.priority, i.issue_type,
            \\       i.assignee, i.created_at, i.updated_at, i.closed_at, i.close_reason
            \\FROM issues i
            \\WHERE i.status = 'open'
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM dependencies d
            \\    JOIN issues blocker ON d.depends_on_id = blocker.id
            \\    WHERE d.issue_id = i.id
            \\      AND d.type = 'blocks'
            \\      AND blocker.status IN ('open', 'active', 'in_progress')
            \\  )
            \\ORDER BY i.priority, i.created_at
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();

        var issues: std.ArrayList(Issue) = .empty;
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        while (try stmt.step()) {
            try issues.append(self.allocator, try self.rowToIssue(&stmt));
        }

        return issues.toOwnedSlice(self.allocator);
    }

    fn rowToIssue(self: *Self, stmt: *Statement) !Issue {
        const id = try self.dupeText(stmt.columnText(0) orelse "");
        errdefer self.allocator.free(id);

        const title = try self.dupeText(stmt.columnText(1) orelse "");
        errdefer self.allocator.free(title);

        const description = try self.dupeText(stmt.columnText(2) orelse "");
        errdefer self.allocator.free(description);

        const status = try self.dupeText(stmt.columnText(3) orelse "open");
        errdefer self.allocator.free(status);

        const issue_type = try self.dupeText(stmt.columnText(5) orelse "task");
        errdefer self.allocator.free(issue_type);

        const assignee = if (stmt.columnText(6)) |t| try self.dupeText(t) else null;
        errdefer if (assignee) |a| self.allocator.free(a);

        const created_at = try self.dupeText(stmt.columnText(7) orelse "");
        errdefer self.allocator.free(created_at);

        const updated_at = try self.dupeText(stmt.columnText(8) orelse "");
        errdefer self.allocator.free(updated_at);

        const closed_at = if (stmt.columnText(9)) |t| try self.dupeText(t) else null;
        errdefer if (closed_at) |s| self.allocator.free(s);

        const close_reason = if (stmt.columnText(10)) |t| try self.dupeText(t) else null;
        errdefer if (close_reason) |s| self.allocator.free(s);

        return Issue{
            .id = id,
            .title = title,
            .description = description,
            .status = status,
            .priority = stmt.columnInt(4),
            .issue_type = issue_type,
            .assignee = assignee,
            .created_at = created_at,
            .updated_at = updated_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .after = null,
            .parent = null,
        };
    }

    fn dupeText(self: *Self, text: []const u8) ![]const u8 {
        return self.allocator.dupe(u8, text);
    }

    pub fn addDependency(self: *Self, issue_id: []const u8, depends_on_id: []const u8, dep_type: []const u8, created_at: []const u8) !void {
        self.add_dep_stmt.reset();
        try self.add_dep_stmt.bindText(1, issue_id);
        try self.add_dep_stmt.bindText(2, depends_on_id);
        try self.add_dep_stmt.bindText(3, dep_type);
        try self.add_dep_stmt.bindText(4, created_at);
        try self.add_dep_stmt.bindText(5, "");
        _ = try self.add_dep_stmt.step();
    }

    pub fn markDirty(self: *Self, issue_id: []const u8, marked_at: []const u8) !void {
        const sql = "INSERT OR REPLACE INTO dirty_issues (issue_id, marked_at) VALUES (?1, ?2)";
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, issue_id);
        try stmt.bindText(2, marked_at);
        _ = try stmt.step();
    }

    pub fn getDirtyIssues(self: *Self) ![][]const u8 {
        var stmt = try self.db.prepare("SELECT issue_id FROM dirty_issues ORDER BY marked_at");
        defer stmt.finalize();

        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }

        while (try stmt.step()) {
            if (stmt.columnText(0)) |id| {
                try ids.append(self.allocator, try self.allocator.dupe(u8, id));
            }
        }

        return ids.toOwnedSlice(self.allocator);
    }

    pub fn clearDirty(self: *Self, issue_ids: []const []const u8) !void {
        var stmt = try self.db.prepare("DELETE FROM dirty_issues WHERE issue_id = ?1");
        defer stmt.finalize();

        for (issue_ids) |id| {
            stmt.reset();
            try stmt.bindText(1, id);
            _ = try stmt.step();
        }
    }

    // Get children for tree view
    pub fn getChildren(self: *Self, parent_id: []const u8) ![]Issue {
        const sql =
            \\SELECT i.id, i.title, i.description, i.status, i.priority, i.issue_type,
            \\       i.assignee, i.created_at, i.updated_at, i.closed_at, i.close_reason
            \\FROM issues i
            \\JOIN dependencies d ON i.id = d.issue_id
            \\WHERE d.depends_on_id = ?1 AND d.type = 'parent-child'
            \\ORDER BY i.priority, i.created_at
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, parent_id);

        var issues: std.ArrayList(Issue) = .empty;
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        while (try stmt.step()) {
            try issues.append(self.allocator, try self.rowToIssue(&stmt));
        }

        return issues.toOwnedSlice(self.allocator);
    }

    // Get root issues (no parent) for tree view
    pub fn getRootIssues(self: *Self) ![]Issue {
        const sql =
            \\SELECT i.id, i.title, i.description, i.status, i.priority, i.issue_type,
            \\       i.assignee, i.created_at, i.updated_at, i.closed_at, i.close_reason
            \\FROM issues i
            \\WHERE i.status != 'closed'
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM dependencies d
            \\    WHERE d.issue_id = i.id AND d.type = 'parent-child'
            \\  )
            \\ORDER BY i.priority, i.created_at
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();

        var issues: std.ArrayList(Issue) = .empty;
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        while (try stmt.step()) {
            try issues.append(self.allocator, try self.rowToIssue(&stmt));
        }

        return issues.toOwnedSlice(self.allocator);
    }

    // Check if issue is blocked
    pub fn isBlocked(self: *Self, issue_id: []const u8) !bool {
        const sql =
            \\SELECT 1 FROM dependencies d
            \\JOIN issues blocker ON d.depends_on_id = blocker.id
            \\WHERE d.issue_id = ?1
            \\  AND d.type = 'blocks'
            \\  AND blocker.status IN ('open', 'active', 'in_progress')
            \\LIMIT 1
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, issue_id);
        return try stmt.step();
    }

    // Search issues
    pub fn searchIssues(self: *Self, query: []const u8) ![]Issue {
        const sql =
            \\SELECT id, title, description, status, priority, issue_type,
            \\       assignee, created_at, updated_at, closed_at, close_reason
            \\FROM issues
            \\WHERE title LIKE '%' || ?1 || '%' OR description LIKE '%' || ?1 || '%'
            \\ORDER BY priority, created_at
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, query);

        var issues: std.ArrayList(Issue) = .empty;
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        while (try stmt.step()) {
            try issues.append(self.allocator, try self.rowToIssue(&stmt));
        }

        return issues.toOwnedSlice(self.allocator);
    }
};

// Hydrate from beads JSONL
pub fn hydrateFromJsonl(storage: *Storage, allocator: Allocator, jsonl_path: []const u8) !usize {
    const file = std.fs.cwd().openFile(jsonl_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(content);

    var count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        // Map beads fields to our schema
        const id = if (obj.get("id")) |v| (if (v == .string) v.string else continue) else continue;
        const title = if (obj.get("title")) |v| (if (v == .string) v.string else continue) else continue;
        const description = if (obj.get("description")) |v| (if (v == .string) v.string else "") else "";
        const status_raw = if (obj.get("status")) |v| (if (v == .string) v.string else "open") else "open";
        const priority: i64 = if (obj.get("priority")) |v| (if (v == .integer) v.integer else 2) else 2;
        const issue_type = if (obj.get("issue_type")) |v| (if (v == .string) v.string else "task") else "task";
        const created_at = if (obj.get("created_at")) |v| (if (v == .string) v.string else "") else "";
        const updated_at = if (obj.get("updated_at")) |v| (if (v == .string) v.string else created_at) else created_at;
        const closed_at = if (obj.get("closed_at")) |v| (if (v == .string) v.string else null) else null;
        const close_reason = if (obj.get("close_reason")) |v| (if (v == .string) v.string else null) else null;

        // Map beads status to dots status
        const status = if (std.mem.eql(u8, status_raw, "in_progress")) "active" else if (std.mem.eql(u8, status_raw, "closed")) "done" else status_raw;

        const issue = Issue{
            .id = id,
            .title = title,
            .description = description,
            .status = status,
            .priority = priority,
            .issue_type = issue_type,
            .assignee = if (obj.get("assignee")) |v| (if (v == .string) v.string else null) else null,
            .created_at = created_at,
            .updated_at = updated_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .after = null,
            .parent = null,
        };

        storage.createIssue(issue) catch continue;

        // Handle dependencies (only if it's a valid array)
        if (obj.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                for (deps_val.array.items) |dep| {
                    if (dep != .object) continue;
                    const dep_obj = dep.object;
                    const depends_on_id = if (dep_obj.get("depends_on_id")) |v| (if (v == .string) v.string else continue) else continue;
                    const dep_type = if (dep_obj.get("type")) |v| (if (v == .string) v.string else "blocks") else "blocks";
                    storage.addDependency(id, depends_on_id, dep_type, created_at) catch continue;
                }
            }
        }

        count += 1;
    }

    return count;
}
