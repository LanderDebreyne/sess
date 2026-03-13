const std = @import("std");
const time = @import("time.zig");

pub const State = enum {
    open,
    done,
};

pub const Item = struct {
    state: State,
    description: []u8,
    done_at: ?[]u8 = null,
    elapsed_seconds: ?u64 = null,

    pub fn open(gpa: std.mem.Allocator, description: []const u8) !Item {
        return .{
            .state = .open,
            .description = try gpa.dupe(u8, description),
        };
    }

    pub fn deinit(self: Item, gpa: std.mem.Allocator) void {
        gpa.free(self.description);
        if (self.done_at) |value| gpa.free(value);
    }
};

pub fn freeList(gpa: std.mem.Allocator, items: []Item) void {
    for (items) |item| item.deinit(gpa);
    gpa.free(items);
}

pub fn parseList(gpa: std.mem.Allocator, contents: []const u8) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    defer out.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try out.append(gpa, try parseLine(gpa, line));
    }

    return out.toOwnedSlice(gpa);
}

pub fn formatList(gpa: std.mem.Allocator, items: []const Item) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    for (items) |item| {
        switch (item.state) {
            .open => {
                const line = try std.fmt.allocPrint(gpa, "open\t{s}\n", .{item.description});
                defer gpa.free(line);
                try out.appendSlice(gpa, line);
            },
            .done => {
                const line = try std.fmt.allocPrint(
                    gpa,
                    "done\t{s}\t{s}\t{d}\n",
                    .{
                        item.description,
                        item.done_at orelse "",
                        item.elapsed_seconds orelse 0,
                    },
                );
                defer gpa.free(line);
                try out.appendSlice(gpa, line);
            },
        }
    }

    return out.toOwnedSlice(gpa);
}

pub fn renderList(gpa: std.mem.Allocator, items: []const Item) ![]u8 {
    if (items.len == 0) return gpa.dupe(u8, "  (none)\n");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    for (items, 0..) |item, i| {
        switch (item.state) {
            .open => {
                const line = try std.fmt.allocPrint(gpa, "  {d}. [ ] {s}\n", .{ i + 1, item.description });
                defer gpa.free(line);
                try out.appendSlice(gpa, line);
            },
            .done => {
                const elapsed = if (item.elapsed_seconds) |seconds|
                    try time.formatDurationHuman(gpa, seconds)
                else
                    try gpa.dupe(u8, "unknown");
                defer gpa.free(elapsed);
                const line = try std.fmt.allocPrint(
                    gpa,
                    "  {d}. [x] {s} (done after {s})\n",
                    .{ i + 1, item.description, elapsed },
                );
                defer gpa.free(line);
                try out.appendSlice(gpa, line);
            },
        }
    }

    return out.toOwnedSlice(gpa);
}

fn parseLine(gpa: std.mem.Allocator, line: []const u8) !Item {
    if (std.mem.startsWith(u8, line, "open\t")) {
        return Item.open(gpa, line["open\t".len..]);
    }

    if (std.mem.startsWith(u8, line, "done\t")) {
        var parts = std.mem.splitScalar(u8, line, '\t');
        _ = parts.next();
        const description = parts.next() orelse return error.InvalidTodoFormat;
        const done_at = parts.next() orelse return error.InvalidTodoFormat;
        const elapsed_raw = parts.next() orelse return error.InvalidTodoFormat;

        return .{
            .state = .done,
            .description = try gpa.dupe(u8, description),
            .done_at = try gpa.dupe(u8, done_at),
            .elapsed_seconds = try std.fmt.parseUnsigned(u64, elapsed_raw, 10),
        };
    }

    if (std.mem.startsWith(u8, line, "- [ ] ")) {
        return Item.open(gpa, line["- [ ] ".len..]);
    }

    if (std.mem.startsWith(u8, line, "- [x] ")) {
        return .{
            .state = .done,
            .description = try gpa.dupe(u8, line["- [x] ".len..]),
        };
    }

    return error.InvalidTodoFormat;
}

test "parses legacy and structured todo files" {
    const gpa = std.testing.allocator;
    const contents = "- [ ] first\n" ++
        "done\tsecond\t2026-03-13T11:00:00Z\t3600\n" ++
        "- [x] third\n";

    const items = try parseList(gpa, contents);
    defer freeList(gpa, items);

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(State.open, items[0].state);
    try std.testing.expectEqual(State.done, items[1].state);
    try std.testing.expectEqualStrings("2026-03-13T11:00:00Z", items[1].done_at.?);
    try std.testing.expectEqual(@as(?u64, 3600), items[1].elapsed_seconds);
    try std.testing.expectEqual(State.done, items[2].state);
}

test "renders completion elapsed time" {
    const gpa = std.testing.allocator;
    var items = try gpa.alloc(Item, 2);
    defer freeList(gpa, items);

    items[0] = try Item.open(gpa, "first");
    items[1] = .{
        .state = .done,
        .description = try gpa.dupe(u8, "second"),
        .done_at = try gpa.dupe(u8, "2026-03-13T11:00:00Z"),
        .elapsed_seconds = 3661,
    };

    const rendered = try renderList(gpa, items);
    defer gpa.free(rendered);

    try std.testing.expectEqualStrings(
        "  1. [ ] first\n  2. [x] second (done after 1h 1m 1s)\n",
        rendered,
    );
}
