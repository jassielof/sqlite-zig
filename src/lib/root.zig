//! Convenience-first SQLite library.
//!
//! The library focuses on a small set of high-value workflows:
//!
//! - open a database with sensible defaults
//! - run statements with positional or named parameters
//! - map rows into Zig scalars, tuples, or structs
//! - use transactions, savepoints, and a lightweight connection pool
//!
//! It intentionally stays below ORM or query-builder scope.

const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

pub const BestIndexInfo = @import("vtab.zig").BestIndexInfo;
pub const Blob = @import("blob.zig").Blob;
pub const BlobValue = @import("types.zig").BlobValue;
pub const Constraint = @import("vtab.zig").Constraint;
pub const ConstraintOp = @import("vtab.zig").ConstraintOp;
pub const Db = @import("db.zig").Db;
pub const Error = @import("errors.zig").Error;
pub const FilterArg = @import("vtab.zig").FilterArg;
pub const FunctionContext = @import("function.zig").FunctionContext;
pub const FunctionFlags = @import("function.zig").FunctionFlags;
pub const LastError = @import("db.zig").LastError;
pub const OpenOptions = @import("db.zig").OpenOptions;
pub const OrderBy = @import("vtab.zig").OrderBy;
pub const Pool = @import("pool.zig").Pool;
pub const QueryPlan = @import("vtab.zig").QueryPlan;
pub const release = @import("release.zig").release;
pub const Savepoint = @import("transaction.zig").Savepoint;
pub const Statement = @import("statement.zig").Statement;
pub const TextValue = @import("types.zig").TextValue;
pub const Transaction = @import("transaction.zig").Transaction;
pub const TransactionMode = @import("transaction.zig").TransactionMode;
pub const UpdateKind = @import("vtab.zig").UpdateKind;
pub const UpdateOperation = @import("vtab.zig").UpdateOperation;
pub const ZeroBlob = @import("types.zig").ZeroBlob;

comptime {
    refAllDecls(@This());
}

test "root exports usable API" {
    var db = try Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec("create table ping(value text not null)", .{});
    try db.exec("insert into ping(value) values (?)", .{"pong"});

    const value = (try db.one([]const u8, "select value from ping", .{})).?;
    defer release(std.testing.allocator, value);

    try std.testing.expectEqualStrings("pong", value);
}
