pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("workaround.h");
});

comptime {
    if (c.SQLITE_VERSION_NUMBER < 3_021_000) {
        @compileError("sqlite-zig requires SQLite 3.21.0 or newer");
    }
}

pub inline fn sqliteTransient() c.sqlite3_destructor_type {
    return c.sqliteTransientAsDestructor();
}
