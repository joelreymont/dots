const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sqlite3.h");
});

// Use SQLITE_STATIC (null) since we always pass string slices that outlive statement execution
const max_jsonl_bytes = 100 * 1024 * 1024;

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

    pub fn changes(self: Self) c_int {
        return c.sqlite3_changes(self.handle);
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
        const safe = if (text.len == 0) "" else text;
        const rc = c.sqlite3_bind_text(self.handle, idx, safe.ptr, @intCast(safe.len), null);
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

pub const ChildIssue = struct {
    issue: Issue,
    blocked: bool,

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
    get_dep_type_stmt: Statement,
    mark_dirty_stmt: Statement,
    clear_dirty_stmt: Statement,
    get_dirty_stmt: Statement,
    get_ready_stmt: Statement,
    get_children_stmt: Statement,
    get_root_stmt: Statement,
    search_stmt: Statement,
    get_config_stmt: Statement,
    set_config_stmt: Statement,
    exists_stmt: Statement,

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

        var list_stmt = try db.prepare("SELECT id, title, description, status, priority, issue_type, assignee, created_at, updated_at, closed_at, close_reason FROM issues WHERE (?1 IS NULL OR status = ?1) ORDER BY priority, created_at");
        errdefer list_stmt.finalize();

        var add_dep_stmt = try db.prepare(
            "INSERT OR REPLACE INTO dependencies (issue_id, depends_on_id, type, created_at, created_by) VALUES (?1, ?2, ?3, ?4, ?5)",
        );
        errdefer add_dep_stmt.finalize();

        var get_dep_type_stmt = try db.prepare(
            "SELECT type FROM dependencies WHERE issue_id = ?1 AND depends_on_id = ?2",
        );
        errdefer get_dep_type_stmt.finalize();

        var mark_dirty_stmt = try db.prepare(
            "INSERT OR REPLACE INTO dirty_issues (issue_id, marked_at) VALUES (?1, ?2)",
        );
        errdefer mark_dirty_stmt.finalize();

        var clear_dirty_stmt = try db.prepare("DELETE FROM dirty_issues WHERE issue_id = ?1");
        errdefer clear_dirty_stmt.finalize();

        var get_dirty_stmt = try db.prepare("SELECT issue_id FROM dirty_issues ORDER BY marked_at");
        errdefer get_dirty_stmt.finalize();

        var get_ready_stmt = try db.prepare(
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
        );
        errdefer get_ready_stmt.finalize();

        var get_children_stmt = try db.prepare(
            \\SELECT i.id, i.title, i.description, i.status, i.priority, i.issue_type,
            \\       i.assignee, i.created_at, i.updated_at, i.closed_at, i.close_reason,
            \\       EXISTS (
            \\         SELECT 1 FROM dependencies d2
            \\         JOIN issues blocker ON d2.depends_on_id = blocker.id
            \\         WHERE d2.issue_id = i.id
            \\           AND d2.type = 'blocks'
            \\           AND blocker.status IN ('open', 'active', 'in_progress')
            \\       ) AS is_blocked
            \\FROM issues i
            \\JOIN dependencies d ON i.id = d.issue_id
            \\WHERE d.depends_on_id = ?1 AND d.type = 'parent-child'
            \\ORDER BY i.priority, i.created_at
        );
        errdefer get_children_stmt.finalize();

        var get_root_stmt = try db.prepare(
            \\SELECT i.id, i.title, i.description, i.status, i.priority, i.issue_type,
            \\       i.assignee, i.created_at, i.updated_at, i.closed_at, i.close_reason
            \\FROM issues i
            \\WHERE i.status != 'closed'
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM dependencies d
            \\    WHERE d.issue_id = i.id AND d.type = 'parent-child'
            \\  )
            \\ORDER BY i.priority, i.created_at
        );
        errdefer get_root_stmt.finalize();

        var search_stmt = try db.prepare(
            \\SELECT id, title, description, status, priority, issue_type,
            \\       assignee, created_at, updated_at, closed_at, close_reason
            \\FROM issues
            \\WHERE title LIKE '%' || ?1 || '%' OR description LIKE '%' || ?1 || '%'
            \\ORDER BY priority, created_at
        );
        errdefer search_stmt.finalize();

        var get_config_stmt = try db.prepare("SELECT value FROM config WHERE key = ?1");
        errdefer get_config_stmt.finalize();

        var set_config_stmt = try db.prepare("INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)");
        errdefer set_config_stmt.finalize();

        var exists_stmt = try db.prepare("SELECT 1 FROM issues WHERE id = ?1");
        errdefer exists_stmt.finalize();

        return Self{
            .db = db,
            .allocator = allocator,
            .insert_stmt = insert_stmt,
            .update_status_stmt = update_status_stmt,
            .delete_stmt = delete_stmt,
            .get_by_id_stmt = get_by_id_stmt,
            .list_stmt = list_stmt,
            .add_dep_stmt = add_dep_stmt,
            .get_dep_type_stmt = get_dep_type_stmt,
            .mark_dirty_stmt = mark_dirty_stmt,
            .clear_dirty_stmt = clear_dirty_stmt,
            .get_dirty_stmt = get_dirty_stmt,
            .get_ready_stmt = get_ready_stmt,
            .get_children_stmt = get_children_stmt,
            .get_root_stmt = get_root_stmt,
            .search_stmt = search_stmt,
            .get_config_stmt = get_config_stmt,
            .set_config_stmt = set_config_stmt,
            .exists_stmt = exists_stmt,
        };
    }

    pub fn close(self: *Self) void {
        self.insert_stmt.finalize();
        self.update_status_stmt.finalize();
        self.delete_stmt.finalize();
        self.get_by_id_stmt.finalize();
        self.list_stmt.finalize();
        self.add_dep_stmt.finalize();
        self.get_dep_type_stmt.finalize();
        self.mark_dirty_stmt.finalize();
        self.clear_dirty_stmt.finalize();
        self.get_dirty_stmt.finalize();
        self.get_ready_stmt.finalize();
        self.get_children_stmt.finalize();
        self.get_root_stmt.finalize();
        self.search_stmt.finalize();
        self.get_config_stmt.finalize();
        self.set_config_stmt.finalize();
        self.exists_stmt.finalize();
        self.db.close();
    }

    pub fn createIssue(self: *Self, issue: Issue) !void {
        try self.db.exec("BEGIN TRANSACTION");
        self.createIssueNoTransaction(issue) catch |err| {
            self.db.exec("ROLLBACK") catch |rollback_err| {
                std.debug.print("rollback failed: {}\n", .{rollback_err});
            };
            return err;
        };
        try self.db.exec("COMMIT");
    }

    pub fn createIssueNoTransaction(self: *Self, issue: Issue) !void {
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

        // Add dependencies (validate targets exist first)
        if (issue.after) |after_id| {
            if (!try self.issueExists(after_id)) return error.DependencyNotFound;
            try self.addDependency(issue.id, after_id, "blocks", issue.created_at);
        }
        if (issue.parent) |parent_id| {
            if (!try self.issueExists(parent_id)) return error.DependencyNotFound;
            try self.addDependency(issue.id, parent_id, "parent-child", issue.created_at);
        }

        try self.markDirty(issue.id, issue.created_at);
    }

    pub fn updateStatus(self: *Self, id: []const u8, status: []const u8, updated_at: []const u8, closed_at: ?[]const u8, reason: ?[]const u8) !void {
        try self.db.exec("BEGIN TRANSACTION");
        self.updateStatusNoTransaction(id, status, updated_at, closed_at, reason) catch |err| {
            self.db.exec("ROLLBACK") catch {};
            return err;
        };
        try self.db.exec("COMMIT");
    }

    pub fn updateStatusNoTransaction(self: *Self, id: []const u8, status: []const u8, updated_at: []const u8, closed_at: ?[]const u8, reason: ?[]const u8) !void {
        if (!try self.issueExists(id)) return error.IssueNotFound;

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
        if (!try self.issueExists(id)) return error.IssueNotFound;

        try self.db.exec("BEGIN TRANSACTION");
        errdefer self.db.exec("ROLLBACK") catch {};

        self.delete_stmt.reset();
        try self.delete_stmt.bindText(1, id);
        _ = try self.delete_stmt.step();

        try self.db.exec("COMMIT");
    }

    pub fn getIssue(self: *Self, id: []const u8) !?Issue {
        self.get_by_id_stmt.reset();
        try self.get_by_id_stmt.bindText(1, id);
        if (try self.get_by_id_stmt.step()) {
            return try self.rowToIssue(&self.get_by_id_stmt);
        }
        return null;
    }

    fn collectIssues(self: *Self, stmt: *Statement) ![]Issue {
        var issues: std.ArrayList(Issue) = .empty;
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        while (try stmt.step()) {
            const issue = try self.rowToIssue(stmt);
            issues.append(self.allocator, issue) catch |err| {
                issue.deinit(self.allocator);
                return err;
            };
        }

        return issues.toOwnedSlice(self.allocator);
    }

    pub fn listIssues(self: *Self, status_filter: ?[]const u8) ![]Issue {
        self.list_stmt.reset();
        if (status_filter) |filter| {
            try self.list_stmt.bindText(1, filter);
        } else {
            try self.list_stmt.bindNull(1);
        }
        return try self.collectIssues(&self.list_stmt);
    }

    pub fn getReadyIssues(self: *Self) ![]Issue {
        self.get_ready_stmt.reset();
        return try self.collectIssues(&self.get_ready_stmt);
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

    fn issueExists(self: *Self, id: []const u8) !bool {
        self.exists_stmt.reset();
        try self.exists_stmt.bindText(1, id);
        return try self.exists_stmt.step();
    }

    pub fn addDependency(self: *Self, issue_id: []const u8, depends_on_id: []const u8, dep_type: []const u8, created_at: []const u8) !void {
        // Check for direct cycle: if depends_on already depends on issue_id
        self.get_dep_type_stmt.reset();
        try self.get_dep_type_stmt.bindText(1, depends_on_id);
        try self.get_dep_type_stmt.bindText(2, issue_id);
        if (try self.get_dep_type_stmt.step()) {
            return error.DependencyCycle;
        }

        // Check if dependency already exists
        self.get_dep_type_stmt.reset();
        try self.get_dep_type_stmt.bindText(1, issue_id);
        try self.get_dep_type_stmt.bindText(2, depends_on_id);
        if (try self.get_dep_type_stmt.step()) {
            const existing = self.get_dep_type_stmt.columnText(0) orelse "";
            if (!std.mem.eql(u8, existing, dep_type)) return error.DependencyConflict;
            return;
        }

        self.add_dep_stmt.reset();
        try self.add_dep_stmt.bindText(1, issue_id);
        try self.add_dep_stmt.bindText(2, depends_on_id);
        try self.add_dep_stmt.bindText(3, dep_type);
        try self.add_dep_stmt.bindText(4, created_at);
        try self.add_dep_stmt.bindText(5, "");
        _ = try self.add_dep_stmt.step();
    }

    pub fn markDirty(self: *Self, issue_id: []const u8, marked_at: []const u8) !void {
        self.mark_dirty_stmt.reset();
        try self.mark_dirty_stmt.bindText(1, issue_id);
        try self.mark_dirty_stmt.bindText(2, marked_at);
        _ = try self.mark_dirty_stmt.step();
    }

    pub fn getDirtyIssues(self: *Self) ![][]const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }

        self.get_dirty_stmt.reset();
        while (try self.get_dirty_stmt.step()) {
            if (self.get_dirty_stmt.columnText(0)) |id| {
                const duped = try self.allocator.dupe(u8, id);
                ids.append(self.allocator, duped) catch |err| {
                    self.allocator.free(duped);
                    return err;
                };
            }
        }

        return ids.toOwnedSlice(self.allocator);
    }

    pub fn clearDirty(self: *Self, issue_ids: []const []const u8) !void {
        for (issue_ids) |id| {
            self.clear_dirty_stmt.reset();
            try self.clear_dirty_stmt.bindText(1, id);
            _ = try self.clear_dirty_stmt.step();
        }
    }

    // Get children for tree view
    pub fn getChildren(self: *Self, parent_id: []const u8) ![]ChildIssue {
        var issues: std.ArrayList(ChildIssue) = .empty;
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        self.get_children_stmt.reset();
        try self.get_children_stmt.bindText(1, parent_id);
        while (try self.get_children_stmt.step()) {
            const issue = try self.rowToIssue(&self.get_children_stmt);
            const blocked = self.get_children_stmt.columnInt(11) != 0;
            issues.append(self.allocator, .{ .issue = issue, .blocked = blocked }) catch |err| {
                issue.deinit(self.allocator);
                return err;
            };
        }

        return issues.toOwnedSlice(self.allocator);
    }

    // Get root issues (no parent) for tree view
    pub fn getRootIssues(self: *Self) ![]Issue {
        self.get_root_stmt.reset();
        return try self.collectIssues(&self.get_root_stmt);
    }

    // Search issues
    pub fn searchIssues(self: *Self, query: []const u8) ![]Issue {
        self.search_stmt.reset();
        try self.search_stmt.bindText(1, query);
        return try self.collectIssues(&self.search_stmt);
    }

    // Get config value from config table
    pub fn getConfig(self: *Self, key: []const u8) !?[]const u8 {
        self.get_config_stmt.reset();
        try self.get_config_stmt.bindText(1, key);
        if (try self.get_config_stmt.step()) {
            if (self.get_config_stmt.columnText(0)) |value| {
                return try self.allocator.dupe(u8, value);
            }
        }
        return null;
    }

    // Set config value in config table
    pub fn setConfig(self: *Self, key: []const u8, value: []const u8) !void {
        self.set_config_stmt.reset();
        try self.set_config_stmt.bindText(1, key);
        try self.set_config_stmt.bindText(2, value);
        _ = try self.set_config_stmt.step();
    }
};

