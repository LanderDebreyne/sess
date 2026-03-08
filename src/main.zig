const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    std.debug.print("sess: session tracker\n", .{});

    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    for (args, 0..) |arg, i| {
        std.debug.print("arg {d}: {s}\n", .{ i, arg });
    }
}
