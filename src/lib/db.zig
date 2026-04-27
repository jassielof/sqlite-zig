const std = @import("std");
const blob = @import("blob.zig");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const function = @import("function.zig");
const release_util = @import("release.zig");
const PrepareOptions = @import("statement.zig").PrepareOptions;
const Statement = @import("statement.zig").Statement;
const tx = @import("transaction.zig");
const vtab = @import("vtab.zig");

pub const LastError = struct {
    code: c_int,
    extended_code: c_int,
    message: []const u8,
};

pub const OpenOptions = struct {
    path: ?[]const u8 = null,
    create: bool = true,
    read_only: bool = false,
    uri: bool = false,
    full_mutex: bool = true,
    shared_cache: bool = false,
    busy_timeout_ms: ?u32 = 5_000,
};

pub const Db = struct {
    allocator: std.mem.Allocator,
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, options: OpenOptions) errors.Error!Db {
        const flags = computeOpenFlags(options);
        const path = options.path orelse ":memory:";
        const z_path = try allocator.dupeZ(u8, path);
        defer allocator.free(z_path);

        var handle: ?*c.sqlite3 = null;
        const result = c.sqlite3_open_v2(z_path.ptr, &handle, flags, null);
        if (result != c.SQLITE_OK) {
            if (handle) |db_handle| {
                _ = c.sqlite3_close_v2(db_handle);
            }
            return errors.fromCode(result);
        }

        const db = Db{
            .allocator = allocator,
            .handle = handle.?,
        };

        _ = c.sqlite3_extended_result_codes(db.handle, 1);

        if (options.busy_timeout_ms) |timeout| {
            const timeout_result = c.sqlite3_busy_timeout(db.handle, @intCast(timeout));
            if (timeout_result != c.SQLITE_OK) {
                _ = c.sqlite3_close_v2(db.handle);
                return errors.fromCode(timeout_result);
            }
        }

        return db;
    }

    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn exec(self: *Db, sql: []const u8, params: anytype) errors.Error!void {
        var statement = try self.prepare(sql);
        defer statement.deinit();
        try statement.bind(params);
        try statement.execute();
    }

    pub fn execFmt(self: *Db, comptime format: []const u8, args: anytype) errors.Error!void {
        const sql = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(sql);
        try self.exec(sql, .{});
    }

    pub fn prepare(self: *Db, sql: []const u8) errors.Error!Statement {
        return Statement.prepare(self.handle, sql);
    }

    pub fn prepareWithOptions(self: *Db, sql: []const u8, options: PrepareOptions) errors.Error!Statement {
        return Statement.prepareWithOptions(self.handle, sql, options);
    }

    pub fn query(self: *Db, sql: []const u8, params: anytype) errors.Error!Statement {
        var statement = try self.prepare(sql);
        errdefer statement.deinit();
        try statement.bind(params);
        return statement;
    }

    pub fn one(self: *Db, comptime T: type, sql: []const u8, params: anytype) errors.Error!?T {
        var statement = try self.query(sql, params);
        defer statement.deinit();

        if (!try statement.step()) {
            return null;
        }

        return try statement.row(T, self.allocator);
    }

    pub fn all(self: *Db, comptime T: type, sql: []const u8, params: anytype) errors.Error![]T {
        var statement = try self.query(sql, params);
        defer statement.deinit();

        var list = try std.ArrayList(T).initCapacity(self.allocator, 8);
        errdefer {
            for (list.items) |item| {
                release_util.release(self.allocator, item);
            }
            list.deinit(self.allocator);
        }

        while (try statement.step()) {
            try list.append(self.allocator, try statement.row(T, self.allocator));
        }

        return try list.toOwnedSlice(self.allocator);
    }

    pub fn transaction(self: *Db, mode: tx.TransactionMode) errors.Error!tx.Transaction {
        const sql = switch (mode) {
            .deferred => "begin",
            .immediate => "begin immediate",
            .exclusive => "begin exclusive",
        };
        try self.exec(sql, .{});
        return .{ .db = self };
    }

    pub fn savepoint(self: *Db, name: []const u8) errors.Error!tx.Savepoint {
        try self.execFmt("savepoint {s}", .{name});
        return .{ .db = self, .name = name };
    }

    pub fn openBlob(self: *Db, table: []const u8, column: []const u8, row_id: i64, options: blob.Blob.OpenOptions) errors.Error!blob.Blob {
        const z_table = try self.allocator.dupeZ(u8, table);
        defer self.allocator.free(z_table);

        const z_column = try self.allocator.dupeZ(u8, column);
        defer self.allocator.free(z_column);

        const z_database = switch (options.database) {
            .main => null,
            .temp => null,
            .attached => |name| try self.allocator.dupeZ(u8, name),
        };
        defer if (z_database) |name| self.allocator.free(name);

        const database_name: [*:0]const u8 = switch (options.database) {
            .main => "main",
            .temp => "temp",
            .attached => z_database.?.ptr,
        };

        var handle: ?*c.sqlite3_blob = null;
        const result = c.sqlite3_blob_open(
            self.handle,
            database_name,
            z_table.ptr,
            z_column.ptr,
            row_id,
            if (options.write) 1 else 0,
            &handle,
        );
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }

        return .{
            .handle = handle.?,
            .size = @intCast(c.sqlite3_blob_bytes(handle.?)),
        };
    }

    pub fn createScalarFunction(self: *Db, comptime name: []const u8, comptime func: anytype, flags: function.FunctionFlags) errors.Error!void {
        try function.createScalar(self.handle, self.allocator, name, func, flags);
    }

    /// Registers a scalar SQL function with user-provided callback state.
    ///
    /// If `func` takes `sqlite.FunctionContext` as its first parameter, it can
    /// recover `user_data` through `ctx.userContext(...)`.
    pub fn createScalarFunctionWithUserData(self: *Db, comptime name: []const u8, user_data: anytype, comptime func: anytype, flags: function.FunctionFlags) errors.Error!void {
        try function.createScalarWithUserData(self.handle, self.allocator, name, user_data, func, flags);
    }

    /// Registers an aggregate SQL function backed by a Zig state type.
    pub fn createAggregateFunction(self: *Db, comptime name: []const u8, comptime Aggregate: type, flags: function.FunctionFlags) errors.Error!void {
        try function.createAggregate(self.handle, self.allocator, name, Aggregate, flags);
    }

    /// Registers an aggregate SQL function that uses `sqlite.FunctionContext`.
    ///
    /// This is the lowest-level aggregate API and allows callbacks to combine
    /// user-provided state with SQLite-managed aggregate storage.
    pub fn createAggregateFunctionWithUserData(self: *Db, comptime name: []const u8, user_data: anytype, comptime step_func: anytype, comptime final_func: anytype, flags: function.FunctionFlags) errors.Error!void {
        try function.createAggregateWithUserData(self.handle, self.allocator, name, user_data, step_func, final_func, flags);
    }

    /// Registers a Zig-backed virtual table module on this connection.
    pub fn createVirtualTableModule(self: *Db, comptime name: []const u8, comptime Table: type) errors.Error!void {
        try vtab.createModule(self.handle, self.allocator, name, Table);
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return @intCast(c.sqlite3_last_insert_rowid(self.handle));
    }

    pub fn changes(self: *Db) usize {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastError(self: *Db) LastError {
        return .{
            .code = c.sqlite3_errcode(self.handle),
            .extended_code = c.sqlite3_extended_errcode(self.handle),
            .message = std.mem.span(c.sqlite3_errmsg(self.handle)),
        };
    }
};

