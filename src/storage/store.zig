const std = @import("std");
const file = @import("file.zig");

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
        return .{ .state_home = path };
    }

    pub fn deinit(self: SessionOptions, gpa: std.mem.Allocator) void {
        gpa.free(self.state_home);
    }
};

pub const SessionStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: SessionOptions,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: SessionOptions) SessionStore {
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
        };
    }

    pub fn ensureBaseDirs(self: SessionStore) !void {
        const sessions_dir = try self.sessionsDirPath();
        defer self.gpa.free(sessions_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, sessions_dir);
    }

    pub fn currentSessionName(self: SessionStore) !?[]u8 {
        const current_path = try self.currentPath();
        defer self.gpa.free(current_path);

        return std.Io.Dir.cwd().readFileAlloc(self.io, current_path, self.gpa, .limited(1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    pub fn sessionExists(self: SessionStore, name: []const u8) !bool {
        const session_dir = try self.sessionDirPath(name);
        defer self.gpa.free(session_dir);

        if (std.Io.Dir.cwd().access(self.io, session_dir, .{})) |_| {
            return true;
        } else |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    }

    pub fn createSession(
        self: SessionStore,
        name: []const u8,
        meta_contents: []const u8,
        log_contents: []const u8,
    ) !void {
        try self.ensureBaseDirs();

        const session_dir = try self.sessionDirPath(name);
        defer self.gpa.free(session_dir);

        try std.Io.Dir.cwd().createDir(self.io, session_dir, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(self.io, session_dir) catch {};

        try file.createFileExclusive(self.gpa, self.io, session_dir, "meta.txt", meta_contents);
        try file.createFileExclusive(self.gpa, self.io, session_dir, "notes.md",
            \\# Notes
            \\
            \\
        );
        try file.createFileExclusive(self.gpa, self.io, session_dir, "log.txt", log_contents);
        try file.createFileExclusive(self.gpa, self.io, session_dir, "todos.txt", "");
    }

    pub fn setCurrent(self: SessionStore, name: []const u8) !void {
        const current_path = try self.currentPath();
        defer self.gpa.free(current_path);
        try file.writeFileAtomic(self.io, current_path, name);
    }

    pub fn clearCurrent(self: SessionStore) !void {
        const current_path = try self.currentPath();
        defer self.gpa.free(current_path);

        std.Io.Dir.cwd().deleteFile(self.io, current_path) catch |err| switch (err) {
            error.FileNotFound => return error.NoActiveSession,
            else => return err,
        };
    }

    pub fn readMeta(self: SessionStore, name: []const u8) ![]u8 {
        return self.readSessionFile(name, "meta.txt", 4096);
    }

    pub fn writeMeta(self: SessionStore, name: []const u8, contents: []const u8) !void {
        try self.writeSessionFile(name, "meta.txt", contents);
    }

    pub fn readTodos(self: SessionStore, name: []const u8) ![]u8 {
        return self.readSessionFile(name, "todos.txt", 1 << 20);
    }

    pub fn writeTodos(self: SessionStore, name: []const u8, contents: []const u8) !void {
        try self.writeSessionFile(name, "todos.txt", contents);
    }

    pub fn readNotes(self: SessionStore, name: []const u8) ![]u8 {
        return self.readSessionFile(name, "notes.md", 1 << 20);
    }

    pub fn writeNotes(self: SessionStore, name: []const u8, contents: []const u8) !void {
        try self.writeSessionFile(name, "notes.md", contents);
    }

    pub fn notesPath(self: SessionStore, name: []const u8) ![]u8 {
        return self.sessionFilePath(name, "notes.md");
    }

    pub fn todosPath(self: SessionStore, name: []const u8) ![]u8 {
        return self.sessionFilePath(name, "todos.txt");
    }

    pub fn appendLog(self: SessionStore, name: []const u8, line: []const u8) !void {
        const existing = self.readSessionFile(name, "log.txt", 1 << 20) catch |err| switch (err) {
            error.FileNotFound => try self.gpa.dupe(u8, ""),
            else => return err,
        };
        defer self.gpa.free(existing);

        const updated = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ existing, line });
        defer self.gpa.free(updated);
        try self.writeSessionFile(name, "log.txt", updated);
    }

    pub fn deleteMetaForTest(self: SessionStore, name: []const u8) !void {
        const path = try self.sessionFilePath(name, "meta.txt");
        defer self.gpa.free(path);
        try std.Io.Dir.cwd().deleteFile(self.io, path);
    }

    fn readSessionFile(
        self: SessionStore,
        name: []const u8,
        file_name: []const u8,
        limit: usize,
    ) ![]u8 {
        const path = try self.sessionFilePath(name, file_name);
        defer self.gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(limit));
    }

    fn writeSessionFile(
        self: SessionStore,
        name: []const u8,
        file_name: []const u8,
        contents: []const u8,
    ) !void {
        const path = try self.sessionFilePath(name, file_name);
        defer self.gpa.free(path);
        try file.writeFileAtomic(self.io, path, contents);
    }

    fn appDirPath(self: SessionStore) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/sess", .{self.options.state_home});
    }

    fn sessionsDirPath(self: SessionStore) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/sess/sessions", .{self.options.state_home});
    }

    fn currentPath(self: SessionStore) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/sess/current", .{self.options.state_home});
    }

    fn sessionDirPath(self: SessionStore, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/sess/sessions/{s}", .{ self.options.state_home, name });
    }

    fn sessionFilePath(
        self: SessionStore,
        name: []const u8,
        file_name: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(
            self.gpa,
            "{s}/sess/sessions/{s}/{s}",
            .{ self.options.state_home, name, file_name },
        );
    }
};
