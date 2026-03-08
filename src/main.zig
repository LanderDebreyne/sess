const std = @import("std");

const Command = struct { name: []const u8, help: []const u8 };

const Parsed = struct { show_help: bool = false, command: ?Command = null };

const commands = [_]Command{
    makeCommand("start", "start a session"),
    makeCommand("stop", "stop a session"),
    makeCommand("todo", "add a todo"),
};

const Spec = struct {
    name: []const u8,
    summary: []const u8,
    commands: []const Command,
};

fn makeCommand(name: []const u8, help: []const u8) Command {
    return Command{ .name = name, .help = help };
}

fn getCommand(spec: Spec, arg: []const u8) ?Command {
    for (spec.commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, arg)) return cmd;
    }
    return null;
}

fn parseArgs(spec: Spec, args: []const []const u8) !Parsed {
    var parsed: Parsed = .{};

    for (args[1..]) |arg| {
        if ((parsed.command == null)) {
            if (std.mem.eql(u8, arg, "help")) {
                parsed.show_help = true;
                continue;
            }
            if (getCommand(spec, arg)) |cmd| {
                parsed.command = cmd;
                continue;
            }
        }

        return error.UnexpectedArgument;
    }

    if ((parsed.command == null) and !parsed.show_help) {
        parsed.show_help = true;
    }

    return parsed;
}

fn printUsage(spec: Spec, w: *std.Io.Writer) !void {
    try w.print("Usage: {s} <command>\n\n", .{spec.name});
    try w.print("{s}\n\n", .{spec.summary});
    try w.writeAll("Commands:\n");

    for (spec.commands) |cmd| {
        try w.print("  {s:<10} {s}\n", .{ cmd.name, cmd.help });
    }
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    const spec = Spec{
        .name = "sess",
        .summary = "session tracker",
        .commands = &commands,
    };

    const parsed = try parseArgs(spec, args);

    if (parsed.show_help) {
        try printUsage(spec, &stdout_writer.interface);
        return;
    }

    const cmd = parsed.command orelse unreachable;

    try stdout.print("command: {s}\n", .{cmd.name});
    try stdout.flush();
}
