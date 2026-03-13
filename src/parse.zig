const std = @import("std");

const CommandKind = enum {
    start,
    todo_add,
    todo_done,
    todo_delete,
    todo_undo,
    notes,
    open,
    status,
    end,
};

pub const CommandData = union(CommandKind) {
    start: struct {
        name: []const u8,
    },
    todo_add: struct {
        description: []const u8,
    },
    todo_done: struct {
        index: usize,
    },
    todo_delete: struct {
        index: usize,
    },
    todo_undo: struct {
        index: usize,
    },
    notes: struct {
        content: []const u8,
    },
    open: struct {
        target: OpenTarget,
    },
    status: void,
    end: void,
};

pub const OpenTarget = enum {
    notes,
    todo,
};

const Parsed = struct {
    show_help: bool = false,
    command: ?CommandData = null,
};

const Command = struct {
    name: []const u8,
    usage: []const u8,
    help: []const u8,
};

pub const commands = [_]Command{
    .{ .name = "start", .usage = "sess start <name>", .help = "start a session" },
    .{ .name = "todo", .usage = "sess todo add <description>", .help = "manage todos" },
    .{ .name = "notes", .usage = "sess notes <text>", .help = "append to session notes" },
    .{ .name = "open", .usage = "sess open [notes|todo]", .help = "open notes or todos in editor" },
    .{ .name = "status", .usage = "sess status", .help = "show session status" },
    .{ .name = "end", .usage = "sess end", .help = "end the current session" },
};

const ArgCursor = struct {
    args: []const []const u8,
    i: usize = 1,

    fn peek(self: *const ArgCursor) ?[]const u8 {
        if (self.i >= self.args.len) return null;
        return self.args[self.i];
    }

    fn next(self: *ArgCursor) ?[]const u8 {
        const arg = self.peek() orelse return null;
        self.i += 1;
        return arg;
    }

    fn hasMore(self: *const ArgCursor) bool {
        return self.i < self.args.len;
    }

    fn rest(self: *ArgCursor) []const []const u8 {
        const out = self.args[self.i..];
        self.i = self.args.len;
        return out;
    }
};

pub const ParseErr = error{
    InvalidArguments,
};

pub const ParseFailure = struct {
    message: []const u8,
};

pub const Spec = struct {
    name: []const u8,
    summary: []const u8,
    commands: []const Command,
};

fn fail(
    gpa: std.mem.Allocator,
    failure: *?ParseFailure,
    comptime fmt: []const u8,
    args: anytype,
) ParseErr {
    failure.* = .{ .message = std.fmt.allocPrint(gpa, fmt, args) catch "invalid arguments" };
    return error.InvalidArguments;
}

fn requireNext(
    gpa: std.mem.Allocator,
    cur: *ArgCursor,
    failure: *?ParseFailure,
    what: []const u8,
) ParseErr![]const u8 {
    return cur.next() orelse fail(gpa, failure, "missing {s}", .{what});
}

fn requireNoMore(
    gpa: std.mem.Allocator,
    cur: *ArgCursor,
    failure: *?ParseFailure,
) ParseErr!void {
    if (cur.next()) |arg| {
        return fail(gpa, failure, "unexpected extra argument: '{s}'", .{arg});
    }
}

fn takeRestJoined(
    gpa: std.mem.Allocator,
    cur: *ArgCursor,
    failure: *?ParseFailure,
    what: []const u8,
) ParseErr![]const u8 {
    if (!cur.hasMore()) {
        return fail(gpa, failure, "missing {s}", .{what});
    }

    const parts = cur.rest();
    return std.mem.join(gpa, " ", parts) catch {
        return fail(gpa, failure, "failed to allocate {s}", .{what});
    };
}

fn parseIndex(
    gpa: std.mem.Allocator,
    s: []const u8,
    failure: *?ParseFailure,
) ParseErr!usize {
    return std.fmt.parseUnsigned(usize, s, 10) catch {
        return fail(
            gpa,
            failure,
            "invalid todo index: '{s}' (expected a positive integer)",
            .{s},
        );
    };
}

pub fn printUsage(spec: Spec, w: *std.Io.Writer) !void {
    try w.writeAll("Usage:\n");
    for (spec.commands) |cmd| {
        try w.print("  {s}\n", .{cmd.usage});
    }
    try w.print("  {s} --help\n\n", .{spec.name});

    try w.print("{s}\n\n", .{spec.summary});
    try w.writeAll("Commands:\n");
    for (spec.commands) |cmd| {
        try w.print("  {s:<10} {s}\n", .{ cmd.name, cmd.help });
    }
    try w.flush();
}

