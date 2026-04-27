const std = @import("std");

pub const c = @import("c");
pub const sqlite_version_number = c.SQLITE_VERSION_NUMBER;

pub const minimum_sqlite_version_number = 3_053_000;
pub const sqlite_version = c.SQLITE_VERSION[0..c.SQLITE_VERSION.len];
pub const sqlite_source_id = c.SQLITE_SOURCE_ID[0..c.SQLITE_SOURCE_ID.len];

comptime {
    if (sqlite_version_number < minimum_sqlite_version_number) {
        @compileError("sqlite-zig requires SQLite 3.53.0 or newer");
    }
}

pub fn sqliteVersion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

pub fn sqliteSourceId() []const u8 {
    return std.mem.span(c.sqlite3_sourceid());
}

pub fn sqliteVersionNumber() c_int {
    return c.sqlite3_libversion_number();
}

pub inline fn sqliteTransient() c.sqlite3_destructor_type {
    return c.sqliteTransientAsDestructor();
}

test "SQLite metadata matches translated header" {
    std.debug.print("SQLite version: {s}", .{sqliteVersion()});
    try std.testing.expect(sqliteVersionNumber() >= minimum_sqlite_version_number);
    try std.testing.expectEqual(sqlite_version_number, sqliteVersionNumber());
    try std.testing.expectEqualStrings(sqlite_version, sqliteVersion());
    try std.testing.expectEqualStrings(sqlite_source_id, sqliteSourceId());
}
