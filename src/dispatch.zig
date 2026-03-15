const parse = @import("parse.zig");
const std = @import("std");
const session = @import("session.zig");

const SessionConflictAction = enum {
    start,
    @"resume",
    remove,
};

pub fn dispatch(
    gpa: std.mem.Allocator,
    cmd: parse.CommandData,
    w: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    io: std.Io,
) !void {
    const options = try session.SessionOptions.fromEnvironment(gpa, env);
    defer options.deinit(gpa);

    switch (cmd) {
        .start => |c| {
            handleStartOrResume(gpa, w, options, io, .start, c.name) catch |err| switch (err) {
                error.InvalidSessionName => {
                    try w.writeAll("error: invalid session name\n");
                    try w.flush();
                    return;
                },
                error.SessionNameExists => {
                    try w.print("error: session already exists: {s}\n", .{c.name});
                    try w.flush();
                    return;
                },
                error.Cancelled => {
                    try w.writeAll("cancelled\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };

            try w.print("started session: {s}\n", .{c.name});
        },

        .@"resume" => |c| {
            handleStartOrResume(gpa, w, options, io, .@"resume", c.name) catch |err| switch (err) {
                error.InvalidSessionName => {
                    try w.writeAll("error: invalid session name\n");
                    try w.flush();
                    return;
                },
                error.SessionNotFound => {
                    try w.print("error: session not found: {s}\n", .{c.name});
                    try w.flush();
                    return;
                },
                error.AlreadyCurrentSession => {
                    try w.print("session already active: {s}\n", .{c.name});
                    try w.flush();
                    return;
                },
                error.Cancelled => {
                    try w.writeAll("cancelled\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };

            try w.print("resumed session: {s}\n", .{c.name});
        },

        .remove => |c| {
            handleRemove(gpa, w, options, io, c.name) catch |err| switch (err) {
                error.InvalidSessionName => {
                    try w.writeAll("error: invalid session name\n");
                    try w.flush();
                    return;
                },
                error.SessionNotFound => {
                    try w.print("error: session not found: {s}\n", .{c.name});
                    try w.flush();
                    return;
                },
                error.Cancelled => {
                    try w.writeAll("cancelled\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };

            try w.print("removed session: {s}\n", .{c.name});
        },

        .todo_add => |c| {
            session.todoAdd(gpa, options, c.description, io) catch |err| switch (err) {
                error.NoActiveSession => {
                    try w.writeAll("error: no active session\n");
                    try w.flush();
                    return;
                },
                error.EmptyTodoDescription => {
                    try w.writeAll("error: todo description cannot be empty\n");
                    try w.flush();
                    return;
                },
                error.CorruptSessionState => {
                    try w.writeAll("error: active session state is corrupt\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };

            try w.print("added todo: {s}\n", .{c.description});
        },

        .todo_done => |c| {
            var result = session.todoDone(gpa, options, c.index, io) catch |err| switch (err) {
                error.NoActiveSession => {
                    try w.writeAll("error: no active session\n");
                    try w.flush();
                    return;
                },
                error.InvalidTodoIndex => {
                    try w.print("error: invalid todo index: {}\n", .{c.index});
                    try w.flush();
                    return;
                },
                error.TodoAlreadyDone => {
                    try w.print("error: todo already completed: {}\n", .{c.index});
                    try w.flush();
                    return;
                },
                error.CorruptSessionState => {
                    try w.writeAll("error: active session state is corrupt\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };
            defer result.deinit(gpa);

            try w.print(
                "completed todo {} after {s}: {s}\n",
                .{ c.index, result.elapsed_since_start, result.description },
            );
        },

        .todo_delete => |c| {
            var result = session.todoDelete(gpa, options, c.index, io) catch |err| switch (err) {
                error.NoActiveSession => {
                    try w.writeAll("error: no active session\n");
                    try w.flush();
                    return;
                },
                error.InvalidTodoIndex => {
                    try w.print("error: invalid todo index: {}\n", .{c.index});
                    try w.flush();
                    return;
                },
                error.CorruptSessionState => {
                    try w.writeAll("error: active session state is corrupt\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };
            defer result.deinit(gpa);

            try w.print("deleted todo {}: {s}\n", .{ c.index, result.description });
        },

        .todo_undo => |c| {
            var result = session.todoUndo(gpa, options, c.index, io) catch |err| switch (err) {
                error.NoActiveSession => {
                    try w.writeAll("error: no active session\n");
                    try w.flush();
                    return;
                },
                error.InvalidTodoIndex => {
                    try w.print("error: invalid todo index: {}\n", .{c.index});
                    try w.flush();
                    return;
                },
                error.TodoAlreadyOpen => {
                    try w.print("error: todo already open: {}\n", .{c.index});
                    try w.flush();
                    return;
                },
                error.CorruptSessionState => {
                    try w.writeAll("error: active session state is corrupt\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };
            defer result.deinit(gpa);

            try w.print("reopened todo {}: {s}\n", .{ c.index, result.description });
        },

        .notes => |c| {
            session.notesAppend(gpa, options, c.content, io) catch |err| switch (err) {
                error.NoActiveSession => {
                    try w.writeAll("error: no active session\n");
                    try w.flush();
                    return;
                },
                error.EmptyNotesContent => {
                    try w.writeAll("error: notes content cannot be empty\n");
                    try w.flush();
                    return;
                },
                error.CorruptSessionState => {
                    try w.writeAll("error: active session state is corrupt\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };

            try w.print("appended note: {s}\n", .{c.content});
        },

        .open => |c| {
            const target = switch (c.target) {
                .notes => session.OpenTarget.notes,
                .todo => session.OpenTarget.todo,
            };
            const path = session.openTargetPath(gpa, options, target, io) catch |err| switch (err) {
                error.NoActiveSession => {
                    try w.writeAll("error: no active session\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };
            defer gpa.free(path);

            const editor = env.get("EDITOR") orelse "nvim";
            var child = try std.process.spawn(io, .{
                .argv = &.{ editor, path },
                .environ_map = env,
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            switch (try child.wait(io)) {
                .exited => |code| {
                    if (code != 0) {
                        try w.print("error: editor exited with status {}\n", .{code});
                    }
                },
                .signal => |sig| {
                    try w.print("error: editor terminated by signal {}\n", .{@intFromEnum(sig)});
                },
                .stopped, .unknown => |code| {
                    try w.print("error: editor terminated unexpectedly ({})\n", .{code});
                },
            }
        },

        .list => {
            const sessions = try session.listSessions(gpa, options, io);
            defer {
                for (sessions) |summary| summary.deinit(gpa);
                gpa.free(sessions);
            }

            if (sessions.len == 0) {
                try w.writeAll("no saved sessions\n");
                try w.flush();
                return;
            }

            for (sessions) |summary| {
                try w.print(
                    "{s}{s}\n  created_at: {s}\n  status: {s}\n",
                    .{
                        summary.name,
                        if (summary.is_current) " (current)" else "",
                        summary.created_at,
                        summary.status,
                    },
                );
                if (summary.ended_at) |ended_at| {
                    try w.print("  ended_at: {s}\n", .{ended_at});
                }
            }
        },

        .status => {
            const s = try session.currentStatus(gpa, options, io);
            defer if (s) |status| status.deinit(gpa);

            if (s) |status| {
                try w.print(
                    "session: {s}\ncreated_at: {s}\nelapsed: {s}\nstatus: {s}\nsince_last_done: {s}\n",
                    .{
                        status.name,
                        status.created_at,
                        status.elapsed,
                        status.state,
                        status.since_last_done orelse "(none)",
                    },
                );
                if (status.warning) |warning| {
                    try w.print("warning: {s}\n", .{warning});
                }
                try w.print("todos:\n{s}", .{status.todos});
                try w.print("notes:\n{s}", .{status.notes});
            } else {
                try w.writeAll("no active session\n");
            }
        },

        .end => {
            var ended = session.end(gpa, options, io) catch |err| switch (err) {
                error.NoActiveSession => {
                    try w.writeAll("error: no active session\n");
                    try w.flush();
                    return;
                },
                else => return err,
            };
            defer ended.deinit(gpa);

            if (ended.recovered_corruption) {
                try w.print("ended session: {s} (recovered corrupt state)\n", .{ended.name});
            } else {
                try w.print("ended session: {s}\n", .{ended.name});
            }
        },
    }
    try w.flush();
}

fn handleStartOrResume(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    options: session.SessionOptions,
    io: std.Io,
    action: SessionConflictAction,
    name: []const u8,
) !void {
    while (true) {
        const completed = switch (action) {
            .start => blk: {
                session.start(gpa, options, name, io) catch |err| switch (err) {
                    error.SessionAlreadyActive => break :blk false,
                    else => return err,
                };
                break :blk true;
            },
            .@"resume" => blk: {
                session.resumeSession(gpa, options, name, io) catch |err| switch (err) {
                    error.SessionAlreadyActive => break :blk false,
                    else => return err,
                };
                break :blk true;
            },
            .remove => unreachable,
        };

        if (completed) return;

        const current = try session.currentSessionName(gpa, options, io);
        defer if (current) |value| gpa.free(value);

        const current_name = current orelse return error.SessionAlreadyActive;
        const confirmed = try confirmReplaceActiveSession(w, io, current_name, action, name);
        if (!confirmed) return error.Cancelled;

        const ended = try session.end(gpa, options, io);
        ended.deinit(gpa);
    }
}

fn confirmReplaceActiveSession(
    w: *std.Io.Writer,
    io: std.Io,
    current_name: []const u8,
    action: SessionConflictAction,
    target_name: []const u8,
) !bool {
    try w.print(
        "session '{s}' is active. End it and {s} '{s}'? [y/n]: ",
        .{
            current_name,
            switch (action) {
                .start => "start",
                .@"resume" => "resume",
                .remove => "remove",
            },
            target_name,
        },
    );
    try w.flush();

    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);

    while (true) {
        const line = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return stdin_reader.err.?,
            error.StreamTooLong => {
                try w.writeAll("\nPlease answer yes or no: ");
                try w.flush();
                continue;
            },
        } orelse return false;

        if (parseConfirmation(line)) |confirmed| {
            return confirmed;
        }

        try w.writeAll("Please answer yes or no: ");
        try w.flush();
    }
}

fn parseConfirmation(line: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "n") or std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    return null;
}

fn handleRemove(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    options: session.SessionOptions,
    io: std.Io,
    name: []const u8,
) !void {
    while (true) {
        session.removeSession(gpa, options, name, io) catch |err| switch (err) {
            error.SessionAlreadyActive => {},
            else => return err,
        };

        const confirmed = try confirmReplaceActiveSession(w, io, name, .remove, name);
        if (!confirmed) return error.Cancelled;

        const ended = try session.end(gpa, options, io);
        ended.deinit(gpa);
    }
}

test "parse confirmation accepts yes and no" {
    try std.testing.expectEqual(@as(?bool, true), parseConfirmation("yes\n"));
    try std.testing.expectEqual(@as(?bool, true), parseConfirmation(" Y "));
    try std.testing.expectEqual(@as(?bool, false), parseConfirmation("no"));
    try std.testing.expectEqual(@as(?bool, false), parseConfirmation(" n\t"));
    try std.testing.expectEqual(@as(?bool, null), parseConfirmation(""));
    try std.testing.expectEqual(@as(?bool, null), parseConfirmation("maybe"));
}