pub fn parseArgs(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    failure: *?ParseFailure,
) ParseErr!Parsed {
    var parsed: Parsed = .{};
    var cur = ArgCursor{ .args = args };

    const first = cur.next() orelse {
        parsed.show_help = true;
        return parsed;
    };

    if (std.mem.eql(u8, first, "help") or
        std.mem.eql(u8, first, "--help") or
        std.mem.eql(u8, first, "-h"))
    {
        parsed.show_help = true;
        try requireNoMore(gpa, &cur, failure);
        return parsed;
    }

    if (std.mem.eql(u8, first, "start")) {
        const name = try takeRestJoined(gpa, &cur, failure, "session name");
        parsed.command = .{ .start = .{ .name = name } };
        return parsed;
    }

    if (std.mem.eql(u8, first, "todo")) {
        const sub = try requireNext(gpa, &cur, failure, "todo subcommand ('add', 'done', 'delete', or 'undo')");

        if (std.mem.eql(u8, sub, "add")) {
            const desc = try takeRestJoined(
                gpa,
                &cur,
                failure,
                "todo description",
            );
            parsed.command = .{ .todo_add = .{ .description = desc } };
            return parsed;
        }

        if (std.mem.eql(u8, sub, "done")) {
            const raw_index = try requireNext(gpa, &cur, failure, "todo index");
            const index = try parseIndex(gpa, raw_index, failure);
            try requireNoMore(gpa, &cur, failure);
            parsed.command = .{ .todo_done = .{ .index = index } };
            return parsed;
        }

        if (std.mem.eql(u8, sub, "delete")) {
            const raw_index = try requireNext(gpa, &cur, failure, "todo index");
            const index = try parseIndex(gpa, raw_index, failure);
            try requireNoMore(gpa, &cur, failure);
            parsed.command = .{ .todo_delete = .{ .index = index } };
            return parsed;
        }

        if (std.mem.eql(u8, sub, "undo")) {
            const raw_index = try requireNext(gpa, &cur, failure, "todo index");
            const index = try parseIndex(gpa, raw_index, failure);
            try requireNoMore(gpa, &cur, failure);
            parsed.command = .{ .todo_undo = .{ .index = index } };
            return parsed;
        }

        return fail(
            gpa,
            failure,
            "unknown todo subcommand: '{s}' (expected 'add', 'done', 'delete', or 'undo')",
            .{sub},
        );
    }

    if (std.mem.eql(u8, first, "notes")) {
        const content = try takeRestJoined(gpa, &cur, failure, "notes content");
        parsed.command = .{ .notes = .{ .content = content } };
        return parsed;
    }

    if (std.mem.eql(u8, first, "open")) {
        const target = if (cur.peek()) |arg| blk: {
            _ = cur.next();
            if (std.mem.eql(u8, arg, "notes")) break :blk OpenTarget.notes;
            if (std.mem.eql(u8, arg, "todo")) break :blk OpenTarget.todo;
            return fail(gpa, failure, "unknown open target: '{s}' (expected 'notes' or 'todo')", .{arg});
        } else OpenTarget.notes;
        try requireNoMore(gpa, &cur, failure);
        parsed.command = .{ .open = .{ .target = target } };
        return parsed;
    }

    if (std.mem.eql(u8, first, "status")) {
        try requireNoMore(gpa, &cur, failure);
        parsed.command = .{ .status = {} };
        return parsed;
    }

    if (std.mem.eql(u8, first, "end")) {
        try requireNoMore(gpa, &cur, failure);
        parsed.command = .{ .end = {} };
        return parsed;
    }

    return fail(gpa, failure, "unknown command: '{s}'", .{first});
}

test "parses todo done command" {
    const gpa = std.testing.allocator;
    var failure: ?ParseFailure = null;
    const args = [_][]const u8{ "sess", "todo", "done", "3" };

    const parsed = try parseArgs(gpa, &args, &failure);
    try std.testing.expect(!parsed.show_help);
    try std.testing.expect(parsed.command != null);
    try std.testing.expectEqual(@as(usize, 3), parsed.command.?.todo_done.index);
}

test "parses start command by consuming the remaining input" {
    const gpa = std.testing.allocator;
    var failure: ?ParseFailure = null;
    const args = [_][]const u8{ "sess", "start", "weekly", "planning", "sync" };

    const parsed = try parseArgs(gpa, &args, &failure);
    try std.testing.expect(!parsed.show_help);
    try std.testing.expect(parsed.command != null);
    try std.testing.expectEqualStrings(
        "weekly planning sync",
        parsed.command.?.start.name,
    );
}

test "rejects extra arguments for status" {
    const gpa = std.testing.allocator;
    var failure: ?ParseFailure = null;
    const args = [_][]const u8{ "sess", "status", "extra" };

    try std.testing.expectError(error.InvalidArguments, parseArgs(gpa, &args, &failure));
    try std.testing.expect(failure != null);
}

test "parses notes command by consuming the remaining input" {
    const gpa = std.testing.allocator;
    var failure: ?ParseFailure = null;
    const args = [_][]const u8{ "sess", "notes", "investigate", "api", "drift" };

    const parsed = try parseArgs(gpa, &args, &failure);
    try std.testing.expectEqualStrings("investigate api drift", parsed.command.?.notes.content);
}

test "parses open command defaulting to notes" {
    const gpa = std.testing.allocator;
    var failure: ?ParseFailure = null;
    const args = [_][]const u8{ "sess", "open" };

    const parsed = try parseArgs(gpa, &args, &failure);
    try std.testing.expectEqual(OpenTarget.notes, parsed.command.?.open.target);
}

test "parses todo delete and undo commands" {
    const gpa = std.testing.allocator;
    var failure: ?ParseFailure = null;

    const delete_args = [_][]const u8{ "sess", "todo", "delete", "2" };
    const delete_parsed = try parseArgs(gpa, &delete_args, &failure);
    try std.testing.expectEqual(@as(usize, 2), delete_parsed.command.?.todo_delete.index);

    failure = null;
    const undo_args = [_][]const u8{ "sess", "todo", "undo", "4" };
    const undo_parsed = try parseArgs(gpa, &undo_args, &failure);
    try std.testing.expectEqual(@as(usize, 4), undo_parsed.command.?.todo_undo.index);
}
