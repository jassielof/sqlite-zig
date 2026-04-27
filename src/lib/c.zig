const std = @import("std");

pub const c = @import("c");

comptime {
    if (c.SQLITE_VERSION_NUMBER < 3_053_000) {
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

test "SQLite 3.53 metadata is exposed" {
    try std.testing.expect(sqliteVersionNumber() >= 3_053_000);
    try std.testing.expectEqualStrings("3.53.0", sqliteVersion());
    try std.testing.expect(std.mem.startsWith(u8, sqliteSourceId(), "2026-04-09"));
}
