const parse = @import("parse.zig");
const std = @import("std");
const session = @import("session.zig");

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
            session.start(gpa, options, c.name, io) catch |err| switch (err) {
                error.InvalidSessionName => {
                    try w.writeAll("error: invalid session name\n");
                    try w.flush();
                    return;
                },
                error.SessionAlreadyActive => {
                    const current = try session.currentSessionName(gpa, options, io);
                    defer if (current) |name| gpa.free(name);

                    if (current) |name| {
                        try w.print("error: a session is already active: {s}\n", .{name});
                    } else {
                        try w.writeAll("error: a session is already active\n");
                    }
                    try w.flush();
                    return;
                },
                error.SessionNameExists => {
                    try w.print("error: session already exists: {s}\n", .{c.name});
                    try w.flush();
                    return;
                },
                else => return err,
            };

            try w.print("started session: {s}\n", .{c.name});
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
