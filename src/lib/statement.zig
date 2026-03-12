const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const types = @import("types.zig");

pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    db_handle: *c.sqlite3,

    pub fn prepare(db_handle: *c.sqlite3, sql: []const u8) errors.Error!Statement {
        var handle: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;

        const result = c.sqlite3_prepare_v2(
            db_handle,
            sql.ptr,
            @intCast(sql.len),
            &handle,
            &tail,
        );
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }
        errdefer _ = c.sqlite3_finalize(handle);

        if (hasTrailingSql(sql, tail)) {
            return error.MultipleStatements;
        }

        return .{
            .handle = handle.?,
            .db_handle = db_handle,
        };
    }

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn step(self: *Statement) errors.Error!bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |result| errors.fromCode(result),
        };
    }

    pub fn execute(self: *Statement) errors.Error!void {
        while (true) {
            if (!try self.step()) return;
        }
    }

    pub fn reset(self: *Statement) errors.Error!void {
        const result = c.sqlite3_reset(self.handle);
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }
    }

    pub fn clearBindings(self: *Statement) errors.Error!void {
        const result = c.sqlite3_clear_bindings(self.handle);
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }
    }

    pub fn bind(self: *Statement, params: anytype) errors.Error!void {
        const Params = @TypeOf(params);
        switch (@typeInfo(Params)) {
            .@"struct" => |struct_info| {
                if (struct_info.is_tuple) {
                    inline for (params, 0..) |value, index| {
                        try bindValue(self.handle, @intCast(index + 1), value);
                    }
                    return;
                }

                if (struct_info.fields.len == 0) {
                    return;
                }

                inline for (struct_info.fields) |field| {
                    const field_value = @field(params, field.name);
                    const index = try parameterIndex(self.handle, field.name);
                    try bindValue(self.handle, index, field_value);
                }
            },
            else => try bindValue(self.handle, 1, params),
        }
    }

    pub fn columnCount(self: *const Statement) usize {
        return @intCast(c.sqlite3_column_count(self.handle));
    }

    pub fn parameterCount(self: *const Statement) usize {
        return @intCast(c.sqlite3_bind_parameter_count(self.handle));
    }

    pub fn isNull(self: *const Statement, index: usize) bool {
        return c.sqlite3_column_type(self.handle, @intCast(index)) == c.SQLITE_NULL;
    }

    pub fn columnName(self: *const Statement, index: usize) []const u8 {
        const raw = c.sqlite3_column_name(self.handle, @intCast(index));
        return std.mem.span(raw);
    }

    pub fn columnInt(self: *const Statement, index: usize) i64 {
        return @intCast(c.sqlite3_column_int64(self.handle, @intCast(index)));
    }

    pub fn columnFloat(self: *const Statement, index: usize) f64 {
        return @floatCast(c.sqlite3_column_double(self.handle, @intCast(index)));
    }

    pub fn columnBool(self: *const Statement, index: usize) bool {
        return self.columnInt(index) != 0;
    }

    pub fn columnBytes(self: *const Statement, index: usize) []const u8 {
        const c_index: c_int = @intCast(index);
        const size = c.sqlite3_column_bytes(self.handle, c_index);
        if (size == 0) {
            return "";
        }

        const raw = c.sqlite3_column_blob(self.handle, c_index);
        if (raw == null) {
            return "";
        }

        const ptr: [*]const u8 = @ptrCast(raw);
        return ptr[0..@intCast(size)];
    }

    pub fn columnText(self: *const Statement, index: usize) []const u8 {
        return self.columnBytes(index);
    }

    pub fn read(self: *const Statement, comptime T: type, index: usize, allocator: std.mem.Allocator) errors.Error!T {
        return readValue(self, T, index, allocator);
    }

    pub fn row(self: *const Statement, comptime T: type, allocator: std.mem.Allocator) errors.Error!T {
        return readRow(self, T, allocator);
    }

    fn hasTrailingSql(sql: []const u8, tail: [*c]const u8) bool {
        const base_addr = @intFromPtr(sql.ptr);
        const tail_addr = @intFromPtr(tail);
        if (tail_addr < base_addr) {
            return false;
        }

        const offset = tail_addr - base_addr;
        if (offset >= sql.len) {
            return false;
        }

        return std.mem.trim(u8, sql[offset..], " \t\r\n").len > 0;
    }
};

fn bindValue(handle: *c.sqlite3_stmt, index: c_int, value: anytype) errors.Error!void {
    const T = @TypeOf(value);

    if (T == types.TextValue) {
        try bindText(handle, index, value.data);
        return;
    }
    if (T == types.BlobValue) {
        try bindBlob(handle, index, value.data);
        return;
    }
    if (T == types.ZeroBlob) {
        const result = c.sqlite3_bind_zeroblob64(handle, index, value.length);
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }
        return;
    }

    switch (@typeInfo(T)) {
        .optional => {
            if (value) |child| {
                try bindValue(handle, index, child);
            } else {
                const result = c.sqlite3_bind_null(handle, index);
                if (result != c.SQLITE_OK) {
                    return errors.fromCode(result);
                }
            }
        },
        .bool => {
            const result = c.sqlite3_bind_int(handle, index, if (value) 1 else 0);
            if (result != c.SQLITE_OK) {
                return errors.fromCode(result);
            }
        },
        .int, .comptime_int => {
            const result = c.sqlite3_bind_int64(handle, index, @intCast(value));
            if (result != c.SQLITE_OK) {
                return errors.fromCode(result);
            }
        },
        .float, .comptime_float => {
            const result = c.sqlite3_bind_double(handle, index, @floatCast(value));
            if (result != c.SQLITE_OK) {
                return errors.fromCode(result);
            }
        },
        .enum_literal => return error.UnsupportedType,
        .@"enum" => {
            try bindValue(handle, index, @intFromEnum(value));
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                try bindText(handle, index, value);
                return;
            }

            if (pointer_info.size == .one) {
                switch (@typeInfo(pointer_info.child)) {
                    .array => |array_info| {
                        if (array_info.child == u8) {
                            try bindText(handle, index, value[0..]);
                            return;
                        }
                    },
                    else => {},
                }
            }

            return error.UnsupportedType;
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                try bindText(handle, index, value[0..]);
                return;
            }
            return error.UnsupportedType;
        },
        else => return error.UnsupportedType,
    }
}

