const std = @import("std");

pub fn createFileExclusive(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    file_name: []const u8,
    contents: []const u8,
) !void {
    const full_path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}",
        .{ dir_path, file_name },
    );
    defer gpa.free(full_path);

    const file = try std.Io.Dir.cwd().createFile(io, full_path, .{ .exclusive = true });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(contents);
    try w.flush();
}

pub fn writeFileAtomic(
    io: std.Io,
    full_path: []const u8,
    contents: []const u8,
) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, full_path, .{});
    defer af.deinit(io);

    var buf: [1024]u8 = undefined;
    var fw = af.file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(contents);
    try w.flush();
    try af.replace(io);
}
