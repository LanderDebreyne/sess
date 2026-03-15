const std = @import("std");
const session = @import("session.zig");
const store = @import("storage/store.zig");
const time = @import("time.zig");
const todo = @import("todo.zig");

const embedded_html = @embedFile("overlay.html");

pub const ServeOptions = struct {
    port: u16 = 47831,
    rotate_seconds: u16 = 15,
    notes_scroll_seconds: u16 = 22,
    timeline_scroll_seconds: u16 = 18,
};

const UiConfig = struct {
    rotate_seconds: u16,
    notes_scroll_seconds: u16,
    timeline_scroll_seconds: u16,
};

const OpenTodo = struct {
    index: usize,
    description: []const u8,
};

const OverlayTodo = struct {
    index: usize,
    state: []const u8,
    description: []const u8,
    done_at: ?[]const u8 = null,
    elapsed: ?[]const u8 = null,
    done_in: ?[]const u8 = null,
};

const OverlayState = struct {
    session_name: ?[]const u8,
    session_state: []const u8,
    created_at: ?[]const u8,
    elapsed: []const u8,
    notes_markdown: []const u8,
    open_todos: []const OpenTodo,
    todos: []const OverlayTodo,
    done_count: usize,
    warning: ?[]const u8,
    ui: UiConfig,
};

fn deinitState(gpa: std.mem.Allocator, state: OverlayState) void {
    if (state.session_name) |value| gpa.free(value);
    gpa.free(state.session_state);
    if (state.created_at) |value| gpa.free(value);
    gpa.free(state.elapsed);
    gpa.free(state.notes_markdown);
    if (state.warning) |value| gpa.free(value);

    for (state.open_todos) |item| {
        gpa.free(item.description);
    }
    if (state.open_todos.len != 0) gpa.free(state.open_todos);

    for (state.todos) |item| {
        gpa.free(item.description);
        if (item.done_at) |value| gpa.free(value);
        if (item.elapsed) |value| gpa.free(value);
        if (item.done_in) |value| gpa.free(value);
    }
    if (state.todos.len != 0) gpa.free(state.todos);
}

