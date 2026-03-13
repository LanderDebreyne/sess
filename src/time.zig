const std = @import("std");

pub fn nowIso8601Utc(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return formatUnixTimestampIso8601Utc(gpa, std.Io.Clock.now(.real, io));
}

pub fn formatDurationHuman(gpa: std.mem.Allocator, total_seconds: u64) ![]u8 {
    var remaining = total_seconds;
    const days = remaining / 86_400;
    remaining %= 86_400;
    const hours = remaining / 3_600;
    remaining %= 3_600;
    const minutes = remaining / 60;
    const seconds = remaining % 60;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    if (days > 0) {
        const part = try std.fmt.allocPrint(gpa, "{d}d ", .{days});
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
    }
    if (hours > 0 or days > 0) {
        const part = try std.fmt.allocPrint(gpa, "{d}h ", .{hours});
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
    }
    if (minutes > 0 or hours > 0 or days > 0) {
        const part = try std.fmt.allocPrint(gpa, "{d}m ", .{minutes});
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
    }
    const suffix = try std.fmt.allocPrint(gpa, "{d}s", .{seconds});
    defer gpa.free(suffix);
    try out.appendSlice(gpa, suffix);

    return out.toOwnedSlice(gpa);
}

pub fn parseIso8601Utc(value: []const u8) !i64 {
    if (value.len != 20) return error.InvalidTimestamp;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') {
        return error.InvalidTimestamp;
    }

    const year = try std.fmt.parseInt(i64, value[0..4], 10);
    const month = try std.fmt.parseInt(i64, value[5..7], 10);
    const day = try std.fmt.parseInt(i64, value[8..10], 10);
    const hour = try std.fmt.parseInt(i64, value[11..13], 10);
    const minute = try std.fmt.parseInt(i64, value[14..16], 10);
    const second = try std.fmt.parseInt(i64, value[17..19], 10);

    if (month < 1 or month > 12) return error.InvalidTimestamp;
    if (day < 1 or day > 31) return error.InvalidTimestamp;
    if (hour < 0 or hour > 23) return error.InvalidTimestamp;
    if (minute < 0 or minute > 59) return error.InvalidTimestamp;
    if (second < 0 or second > 59) return error.InvalidTimestamp;

    const days = daysFromCivil(year, month, day);
    return days * 86_400 + hour * 3_600 + minute * 60 + second;
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

    return .{ .year = y, .month = m, .day = d };
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = year - (if (month <= 2) @as(i64, 1) else @as(i64, 0));
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "formats human duration" {
    const rendered = try formatDurationHuman(std.testing.allocator, 104_431);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("1d 5h 0m 31s", rendered);
}

test "parses iso8601 timestamp" {
    try std.testing.expectEqual(@as(i64, 1_710_324_123), try parseIso8601Utc("2024-03-12T11:22:03Z"));
}
