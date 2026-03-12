const c = @import("c.zig").c;

pub const Error = error{
    Abort,
    Busy,
    CantOpen,
    Constraint,
    Corrupt,
    Interrupt,
    InvalidParameter,
    Io,
    Locked,
    Misuse,
    MultipleStatements,
    OutOfMemory,
    NoRow,
    NotFound,
    NullValue,
    PoolClosed,
    Protocol,
    Range,
    ReadOnly,
    TooBig,
    UnknownColumn,
    UnsupportedType,
    Unexpected,
};

pub fn fromCode(result_code: c_int) Error {
    const primary = result_code & 0xff;
    return switch (primary) {
        c.SQLITE_ABORT => error.Abort,
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_IOERR => error.Io,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_NOTFOUND => error.NotFound,
        c.SQLITE_PROTOCOL => error.Protocol,
        c.SQLITE_RANGE => error.Range,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_TOOBIG => error.TooBig,
        else => error.Unexpected,
    };
}

pub fn check(result_code: c_int) Error!void {
    if (result_code != c.SQLITE_OK) {
        return fromCode(result_code);
    }
}
