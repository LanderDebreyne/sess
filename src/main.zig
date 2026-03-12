const std = @import("std");
const session = @import("session.zig");

const CommandKind = enum {
    start,
    todo_add,
    todo_done,
    status,
    end,
};

const CommandData = union(CommandKind) {
    start: struct {
        name: []const u8,
    },
    todo_add: struct {
        description: []const u8,
    },
    todo_done: struct {
        index: usize,
    },
    status: void,
    end: void,
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

const commands = [_]Command{
    .{ .name = "start", .usage = "sess start <name>", .help = "start a session" },
    .{ .name = "todo", .usage = "sess todo add <description>", .help = "manage todos" },
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

const ParseErr = error{
    InvalidArguments,
};

const ParseFailure = struct {
    message: []const u8,
};

const Spec = struct {
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

fn parseArgs(
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
        const sub = try requireNext(gpa, &cur, failure, "todo subcommand ('add' or 'done')");

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

        return fail(gpa, failure, "unknown todo subcommand: '{s}' (expected 'add' or 'done')", .{sub});
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

fn printUsage(spec: Spec, w: *std.Io.Writer) !void {
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

fn run(
    gpa: std.mem.Allocator,
    spec: Spec,
    args: []const []const u8,
    stdout_writer: *std.Io.File.Writer,
    env: *const std.process.Environ.Map,
    io: std.Io,
) !void {
    var parse_failure: ?ParseFailure = null;
    const parsed = parseArgs(gpa, args, &parse_failure) catch |err| switch (err) {
        error.InvalidArguments => {
            const msg = if (parse_failure) |pf| pf.message else "invalid arguments";
            try stdout_writer.interface.print("error: {s}\n\n", .{msg});
            try printUsage(spec, &stdout_writer.interface);
            return;
        },
    };

    if (parsed.show_help) {
        try printUsage(spec, &stdout_writer.interface);
        return;
    }

    const cmd = parsed.command orelse unreachable;

    // dispatch
    try dispatch(
        gpa,
        cmd,
        &stdout_writer.interface,
        env,
        io,
    );
}

fn dispatch(
    gpa: std.mem.Allocator,
    cmd: CommandData,
    w: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    io: std.Io,
) !void {
    switch (cmd) {
        .start => |c| {
            const options = try session.SessionOptions.fromEnvironment(gpa, env);
            defer options.deinit(gpa);

            session.start(
                gpa,
                options,
                c.name,
                io,
            ) catch |err| switch (err) {
                error.InvalidSessionName => {
                    try w.writeAll("error: invalid session name\n");
                    try w.flush();
                    return;
                },
                error.SessionAlreadyActive => {
                    const current = try session.currentSessionName(
                        gpa,
                        options,
                        io,
                    );
                    defer if (current) |name| gpa.free(name);

                    if (current) |name| {
                        try w.print("error: a session is already active: {s}\n", .{name});
                    } else {
                        try w.writeAll("error: a session is already active\n");
                    }
                    try w.flush();
                    return;
                },
                else => return err,
            };

            try w.print("started session: {s}\n", .{c.name});
        },
        .todo_add => |c| {
            try w.print("command: todo add, description={s}\n", .{c.description});
        },
        .todo_done => |c| {
            try w.print("command: todo done, index={}\n", .{c.index});
        },
        .status => {
            try w.writeAll("command: status\n");
        },
        .end => {
            try w.writeAll("command: end\n");
        },
    }
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    // setup
    const gpa: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);

    const args = try init.minimal.args.toSlice(gpa);

    const spec = Spec{
        .name = "sess",
        .summary = "session tracker",
        .commands = &commands,
    };

    try run(gpa, spec, args, &stdout_writer, init.environ_map, init.io);
}
