const std = @import("std");
const store = @import("storage/store.zig");
const time = @import("time.zig");
const todo = @import("todo.zig");

pub const SessionOptions = store.SessionOptions;

pub const StartError = error{
    InvalidSessionName,
    SessionAlreadyActive,
    SessionNameExists,
};

pub const SessionError = error{
    NoActiveSession,
    EmptyTodoDescription,
    InvalidTodoIndex,
    TodoAlreadyDone,
    CorruptSessionState,
};

const SessionMeta = struct {
    name: []const u8,
    created_at: []const u8,
    status: []const u8,
    ended_at: ?[]const u8 = null,
};

pub const TodoDoneResult = struct {
    description: []u8,
    elapsed_since_start: []u8,

    pub fn deinit(self: TodoDoneResult, gpa: std.mem.Allocator) void {
        gpa.free(self.description);
        gpa.free(self.elapsed_since_start);
    }
};

pub const EndResult = struct {
    name: []u8,
    recovered_corruption: bool,

    pub fn deinit(self: EndResult, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

pub const Status = struct {
    name: []u8,
    created_at: []u8,
    state: []u8,
    elapsed: []u8,
    since_last_done: ?[]u8,
    todos: []u8,
    warning: ?[]u8,

    pub fn deinit(self: Status, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.created_at);
        gpa.free(self.state);
        gpa.free(self.elapsed);
        if (self.since_last_done) |value| gpa.free(value);
        gpa.free(self.todos);
        if (self.warning) |value| gpa.free(value);
    }
};

pub fn start(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    name: []const u8,
    io: std.Io,
) !void {
    const created_at = try time.nowIso8601Utc(gpa, io);
    defer gpa.free(created_at);

    try startAt(gpa, options, name, created_at, io);
}

pub fn todoAdd(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    description: []const u8,
    io: std.Io,
) !void {
    const trimmed = std.mem.trim(u8, description, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyTodoDescription;

    const s = store.SessionStore.init(gpa, io, options);
    const name = try s.currentSessionName() orelse return error.NoActiveSession;
    defer gpa.free(name);

    const todos_text = s.readTodos(name) catch |err| switch (err) {
        error.FileNotFound => return error.CorruptSessionState,
        else => return err,
    };
    defer gpa.free(todos_text);

    var items = try todo.parseList(gpa, todos_text);
    defer todo.freeList(gpa, items);

    const next = try todo.Item.open(gpa, trimmed);
    items = try appendTodoItem(gpa, items, next);

    const updated = try todo.formatList(gpa, items);
    defer gpa.free(updated);
    try s.writeTodos(name, updated);

    const now = try time.nowIso8601Utc(gpa, io);
    defer gpa.free(now);

    const log_line = try std.fmt.allocPrint(gpa, "[{s}] todo added: {s}\n", .{ now, trimmed });
    defer gpa.free(log_line);
    try s.appendLog(name, log_line);
}

pub fn todoDone(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    index: usize,
    io: std.Io,
) !TodoDoneResult {
    const now = try time.nowIso8601Utc(gpa, io);
    defer gpa.free(now);

    return try todoDoneAt(gpa, options, index, now, io);
}

pub fn end(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    io: std.Io,
) !EndResult {
    const now = try time.nowIso8601Utc(gpa, io);
    defer gpa.free(now);

    return try endAt(gpa, options, now, io);
}

pub fn currentStatus(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    io: std.Io,
) !?Status {
    const now = try time.nowIso8601Utc(gpa, io);
    defer gpa.free(now);

    return try currentStatusAt(gpa, options, now, io);
}

pub fn currentSessionName(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    io: std.Io,
) !?[]u8 {
    return store.SessionStore.init(gpa, io, options).currentSessionName();
}

fn startAt(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    name: []const u8,
    created_at: []const u8,
    io: std.Io,
) !void {
    try validateSessionName(name);

    const s = store.SessionStore.init(gpa, io, options);
    try s.ensureBaseDirs();

    if (try s.currentSessionName() != null) {
        return error.SessionAlreadyActive;
    }
    if (try s.sessionExists(name)) {
        return error.SessionNameExists;
    }

    const meta = SessionMeta{
        .name = name,
        .created_at = created_at,
        .status = "active",
    };
    const meta_contents = try formatMeta(gpa, meta);
    defer gpa.free(meta_contents);

    const log_contents = try std.fmt.allocPrint(
        gpa,
        "[{s}] session started: {s}\n",
        .{ created_at, name },
    );
    defer gpa.free(log_contents);

    try s.createSession(name, meta_contents, log_contents);
    try s.setCurrent(name);
}

fn todoDoneAt(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    index: usize,
    now_iso: []const u8,
    io: std.Io,
) !TodoDoneResult {
    if (index == 0) return error.InvalidTodoIndex;

    const s = store.SessionStore.init(gpa, io, options);
    const name = try s.currentSessionName() orelse return error.NoActiveSession;
    defer gpa.free(name);

    const meta_text = s.readMeta(name) catch |err| switch (err) {
        error.FileNotFound => return error.CorruptSessionState,
        else => return err,
    };
    defer gpa.free(meta_text);

    const meta = try parseMeta(meta_text);
    const created_at = meta.created_at orelse return error.CorruptSessionState;
    const started_seconds = time.parseIso8601Utc(created_at) catch return error.CorruptSessionState;
    const now_seconds = try time.parseIso8601Utc(now_iso);
    const elapsed_seconds = if (now_seconds >= started_seconds)
        @as(u64, @intCast(now_seconds - started_seconds))
    else
        0;

    const todos_text = s.readTodos(name) catch |err| switch (err) {
        error.FileNotFound => return error.CorruptSessionState,
        else => return err,
    };
    defer gpa.free(todos_text);

    var items = try todo.parseList(gpa, todos_text);
    defer todo.freeList(gpa, items);

    if (index > items.len) return error.InvalidTodoIndex;

    var item = &items[index - 1];
    if (item.state == .done) return error.TodoAlreadyDone;

    item.state = .done;
    item.done_at = try gpa.dupe(u8, now_iso);
    item.elapsed_seconds = elapsed_seconds;

    const updated = try todo.formatList(gpa, items);
    defer gpa.free(updated);
    try s.writeTodos(name, updated);

    const elapsed = try time.formatDurationHuman(gpa, elapsed_seconds);
    errdefer gpa.free(elapsed);

    const log_line = try std.fmt.allocPrint(
        gpa,
        "[{s}] todo completed (#{d}) after {s}: {s}\n",
        .{ now_iso, index, elapsed, item.description },
    );
    defer gpa.free(log_line);
    try s.appendLog(name, log_line);

    return .{
        .description = try gpa.dupe(u8, item.description),
        .elapsed_since_start = elapsed,
    };
}

fn endAt(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    now_iso: []const u8,
    io: std.Io,
) !EndResult {
    const s = store.SessionStore.init(gpa, io, options);
    const name = try s.currentSessionName() orelse return error.NoActiveSession;
    errdefer gpa.free(name);

    try s.clearCurrent();

    var recovered_corruption = false;

    const meta_text = blk: {
        const loaded = s.readMeta(name) catch |err| switch (err) {
            error.FileNotFound => {
                recovered_corruption = true;
                break :blk try std.fmt.allocPrint(
                    gpa,
                    "name: {s}\nstatus: active\n",
                    .{name},
                );
            },
            else => return err,
        };
        break :blk loaded;
    };
    defer gpa.free(meta_text);

    const parsed_meta = try parseMeta(meta_text);
    const meta = SessionMeta{
        .name = parsed_meta.name orelse name,
        .created_at = parsed_meta.created_at orelse "unknown",
        .status = "ended",
        .ended_at = now_iso,
    };
    if (parsed_meta.name == null or parsed_meta.created_at == null or parsed_meta.status == null) {
        recovered_corruption = true;
    }

    const updated_meta = try formatMeta(gpa, meta);
    defer gpa.free(updated_meta);
    try s.writeMeta(name, updated_meta);

    const log_line = try std.fmt.allocPrint(
        gpa,
        "[{s}] session ended: {s}\n",
        .{ now_iso, name },
    );
    defer gpa.free(log_line);
    try s.appendLog(name, log_line);

    return .{
        .name = name,
        .recovered_corruption = recovered_corruption,
    };
}

fn currentStatusAt(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    now_iso: []const u8,
    io: std.Io,
) !?Status {
    const s = store.SessionStore.init(gpa, io, options);
    const name = try s.currentSessionName() orelse return null;
    errdefer gpa.free(name);

    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(gpa);

    const meta_text = s.readMeta(name) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try appendWarning(gpa, &warnings, "missing meta.txt");
            break :blk try std.fmt.allocPrint(gpa, "name: {s}\nstatus: active\n", .{name});
        },
        else => return err,
    };
    defer gpa.free(meta_text);

    const parsed_meta = try parseMeta(meta_text);
    if (parsed_meta.name == null) try appendWarning(gpa, &warnings, "meta.txt missing name");
    if (parsed_meta.created_at == null) try appendWarning(gpa, &warnings, "meta.txt missing created_at");
    if (parsed_meta.status == null) try appendWarning(gpa, &warnings, "meta.txt missing status");

    const todos_text = s.readTodos(name) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try appendWarning(gpa, &warnings, "missing todos.txt");
            break :blk try gpa.dupe(u8, "");
        },
        else => return err,
    };
    defer gpa.free(todos_text);

    const items = try todo.parseList(gpa, todos_text);
    defer todo.freeList(gpa, items);

    const created_at = parsed_meta.created_at orelse "unknown";
    const now_seconds = time.parseIso8601Utc(now_iso) catch 0;
    const started_seconds_opt = time.parseIso8601Utc(created_at) catch null;
    const elapsed = if (started_seconds_opt) |started_seconds|
        try time.formatDurationHuman(gpa, if (now_seconds >= started_seconds)
            @as(u64, @intCast(now_seconds - started_seconds))
        else
            0)
    else
        try gpa.dupe(u8, "unknown");
    errdefer gpa.free(elapsed);

    const latest_done_seconds = latestDoneSeconds(items);
    const since_last_done = if (latest_done_seconds) |done_seconds|
        try time.formatDurationHuman(gpa, if (now_seconds >= done_seconds)
            @as(u64, @intCast(now_seconds - done_seconds))
        else
            0)
    else
        null;
    errdefer if (since_last_done) |value| gpa.free(value);

    const rendered_todos = try todo.renderList(gpa, items);
    errdefer gpa.free(rendered_todos);

    const is_corrupt = warnings.items.len > 0 or
        parsed_meta.status == null or
        !std.mem.eql(u8, parsed_meta.status.?, "active");

    return .{
        .name = name,
        .created_at = try gpa.dupe(u8, created_at),
        .state = try gpa.dupe(u8, if (is_corrupt) "corrupt" else "active"),
        .elapsed = elapsed,
        .since_last_done = since_last_done,
        .todos = rendered_todos,
        .warning = if (warnings.items.len == 0) null else try gpa.dupe(u8, warnings.items),
    };
}