const ParsedMeta = struct {
    name: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub fn serve(
    gpa: std.mem.Allocator,
    sess_options: session.SessionOptions,
    options: ServeOptions,
    io: std.Io,
    w: *std.Io.Writer,
) !void {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(options.port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try w.print("overlay listening at http://127.0.0.1:{d}/\n", .{server.socket.address.getPort()});
    try w.flush();

    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();

        handleConnection(arena_state.allocator(), sess_options, options, io, &stream) catch |err| {
            sendResponse(
                io,
                &stream,
                "500 Internal Server Error",
                "text/plain; charset=utf-8",
                "internal server error\n",
            ) catch {};
            std.log.err("overlay request failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    gpa: std.mem.Allocator,
    sess_options: session.SessionOptions,
    options: ServeOptions,
    io: std.Io,
    stream: *std.Io.net.Stream,
) !void {
    const request = try readRequestLine(io, stream);

    if (!std.mem.eql(u8, request.method, "GET")) {
        try sendResponse(io, stream, "405 Method Not Allowed", "text/plain; charset=utf-8", "method not allowed\n");
        return;
    }

    if (std.mem.eql(u8, request.path, "/")) {
        try sendResponse(io, stream, "200 OK", "text/html; charset=utf-8", embedded_html);
        return;
    }

    if (std.mem.eql(u8, request.path, "/health")) {
        try sendResponse(io, stream, "200 OK", "text/plain; charset=utf-8", "ok\n");
        return;
    }

    if (std.mem.eql(u8, request.path, "/api/state")) {
        const state = try buildState(gpa, sess_options, options, io);
        const body = try std.fmt.allocPrint(gpa, "{f}\n", .{std.json.fmt(state, .{})});
        try sendResponse(io, stream, "200 OK", "application/json; charset=utf-8", body);
        return;
    }

    try sendResponse(io, stream, "404 Not Found", "text/plain; charset=utf-8", "not found\n");
}

fn readRequestLine(io: std.Io, stream: *std.Io.net.Stream) !struct { method: []const u8, path: []const u8 } {
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &buffer);

    const line = try reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, line, "\r");

    while (true) {
        const header_line = try reader.interface.takeDelimiterExclusive('\n');
        if (std.mem.trim(u8, header_line, "\r").len == 0) break;
    }

    var parts = std.mem.splitScalar(u8, trimmed, ' ');
    const method = parts.next() orelse return error.InvalidHttpRequest;
    const target = parts.next() orelse return error.InvalidHttpRequest;
    _ = parts.next() orelse return error.InvalidHttpRequest;

    return .{
        .method = method,
        .path = stripQuery(target),
    };
}

fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |index| return target[0..index];
    return target;
}

fn sendResponse(
    io: std.Io,
    stream: *std.Io.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var writer_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.print(
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

fn buildState(
    gpa: std.mem.Allocator,
    sess_options: session.SessionOptions,
    options: ServeOptions,
    io: std.Io,
) !OverlayState {
    const now_iso = try time.nowIso8601Utc(gpa, io);
    defer gpa.free(now_iso);

    const s = store.SessionStore.init(gpa, io, sess_options);
    const current_name = try s.currentSessionName() orelse return .{
        .session_name = null,
        .session_state = try gpa.dupe(u8, "inactive"),
        .created_at = null,
        .elapsed = try gpa.dupe(u8, "0s"),
        .notes_markdown = try gpa.dupe(u8, ""),
        .open_todos = &.{},
        .todos = &.{},
        .done_count = 0,
        .warning = null,
        .ui = uiConfig(options),
    };
    defer gpa.free(current_name);

    var warnings: std.ArrayList(u8) = .empty;
    defer warnings.deinit(gpa);

    const meta_text = s.readMeta(current_name) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try appendWarning(gpa, &warnings, "missing meta.txt");
            break :blk try std.fmt.allocPrint(gpa, "name: {s}\nstatus: active\n", .{current_name});
        },
        else => return err,
    };
    defer gpa.free(meta_text);

    const meta = parseMeta(meta_text);

    const todos_text = s.readTodos(current_name) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try appendWarning(gpa, &warnings, "missing todos.txt");
            break :blk try gpa.dupe(u8, "");
        },
        else => return err,
    };
    defer gpa.free(todos_text);

    const items = try todo.parseList(gpa, todos_text);
    defer todo.freeList(gpa, items);
    const open_todos = try buildOpenTodos(gpa, items);
    const todos = try buildTodos(gpa, items);
    const done_count = countDone(items);

    const notes_markdown = s.readNotes(current_name) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try appendWarning(gpa, &warnings, "missing notes.md");
            break :blk try gpa.dupe(u8, "");
        },
        else => return err,
    };

    if (meta.created_at == null) try appendWarning(gpa, &warnings, "meta.txt missing created_at");
    if (meta.status == null) try appendWarning(gpa, &warnings, "meta.txt missing status");

    const created_at_source = meta.created_at orelse "unknown";
    const created_at = if (meta.created_at) |value|
        time.formatIso8601UtcLocal(gpa, value) catch try gpa.dupe(u8, value)
    else
        try gpa.dupe(u8, "unknown");

    const elapsed = blk: {
        const now_seconds = time.parseIso8601Utc(now_iso) catch break :blk try gpa.dupe(u8, "unknown");
        const started_seconds = time.parseIso8601Utc(created_at_source) catch break :blk try gpa.dupe(u8, "unknown");
        break :blk try time.formatDurationHuman(gpa, if (now_seconds >= started_seconds)
            @as(u64, @intCast(now_seconds - started_seconds))
        else
            0);
    };

    const state = if (warnings.items.len > 0 or meta.status == null or !std.mem.eql(u8, meta.status.?, "active"))
        "corrupt"
    else
        "active";

    return .{
        .session_name = try gpa.dupe(u8, meta.name orelse current_name),
        .session_state = try gpa.dupe(u8, state),
        .created_at = created_at,
        .elapsed = elapsed,
        .notes_markdown = notes_markdown,
        .open_todos = open_todos,
        .todos = todos,
        .done_count = done_count,
        .warning = if (warnings.items.len == 0) null else try gpa.dupe(u8, warnings.items),
        .ui = uiConfig(options),
    };
}

fn uiConfig(options: ServeOptions) UiConfig {
    return .{
        .rotate_seconds = options.rotate_seconds,
        .notes_scroll_seconds = options.notes_scroll_seconds,
        .timeline_scroll_seconds = options.timeline_scroll_seconds,
    };
}

fn parseMeta(contents: []const u8) ParsedMeta {
    var meta: ParsedMeta = .{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "name: ")) {
            meta.name = line["name: ".len..];
        } else if (std.mem.startsWith(u8, line, "created_at: ")) {
            meta.created_at = line["created_at: ".len..];
        } else if (std.mem.startsWith(u8, line, "status: ")) {
            meta.status = line["status: ".len..];
        }
    }
    return meta;
}

fn buildOpenTodos(gpa: std.mem.Allocator, items: []const todo.Item) ![]OpenTodo {
    var out: std.ArrayList(OpenTodo) = .empty;
    defer out.deinit(gpa);

    for (items, 0..) |item, index| {
        if (item.state != .open) continue;
        try out.append(gpa, .{
            .index = index + 1,
            .description = try gpa.dupe(u8, item.description),
        });
    }

    return out.toOwnedSlice(gpa);
}

fn countDone(items: []const todo.Item) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.state == .done) count += 1;
    }
    return count;
}

