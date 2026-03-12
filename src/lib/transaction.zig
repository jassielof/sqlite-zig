const std = @import("std");
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");

pub const TransactionMode = enum {
    deferred,
    immediate,
    exclusive,
};

pub const Transaction = struct {
    db: *Db,
    completed: bool = false,

    pub fn commit(self: *Transaction) errors.Error!void {
        try self.db.exec("commit", .{});
        self.completed = true;
    }

    pub fn rollback(self: *Transaction) void {
        if (self.completed) return;
        self.db.exec("rollback", .{}) catch {};
        self.completed = true;
    }

    pub fn deinit(self: *Transaction) void {
        self.rollback();
    }
};

pub const Savepoint = struct {
    db: *Db,
    name: []const u8,
    completed: bool = false,

    pub fn commit(self: *Savepoint) errors.Error!void {
        try self.db.execFmt("release savepoint {s}", .{self.name});
        self.completed = true;
    }

    pub fn rollback(self: *Savepoint) void {
        if (self.completed) return;
        self.db.execFmt("rollback to savepoint {s}", .{self.name}) catch {};
        self.db.execFmt("release savepoint {s}", .{self.name}) catch {};
        self.completed = true;
    }

    pub fn deinit(self: *Savepoint) void {
        self.rollback();
    }
};

test "savepoint rolls back by default" {
    var db = try Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec("create table logs(value integer not null)", .{});

    {
        var savepoint = try db.savepoint("test_nested");
        defer savepoint.deinit();

        try db.exec("insert into logs(value) values (?)", .{@as(i64, 5)});
    }

    try std.testing.expectEqual(@as(?i64, null), try db.one(i64, "select value from logs limit 1", .{}));
}
