const std = @import("std");

pub const StartError = error{
    InvalidSessionName,
    SessionAlreadyActive,
};

pub const SessionOptions = struct {
    state_home: []const u8,

    pub fn fromEnvironment(
        gpa: std.mem.Allocator,
        env: *const std.process.Environ.Map,
    ) !SessionOptions {
        if (env.get("XDG_STATE_HOME")) |p| {
            return .{
                .state_home = try gpa.dupe(u8, p),
            };
        }

        const home = env.get("HOME") orelse
            return error.EnvironmentVariableNotFound;

        const path = try std.fs.path.join(gpa, &.{ home, ".local", "state" });

        return .{
            .state_home = path,
        };
    }

    pub fn deinit(self: SessionOptions, gpa: std.mem.Allocator) void {
        gpa.free(self.state_home);
    }
};

pub fn start(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    name: []const u8,
    io: std.Io,
) !void {
    try validateSessionName(name);

    const cwd = std.Io.Dir.cwd();
    const state_home = options.state_home;

    const app_dir_path = try std.fmt.allocPrint(gpa, "{s}/sess", .{state_home});
    defer gpa.free(app_dir_path);

    const sessions_dir_path = try std.fmt.allocPrint(gpa, "{s}/sessions", .{app_dir_path});
    defer gpa.free(sessions_dir_path);

    const current_path = try std.fmt.allocPrint(gpa, "{s}/current", .{app_dir_path});
    defer gpa.free(current_path);

    const session_dir_path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}",
        .{ sessions_dir_path, name },
    );
    defer gpa.free(session_dir_path);

    // Ensure base directories exist.
    try cwd.createDirPath(io, sessions_dir_path);

    // Only one active session allowed.
    if (cwd.access(io, current_path, .{})) |_| {
        return error.SessionAlreadyActive;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try cwd.createDirPath(io, session_dir_path);

    const created_at = try nowIso8601Utc(gpa, io);
    defer gpa.free(created_at);

    const meta_contents = try std.fmt.allocPrint(
        gpa,
        \\name: {s}
        \\created_at: {s}
        \\status: active
        \\
    ,
        .{ name, created_at },
    );
    defer gpa.free(meta_contents);

    const log_contents = try std.fmt.allocPrint(
        gpa,
        "[{s}] session started: {s}\n",
        .{ created_at, name },
    );
    defer gpa.free(log_contents);

    try createFileExclusive(gpa, io, session_dir_path, "meta.txt", meta_contents);
    try createFileExclusive(gpa, io, session_dir_path, "notes.md",
        \\# Notes
        \\
        \\
    );
    try createFileExclusive(gpa, io, session_dir_path, "log.txt", log_contents);
    try createFileExclusive(gpa, io, session_dir_path, "todos.txt", "");

    try writeFileAtomic(io, current_path, name);
}

pub fn currentSessionName(
    gpa: std.mem.Allocator,
    options: SessionOptions,
    io: std.Io,
) !?[]u8 {
    const current_path = try std.fmt.allocPrint(gpa, "{s}/sess/current", .{options.state_home});
    defer gpa.free(current_path);

    return std.Io.Dir.cwd().readFileAlloc(io, current_path, gpa, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

pub fn sessionDirPath(
    gpa: std.mem.Allocator,
    name: []const u8,
    options: SessionOptions,
) ![]u8 {
    return try std.fmt.allocPrint(
        gpa,
        "{s}/sess/sessions/{s}",
        .{ options.state_home, name },
    );
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

fn createFileExclusive(
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

fn writeFileAtomic(
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
    try af.link(io);
}

fn nowIso8601Utc(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Clock.now(.real, io);
    return try formatUnixTimestampIso8601Utc(gpa, now);
}

fn formatUnixTimestampIso8601Utc(allocator: std.mem.Allocator, now: std.Io.Timestamp) ![]u8 {
    const ts: i64 = now.toSeconds();
    const secs_per_day: i64 = 86_400;
    const z = @divFloor(ts, secs_per_day);
    const rem = ts - z * secs_per_day;

    const hour: u8 = @intCast(@divFloor(rem, 3600));
    const minute: u8 = @intCast(@divFloor(@mod(rem, 3600), 60));
    const second: u8 = @intCast(@mod(rem, 60));

    const ymd = civilFromDays(z);

    if (ymd.year < 0) return error.UnsupportedTimestamp;

    const year: u16 = @intCast(ymd.year);
    const month: u8 = @intCast(ymd.month);
    const day: u8 = @intCast(ymd.day);

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, month, day, hour, minute, second },
    );
}

const Ymd = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_unix_epoch: i64) Ymd {
    // Howard Hinnant's civil_from_days, with Unix epoch offset.
    const z = days_since_unix_epoch + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096),
        365,
    );
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    y += if (m <= 2) 1 else 0;

    return .{
        .year = y,
        .month = m,
        .day = d,
    };
}