fn bindText(handle: *c.sqlite3_stmt, index: c_int, data: []const u8) errors.Error!void {
    const result = c.sqlite3_bind_text64(
        handle,
        index,
        data.ptr,
        data.len,
        c.SQLITE_TRANSIENT,
        c.SQLITE_UTF8,
    );
    if (result != c.SQLITE_OK) {
        return errors.fromCode(result);
    }
}

fn bindBlob(handle: *c.sqlite3_stmt, index: c_int, data: []const u8) errors.Error!void {
    const result = c.sqlite3_bind_blob64(
        handle,
        index,
        data.ptr,
        data.len,
        c.SQLITE_TRANSIENT,
    );
    if (result != c.SQLITE_OK) {
        return errors.fromCode(result);
    }
}

fn parameterIndex(handle: *c.sqlite3_stmt, comptime name: []const u8) errors.Error!c_int {
    inline for (.{ ':', '@', '$' }) |prefix| {
        var buffer: [name.len + 2]u8 = undefined;
        buffer[0] = prefix;
        @memcpy(buffer[1 .. name.len + 1], name);
        buffer[name.len + 1] = 0;

        const index = c.sqlite3_bind_parameter_index(handle, @ptrCast(&buffer));
        if (index != 0) {
            return index;
        }
    }

    return error.InvalidParameter;
}

fn readRow(statement: *const Statement, comptime T: type, allocator: std.mem.Allocator) errors.Error!T {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                var result: T = undefined;
                inline for (struct_info.fields, 0..) |field, index| {
                    @field(result, field.name) = try readValue(statement, field.type, index, allocator);
                }
                return result;
            }

            var result: T = undefined;
            inline for (struct_info.fields) |field| {
                const index = findColumnIndex(statement, field.name) orelse return error.UnknownColumn;
                @field(result, field.name) = try readValue(statement, field.type, index, allocator);
            }
            return result;
        },
        else => return readValue(statement, T, 0, allocator),
    }
}

fn readValue(statement: *const Statement, comptime T: type, index: usize, allocator: std.mem.Allocator) errors.Error!T {
    if (T == types.TextValue) {
        return .{ .data = try allocator.dupe(u8, statement.columnText(index)) };
    }
    if (T == types.BlobValue) {
        return .{ .data = try allocator.dupe(u8, statement.columnBytes(index)) };
    }

    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            if (statement.isNull(index)) {
                return null;
            }
            return try readValue(statement, optional_info.child, index, allocator);
        },
        .bool => {
            if (statement.isNull(index)) return error.NullValue;
            return statement.columnBool(index);
        },
        .int => {
            if (statement.isNull(index)) return error.NullValue;
            return @intCast(statement.columnInt(index));
        },
        .float => {
            if (statement.isNull(index)) return error.NullValue;
            return @floatCast(statement.columnFloat(index));
        },
        .@"enum" => |enum_info| {
            if (statement.isNull(index)) return error.NullValue;
            return @enumFromInt(@as(enum_info.tag_type, @intCast(statement.columnInt(index))));
        },
        .pointer => |pointer_info| {
            if (pointer_info.size != .slice or pointer_info.child != u8) {
                return error.UnsupportedType;
            }
            if (statement.isNull(index)) return error.NullValue;
            return try allocator.dupe(u8, statement.columnBytes(index));
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                var result: T = undefined;
                inline for (struct_info.fields, 0..) |field, tuple_index| {
                    @field(result, field.name) = try readValue(statement, field.type, tuple_index, allocator);
                }
                return result;
            }

            var result: T = undefined;
            inline for (struct_info.fields) |field| {
                const field_index = findColumnIndex(statement, field.name) orelse return error.UnknownColumn;
                @field(result, field.name) = try readValue(statement, field.type, field_index, allocator);
            }
            return result;
        },
        else => return error.UnsupportedType,
    }
}

fn findColumnIndex(statement: *const Statement, comptime name: []const u8) ?usize {
    for (0..statement.columnCount()) |index| {
        if (std.mem.eql(u8, statement.columnName(index), name)) {
            return index;
        }
    }
    return null;
}

test "statement supports named and positional parameters" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec("create table items(id integer primary key, name text not null)", .{});
    try db.exec("insert into items(name) values (?)", .{"first"});
    try db.exec("insert into items(name) values (:name)", .{ .name = "second" });

    const Item = struct { id: i64, name: []const u8 };
    const item = (try db.one(Item, "select id, name from items where name = :name", .{ .name = "second" })).?;
    defer @import("release.zig").release(std.testing.allocator, item);

    try std.testing.expectEqual(@as(i64, 2), item.id);
    try std.testing.expectEqualStrings("second", item.name);
}
