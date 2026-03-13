const dispatch = @import("dispatch.zig");
const parse = @import("parse.zig");
const std = @import("std");

fn run(
    gpa: std.mem.Allocator,
    spec: parse.Spec,
    args: []const []const u8,
    stdout_writer: *std.Io.File.Writer,
    env: *const std.process.Environ.Map,
    io: std.Io,
) !void {
    var parse_failure: ?parse.ParseFailure = null;
    const parsed = parse.parseArgs(gpa, args, &parse_failure) catch |err| switch (err) {
        error.InvalidArguments => {
            const msg = if (parse_failure) |pf| pf.message else "invalid arguments";
            try stdout_writer.interface.print("error: {s}\n\n", .{msg});
            try parse.printUsage(spec, &stdout_writer.interface);
            return;
        },
    };

    if (parsed.show_help) {
        try parse.printUsage(spec, &stdout_writer.interface);
        return;
    }

    const cmd = parsed.command orelse unreachable;

    try dispatch.dispatch(
        gpa,
        cmd,
        &stdout_writer.interface,
        env,
        io,
    );
}

pub fn main(init: std.process.Init) !void {
    // setup
    const gpa: std.mem.Allocator = init.arena.allocator();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);

    const args = try init.minimal.args.toSlice(gpa);

    const spec = parse.Spec{
        .name = "sess",
        .summary = "session tracker",
        .commands = &parse.commands,
    };

    try run(gpa, spec, args, &stdout_writer, init.environ_map, init.io);
}