const ParsedMeta = struct {
    name: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    status: ?[]const u8 = null,
    ended_at: ?[]const u8 = null,
};

fn parseMeta(contents: []const u8) !ParsedMeta {
    var meta: ParsedMeta = .{};

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "name: ")) {
            meta.name = line["name: ".len..];
        } else if (std.mem.startsWith(u8, line, "created_at: ")) {
            meta.created_at = line["created_at: ".len..];
        } else if (std.mem.startsWith(u8, line, "status: ")) {
            meta.status = line["status: ".len..];
        } else if (std.mem.startsWith(u8, line, "ended_at: ")) {
            meta.ended_at = line["ended_at: ".len..];
        }
    }

    return meta;
}

fn formatMeta(gpa: std.mem.Allocator, meta: SessionMeta) ![]u8 {
    if (meta.ended_at) |ended_at| {
        return std.fmt.allocPrint(
            gpa,
            "name: {s}\ncreated_at: {s}\nstatus: {s}\nended_at: {s}\n",
            .{ meta.name, meta.created_at, meta.status, ended_at },
        );
    }

    return std.fmt.allocPrint(
        gpa,
        "name: {s}\ncreated_at: {s}\nstatus: {s}\n",
        .{ meta.name, meta.created_at, meta.status },
    );
}