fn buildTodos(gpa: std.mem.Allocator, items: []const todo.Item) ![]OverlayTodo {
    var out: std.ArrayList(OverlayTodo) = .empty;
    defer out.deinit(gpa);

    for (items, 0..) |item, index| {
        switch (item.state) {
            .open => try out.append(gpa, .{
                .index = index + 1,
                .state = "open",
                .description = try gpa.dupe(u8, item.description),
            }),
            .done => {
                const done_at = if (item.done_at) |value|
                    time.formatIso8601UtcLocal(gpa, value) catch try gpa.dupe(u8, value)
                else
                    null;
                errdefer if (done_at) |value| gpa.free(value);

                const elapsed = if (item.elapsed_seconds) |seconds|
                    try time.formatDurationHuman(gpa, seconds)
                else
                    null;
                errdefer if (elapsed) |value| gpa.free(value);

                const done_in = if (item.done_at) |value|
                    try formatElapsedSincePreviousDone(gpa, items, value, item.elapsed_seconds)
                else
                    null;
                errdefer if (done_in) |value| gpa.free(value);

                try out.append(gpa, .{
                    .index = index + 1,
                    .state = "done",
                    .description = try gpa.dupe(u8, item.description),
                    .done_at = done_at,
                    .elapsed = elapsed,
                    .done_in = done_in,
                });
            },
        }
    }

    return out.toOwnedSlice(gpa);
}

fn formatElapsedSincePreviousDone(
    gpa: std.mem.Allocator,
    items: []const todo.Item,
    done_at: []const u8,
    elapsed_since_start_seconds: ?u64,
) ![]u8 {
    const current_done_seconds = time.parseIso8601Utc(done_at) catch return gpa.dupe(u8, "unknown");

    var previous_done_seconds: ?i64 = null;
    for (items) |item| {
        const previous_done_at = item.done_at orelse continue;
        if (std.mem.eql(u8, previous_done_at, done_at)) continue;

        const parsed = time.parseIso8601Utc(previous_done_at) catch continue;
        if (parsed >= current_done_seconds) continue;

        previous_done_seconds = if (previous_done_seconds) |current|
            @max(current, parsed)
        else
            parsed;
    }

    const elapsed = if (previous_done_seconds) |previous|
        @as(u64, @intCast(current_done_seconds - previous))
    else
        elapsed_since_start_seconds orelse 0;

    return time.formatDurationHuman(gpa, elapsed);
}

fn appendWarning(
    gpa: std.mem.Allocator,
    warnings: *std.ArrayList(u8),
    text: []const u8,
) !void {
    if (warnings.items.len != 0) try warnings.appendSlice(gpa, "; ");
    try warnings.appendSlice(gpa, text);
}

test "builds overlay todos from todo items" {
    const gpa = std.testing.allocator;
    var items = try gpa.alloc(todo.Item, 2);
    defer todo.freeList(gpa, items);

    items[0] = try todo.Item.open(gpa, "keep overlay scroll stable");
    items[1] = .{
        .state = .done,
        .description = try gpa.dupe(u8, "replace todo timeline"),
        .done_at = try gpa.dupe(u8, "2026-03-15T09:02:00Z"),
        .elapsed_seconds = 120,
    };

    const todos = try buildTodos(gpa, items);
    defer {
        for (todos) |item| {
            gpa.free(item.description);
            if (item.done_at) |value| gpa.free(value);
            if (item.elapsed) |value| gpa.free(value);
            if (item.done_in) |value| gpa.free(value);
        }
        gpa.free(todos);
    }

    try std.testing.expectEqual(@as(usize, 2), todos.len);
    try std.testing.expectEqualStrings("open", todos[0].state);
    try std.testing.expectEqualStrings("keep overlay scroll stable", todos[0].description);
    try std.testing.expectEqualStrings("done", todos[1].state);
    try std.testing.expectEqualStrings("replace todo timeline", todos[1].description);
    try std.testing.expect(todos[1].done_at != null);
    try std.testing.expectEqualStrings("2m 0s", todos[1].elapsed.?);
    try std.testing.expectEqualStrings("2m 0s", todos[1].done_in.?);
}

test "buildState returns empty payload without active session" {
    const gpa = std.testing.allocator;
    const options = try testSessionOptions(gpa, "overlay-empty");
    defer options.deinit(gpa);

    const state = try buildState(gpa, options, .{}, std.testing.io);
    defer deinitState(gpa, state);
    try std.testing.expect(state.session_name == null);
    try std.testing.expectEqualStrings("inactive", state.session_state);
    try std.testing.expectEqual(@as(usize, 0), state.open_todos.len);
    try std.testing.expectEqual(@as(usize, 0), state.todos.len);
}

fn testSessionOptions(gpa: std.mem.Allocator, tmp_sub_path: []const u8) !session.SessionOptions {
    const state_home = try std.fs.path.join(gpa, &.{ "/tmp", "sess-tests", tmp_sub_path });
    return .{ .state_home = state_home };
}
