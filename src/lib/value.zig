const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const types = @import("types.zig");

pub const FilterArg = struct {
    raw: *c.sqlite3_value,

    pub fn read(self: FilterArg, comptime T: type) errors.Error!T {
        return readCallbackValue(T, self.raw);
    }
};

pub fn readCallbackValue(comptime T: type, raw: *c.sqlite3_value) errors.Error!T {
    if (T == types.TextValue) {
        if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return error.NullValue;
        return .{ .data = readText(raw) };
    }
    if (T == types.BlobValue) {
        if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return error.NullValue;
        return .{ .data = readBlob(raw) };
    }

    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) {
                return null;
            }
            return try readCallbackValue(optional_info.child, raw);
        },
        .bool => {
            if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return error.NullValue;
            return c.sqlite3_value_int(raw) != 0;
        },
        .int => {
            if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return error.NullValue;
            return @intCast(c.sqlite3_value_int64(raw));
        },
        .float => {
            if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return error.NullValue;
            return @floatCast(c.sqlite3_value_double(raw));
        },
        .@"enum" => |enum_info| {
            if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return error.NullValue;
            return @enumFromInt(@as(enum_info.tag_type, @intCast(c.sqlite3_value_int64(raw))));
        },
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return error.NullValue;
                return readText(raw);
            }
            return error.UnsupportedType;
        },
        else => return error.UnsupportedType,
    }
}

pub fn setContextResult(ctx: ?*c.sqlite3_context, value: anytype) void {
    const T = @TypeOf(value);

    if (T == types.TextValue) {
        const slice = value.data;
        c.sqlite3_result_text64(ctx, slice.ptr, slice.len, c.SQLITE_TRANSIENT, c.SQLITE_UTF8);
        return;
    }
    if (T == types.BlobValue) {
        const slice = value.data;
        c.sqlite3_result_blob64(ctx, slice.ptr, slice.len, c.SQLITE_TRANSIENT);
        return;
    }

    switch (@typeInfo(T)) {
        .optional => {
            if (value) |child| {
                setContextResult(ctx, child);
            } else {
                c.sqlite3_result_null(ctx);
            }
        },
        .bool => c.sqlite3_result_int(ctx, if (value) 1 else 0),
        .int, .comptime_int => c.sqlite3_result_int64(ctx, @intCast(value)),
        .float, .comptime_float => c.sqlite3_result_double(ctx, @floatCast(value)),
        .pointer => |pointer_info| {
            if (pointer_info.size == .slice and pointer_info.child == u8) {
                c.sqlite3_result_text64(ctx, value.ptr, value.len, c.SQLITE_TRANSIENT, c.SQLITE_UTF8);
                return;
            }
            @compileError("unsupported SQLite callback result type " ++ @typeName(T));
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                c.sqlite3_result_text64(ctx, value[0..].ptr, value.len, c.SQLITE_TRANSIENT, c.SQLITE_UTF8);
                return;
            }
            @compileError("unsupported SQLite callback result type " ++ @typeName(T));
        },
        .@"enum" => c.sqlite3_result_int64(ctx, @intCast(@intFromEnum(value))),
        else => @compileError("unsupported SQLite callback result type " ++ @typeName(T)),
    }
}

pub fn setContextError(ctx: ?*c.sqlite3_context, message: []const u8) void {
    c.sqlite3_result_error(ctx, message.ptr, @intCast(message.len));
}

fn readText(raw: *c.sqlite3_value) []const u8 {
    const size: usize = @intCast(c.sqlite3_value_bytes(raw));
    if (size == 0) return "";

    const ptr = c.sqlite3_value_text(raw);
    if (ptr == null) return "";
    return ptr[0..size];
}

fn readBlob(raw: *c.sqlite3_value) []const u8 {
    const size: usize = @intCast(c.sqlite3_value_bytes(raw));
    if (size == 0) return "";

    const ptr = c.sqlite3_value_blob(raw);
    if (ptr == null) return "";
    return @as([*]const u8, @ptrCast(ptr))[0..size];
}