fn appendTodoItem(
    gpa: std.mem.Allocator,
    items: []todo.Item,
    next: todo.Item,
) ![]todo.Item {
    var out = try gpa.alloc(todo.Item, items.len + 1);
    for (items, 0..) |item, i| out[i] = item;
    out[items.len] = next;
    gpa.free(items);
    return out;
}

fn latestDoneSeconds(items: []const todo.Item) ?i64 {
    var latest: ?i64 = null;
    for (items) |item| {
        const done_at = item.done_at orelse continue;
        const seconds = time.parseIso8601Utc(done_at) catch continue;
        latest = if (latest) |current|
            @max(current, seconds)
        else
            seconds;
    }
    return latest;
}

fn appendWarning(
    gpa: std.mem.Allocator,
    warnings: *std.ArrayList(u8),
    text: []const u8,
) !void {
    if (warnings.items.len != 0) {
        try warnings.appendSlice(gpa, "; ");
    }
    try warnings.appendSlice(gpa, text);
}

fn validateSessionName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidSessionName;
    if (std.mem.indexOfScalar(u8, name, '/')) |_| return error.InvalidSessionName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.InvalidSessionName;
    }
    if (std.mem.trim(u8, name, " \t\r\n").len != name.len) {
        return error.InvalidSessionName;
    }

    for (name) |c| {
        switch (c) {
            0...31 => return error.InvalidSessionName,
            '\\' => return error.InvalidSessionName,
            ':' => return error.InvalidSessionName,
            '*' => return error.InvalidSessionName,
            '?' => return error.InvalidSessionName,
            '"' => return error.InvalidSessionName,
            '<' => return error.InvalidSessionName,
            '>' => return error.InvalidSessionName,
            '|' => return error.InvalidSessionName,
            else => {},
        }
    }
}

