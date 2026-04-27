# SQLite for Zig

Convenience-first SQLite for Zig.

The goal is to make common database work feel straightforward without turning the library into an ORM. You open a database, execute statements, bind positional or named parameters, map rows into Zig values or structs, and use transactions or a pool when you need them.

## Status

The initial implementation includes:

- in-memory or file-backed databases
- positional and named parameter binding
- typed row decoding into scalars, tuples, and structs
- transactions and savepoints
- a lightweight connection pool
- incremental blob read/write
- scalar and aggregate SQL function registration
- context-aware scalar and aggregate SQL function registration
- virtual table module registration with query planning and writes
- top-level integration and unit tests

## Zig Version

This package targets Zig 0.16.0 and uses build-system C translation instead of source-level `@cImport`.

## SQLite Version

The bundled amalgamation currently targets SQLite 3.53.0. The root module exposes the translated header macros as `sqlite.sqlite_version`, `sqlite.sqlite_version_number`, and `sqlite.sqlite_source_id`, plus runtime verification helpers `sqlite.sqliteVersion()`, `sqlite.sqliteVersionNumber()`, and `sqlite.sqliteSourceId()`.

SQLite 3.53 additions are available through the normal APIs, including `PrepareOptions.from_ddl` for `SQLITE_PREPARE_FROM_DDL` and SQL functions such as `json_array_insert()`.

## Quick Start

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.Db.open(std.heap.page_allocator, .{});
    defer db.deinit();

    try db.exec(
        "create table user(id integer primary key, name text not null, active integer not null)",
        .{},
    );

    try db.exec("insert into user(name, active) values (?, ?)", .{"Ada", true});
    try db.exec("insert into user(name, active) values (:name, :active)", .{
        .name = "Linus",
        .active = false,
    });

    const User = struct {
        id: i64,
        name: []const u8,
        active: bool,
    };

    const users = try db.all(User, "select id, name, active from user order by id", .{});
    defer sqlite.release(std.heap.page_allocator, users);

    for (users) |user| {
        std.debug.print("{d}: {s} active={any}\n", .{ user.id, user.name, user.active });
    }
}
```

## API Shape

`sqlite.Db.open(allocator, options)` opens a connection.

`db.exec(sql, params)` runs statements that do not need returned rows.

`db.one(T, sql, params)` maps a single row into a scalar, tuple, or struct and returns `?T`.

`db.all(T, sql, params)` collects all rows into `[]T`.

`db.query(sql, params)` returns a prepared statement for manual stepping.

`db.transaction(mode)` starts a transaction that rolls back unless committed.

`db.savepoint(name)` starts a savepoint that rolls back unless released.

`sqlite.Pool` manages multiple `Db` connections for concurrent use.

`db.openBlob(table, column, row_id, options)` opens incremental blob I/O.

`db.createScalarFunction(name, func, flags)` registers a Zig function as a SQLite scalar function.

`db.createScalarFunctionWithUserData(name, user_data, func, flags)` registers a scalar function with `sqlite.FunctionContext` access to SQLite and user state.

`db.createAggregateFunction(name, AggregateType, flags)` registers an aggregate implemented as Zig state with `step` and `final`.

`db.createAggregateFunctionWithUserData(name, user_data, step, final, flags)` registers an aggregate using `sqlite.FunctionContext`, including aggregate-local state via `aggregateContext`.

`db.createVirtualTableModule(name, TableType)` registers a Zig-backed virtual table module.

## Blob I/O

```zig
try db.exec("create table files(id integer primary key, data blob not null)", .{});
try db.exec("insert into files(data) values (?)", .{sqlite.ZeroBlob{ .length = 11 }});

var blob = try db.openBlob("files", "data", db.lastInsertRowId(), .{ .write = true });
defer blob.deinit();

try blob.writeAll("hello world");
blob.reset();

const data = try blob.readAllAlloc(std.heap.page_allocator);
defer std.heap.page_allocator.free(data);
```

## SQL Functions

```zig
const add_one = struct {
    fn call(value: i64) i64 {
        return value + 1;
    }
}.call;

try db.createScalarFunction("zig_add_one", add_one, .{});
```

Context-aware scalar functions can opt into `sqlite.FunctionContext` as the first parameter and read caller-provided user state:

```zig
const Scale = struct { factor: i64 };
var scale = Scale{ .factor = 3 };

try db.createScalarFunctionWithUserData(
    "zig_scale",
    &scale,
    struct {
        fn call(ctx: sqlite.FunctionContext, value: i64) i64 {
            const user = ctx.userContext(*Scale) orelse return value;
            return value * user.factor;
        }
    }.call,
    .{},
);
```

Aggregate functions use a Zig state type with `step` and `final`:

```zig
const RunningTotal = struct {
    total: i64 = 0,

    const Self = @This();

    pub fn step(self: *Self, value: i64) void {
        self.total += value;
    }

    pub fn final(self: *Self) i64 {
        return self.total;
    }
};

try db.createAggregateFunction("zig_total", RunningTotal, .{});
```

Context-aware aggregates can also use SQLite-managed aggregate storage directly:

```zig
var multiplier: i64 = 2;

try db.createAggregateFunctionWithUserData(
    "zig_scaled_sum",
    &multiplier,
    struct {
        fn step(ctx: sqlite.FunctionContext, value: i64) void {
            const total = ctx.aggregateContext(*i64) orelse return;
            const factor = ctx.userContext(*i64) orelse return;
            total.* += value * factor.*;
        }
    }.step,
    struct {
        fn final(ctx: sqlite.FunctionContext) i64 {
            return (ctx.aggregateContext(*i64) orelse return 0).*;
        }
    }.final,
    .{},
);
```

## Virtual Tables

Virtual tables support both planner hints and writable tables. A module type needs:

- `pub const schema: [:0]const u8`
- `init(allocator, args)`
- `openCursor(self, allocator)`
- a `Cursor` type with `filter`, `next`, `eof`, `column`, and `rowId`

Optional hooks:

- `bestIndex(self, info: *sqlite.BestIndexInfo)` to inspect constraints and ORDER BY terms, then assign `idxNum`, `idxStr`, argv bindings, costs, and uniqueness flags.
- `update(self, op: sqlite.UpdateOperation) !?i64` to handle `INSERT`, `UPDATE`, and `DELETE`.
- transaction hooks such as `begin`, `commit`, `rollback`, `savepoint`, `release`, and `rollbackTo`.

Cursor `filter` can either keep the simple shape:

- `filter(self, args)`

or accept planner data:

- `filter(self, plan: sqlite.QueryPlan, args)`

See [tests/suite.zig](/d:/github/jassielof/sqlite-zig/tests/suite.zig) for a complete example.

## Ownership

Typed query helpers allocate result memory for strings and slices. Release those values with `sqlite.release(allocator, value)`.

## Tests

Run the full suite with:

```sh
zig build tests
```
