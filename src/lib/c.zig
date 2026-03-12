pub const c = @cImport({
    @cInclude("sqlite3.h");
});

comptime {
    if (c.SQLITE_VERSION_NUMBER < 3_021_000) {
        @compileError("sqlite-zig requires SQLite 3.21.0 or newer");
    }
}