fn normalizeJsonlStatus(status_raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, status_raw, "open")) return "open";
    if (std.mem.eql(u8, status_raw, "active") or std.mem.eql(u8, status_raw, "in_progress")) return "active";
    if (std.mem.eql(u8, status_raw, "closed") or std.mem.eql(u8, status_raw, "done")) return "closed";
    return error.InvalidStatus;
}

// Hydrate from beads JSONL
pub fn hydrateFromJsonl(storage: *Storage, allocator: Allocator, jsonl_path: []const u8) !usize {
    const file = std.fs.cwd().openFile(jsonl_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, max_jsonl_bytes);
    defer allocator.free(content);

    var count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;

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
        updated_at: []const u8,
        closed_at: ?[]const u8 = null,
        close_reason: ?[]const u8 = null,
        dependencies: ?[]const JsonlDependency = null,
    };

    while (line_iter.next()) |line| : (line_no += 1) {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(JsonlIssue, allocator, line, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("Invalid JSON at {s}:{d}\n", .{ jsonl_path, line_no + 1 });
            return err;
        };
        defer parsed.deinit();

        const obj = parsed.value;

        // Map beads fields to our schema
        const id = obj.id;
        const title = obj.title;
        const description = obj.description orelse "";
        const status_raw = obj.status;
        const priority: i64 = obj.priority;
        const issue_type = obj.issue_type;
        const created_at = obj.created_at;
        const updated_at = obj.updated_at;
        const closed_at = obj.closed_at;
        const close_reason = obj.close_reason;

        // Map beads status to dots status (in_progress -> active, keep closed as-is)
        const status = normalizeJsonlStatus(status_raw) catch |err| switch (err) {
            error.InvalidStatus => return error.InvalidJsonl,
        };

        const issue = Issue{
            .id = id,
            .title = title,
            .description = description,
            .status = status,
            .priority = priority,
            .issue_type = issue_type,
            .assignee = obj.assignee,
            .created_at = created_at,
            .updated_at = updated_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .after = null,
            .parent = null,
        };

        try storage.createIssue(issue);

        if (obj.dependencies) |deps| {
            for (deps) |dep| {
                const dep_type = dep.type orelse "blocks";
                storage.addDependency(id, dep.depends_on_id, dep_type, created_at) catch |err| switch (err) {
                    error.DependencyConflict => {
                        std.debug.print(
                            "Invalid dependency at {s}:{d} for {s} -> {s}\n",
                            .{ jsonl_path, line_no + 1, id, dep.depends_on_id },
                        );
                        return error.InvalidJsonl;
                    },
                    else => return err,
                };
            }
        }

        count += 1;
    }

    return count;
}