fn computeOpenFlags(options: OpenOptions) c_int {
    var flags: c_int = c.SQLITE_OPEN_EXRESCODE;

    if (options.read_only) {
        flags |= c.SQLITE_OPEN_READONLY;
    } else {
        flags |= c.SQLITE_OPEN_READWRITE;
        if (options.create) {
            flags |= c.SQLITE_OPEN_CREATE;
        }
    }

    if (options.path == null) {
        flags |= c.SQLITE_OPEN_MEMORY;
    }

    if (options.uri) {
        flags |= c.SQLITE_OPEN_URI;
    }
    if (options.shared_cache) {
        flags |= c.SQLITE_OPEN_SHAREDCACHE;
    }

    flags |= if (options.full_mutex) c.SQLITE_OPEN_FULLMUTEX else c.SQLITE_OPEN_NOMUTEX;
    return flags;
}

test "db convenience API maps rows into structs" {
    var db = try Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec(
        "create table users(id integer primary key, name text not null, active integer, score real)",
        .{},
    );
    try db.exec("insert into users(name, active, score) values (?, ?, ?)", .{ "Ada", true, 9.5 });
    try db.exec("insert into users(name, active, score) values (?, ?, ?)", .{ "Linus", false, 8.25 });

    const User = struct {
        id: i64,
        name: []const u8,
        active: bool,
        score: f64,
    };

    const users = try db.all(User, "select id, name, active, score from users order by id", .{});
    defer release_util.release(std.testing.allocator, users);

    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqualStrings("Ada", users[0].name);
    try std.testing.expect(users[0].active);
    try std.testing.expectApproxEqAbs(@as(f64, 8.25), users[1].score, 0.0001);
}

test "db supports scalar and aggregate SQL functions" {
    var db = try Db.open(std.testing.allocator, .{});
    defer db.deinit();

    const upper_len = struct {
        fn call(text: []const u8) i64 {
            return @intCast(text.len);
        }
    }.call;

    const SumInts = struct {
        const Self = @This();

        total: i64 = 0,

        pub fn step(self: *Self, value: i64) void {
            self.total += value;
        }

        pub fn final(self: *Self) i64 {
            return self.total;
        }
    };

    try db.createScalarFunction("zig_upper_len", upper_len, .{});
    try db.createAggregateFunction("zig_sum_ints", SumInts, .{});

    const scalar_result = (try db.one(i64, "select zig_upper_len(?)", .{"hello"})).?;
    try std.testing.expectEqual(@as(i64, 5), scalar_result);

    try db.exec("create table metrics(value integer not null)", .{});
    try db.exec("insert into metrics(value) values (?), (?), (?)", .{ @as(i64, 3), @as(i64, 7), @as(i64, 11) });

    const aggregate_result = (try db.one(i64, "select zig_sum_ints(value) from metrics", .{})).?;
    try std.testing.expectEqual(@as(i64, 21), aggregate_result);
}

test "db supports incremental blob io" {
    var db = try Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec("create table files(id integer primary key, data blob not null)", .{});
    try db.exec("insert into files(data) values (?)", .{@import("types.zig").ZeroBlob{ .length = 16 }});

    var blob_handle = try db.openBlob("files", "data", db.lastInsertRowId(), .{ .write = true });
    defer blob_handle.deinit();
    try blob_handle.writeAll("hello sqlite-zig");

    blob_handle.reset();
    const data = try blob_handle.readAllAlloc(std.testing.allocator);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqualStrings("hello sqlite-zig", data[0..16]);
}