test "status includes elapsed values and todo completion timing" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options = try testOptions(gpa, tmp.sub_path[0..]);
    defer options.deinit(gpa);

    try startAt(gpa, options, "alpha", "2026-03-13T10:00:00Z", std.testing.io);
    try todoAdd(gpa, options, "first task", std.testing.io);

    var result = try todoDoneAt(gpa, options, 1, "2026-03-13T11:02:03Z", std.testing.io);
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("first task", result.description);
    try std.testing.expectEqualStrings("1h 2m 3s", result.elapsed_since_start);

    const status = (try currentStatusAt(gpa, options, "2026-03-14T12:02:04Z", std.testing.io)).?;
    defer status.deinit(gpa);

    try std.testing.expectEqualStrings("active", status.state);
    try std.testing.expectEqualStrings("1d 2h 2m 4s", status.elapsed);
    try std.testing.expect(status.since_last_done != null);
    try std.testing.expectEqualStrings("1d 1h 0m 1s", status.since_last_done.?);
    try std.testing.expect(std.mem.containsAtLeast(u8, status.todos, 1, "1. [x] first task (done after 1h 2m 3s)"));
}

test "todo cannot be completed twice" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options = try testOptions(gpa, tmp.sub_path[0..]);
    defer options.deinit(gpa);

    try startAt(gpa, options, "alpha", "2026-03-13T10:00:00Z", std.testing.io);
    try todoAdd(gpa, options, "first task", std.testing.io);
    var first = try todoDoneAt(gpa, options, 1, "2026-03-13T10:05:00Z", std.testing.io);
    defer first.deinit(gpa);

    try std.testing.expectError(
        error.TodoAlreadyDone,
        todoDoneAt(gpa, options, 1, "2026-03-13T10:06:00Z", std.testing.io),
    );
}

test "end clears active marker even when session files are corrupt" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options = try testOptions(gpa, tmp.sub_path[0..]);
    defer options.deinit(gpa);

    try startAt(gpa, options, "alpha", "2026-03-13T10:00:00Z", std.testing.io);

    const s = store.SessionStore.init(gpa, std.testing.io, options);
    try s.deleteMetaForTest("alpha");

    const status = (try currentStatusAt(gpa, options, "2026-03-13T10:10:00Z", std.testing.io)).?;
    defer status.deinit(gpa);
    try std.testing.expectEqualStrings("corrupt", status.state);
    try std.testing.expect(status.warning != null);

    var ended = try endAt(gpa, options, "2026-03-13T11:00:00Z", std.testing.io);
    defer ended.deinit(gpa);
    try std.testing.expect(ended.recovered_corruption);
    try std.testing.expect((try currentSessionName(gpa, options, std.testing.io)) == null);
}

test "cannot reuse existing session name" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options = try testOptions(gpa, tmp.sub_path[0..]);
    defer options.deinit(gpa);

    try startAt(gpa, options, "alpha", "2026-03-13T10:00:00Z", std.testing.io);
    var ended = try endAt(gpa, options, "2026-03-13T11:00:00Z", std.testing.io);
    defer ended.deinit(gpa);

    try std.testing.expectError(
        error.SessionNameExists,
        startAt(gpa, options, "alpha", "2026-03-13T12:00:00Z", std.testing.io),
    );
}

fn testOptions(gpa: std.mem.Allocator, tmp_sub_path: []const u8) !SessionOptions {
    return .{
        .state_home = try std.fmt.allocPrint(
            gpa,
            ".zig-cache/tmp/{s}/state",
            .{tmp_sub_path},
        ),
    };
}
