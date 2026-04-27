const std = @import("std");

const sqlite = @import("sqlite");

comptime {
    std.testing.refAllDecls(@This());
}

test "integration: convenience query flow" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec(
        "create table posts(id integer primary key, title text not null, published integer, views integer)",
        .{},
    );
    try db.exec("insert into posts(title, published, views) values (?, ?, ?)", .{ "Hello", true, 10 });
    try db.exec("insert into posts(title, published, views) values (:title, :published, :views)", .{
        .title = "World",
        .published = false,
        .views = 5,
    });

    const Post = struct {
        id: i64,
        title: []const u8,
        published: bool,
        views: i64,
    };

    const first = (try db.one(Post, "select id, title, published, views from posts where title = ?", .{"Hello"})).?;
    defer sqlite.release(std.testing.allocator, first);
    try std.testing.expectEqualStrings("Hello", first.title);
    try std.testing.expect(first.published);

    const all_posts = try db.all(Post, "select id, title, published, views from posts order by id", .{});
    defer sqlite.release(std.testing.allocator, all_posts);

    try std.testing.expectEqual(@as(usize, 2), all_posts.len);
    try std.testing.expectEqual(@as(i64, 5), all_posts[1].views);
}

test "integration: transaction and savepoint ergonomics" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec("create table entries(value integer not null)", .{});

    {
        var tx = try db.transaction(.immediate);
        defer tx.deinit();

        try db.exec("insert into entries(value) values (?)", .{@as(i64, 1)});
        try db.exec("insert into entries(value) values (?)", .{@as(i64, 2)});
        try tx.commit();
    }

    {
        var savepoint = try db.savepoint("partial_work");
        defer savepoint.deinit();

        try db.exec("insert into entries(value) values (?)", .{@as(i64, 3)});
    }

    const count = (try db.one(i64, "select count(*) from entries", .{})).?;
    try std.testing.expectEqual(@as(i64, 2), count);
}

test "integration: prepared statement manual stepping" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec("create table metrics(name text not null, value integer not null)", .{});
    try db.exec("insert into metrics(name, value) values (?, ?)", .{ "cpu", 80 });
    try db.exec("insert into metrics(name, value) values (?, ?)", .{ "mem", 65 });

    var statement = try db.query("select name, value from metrics order by value desc", .{});
    defer statement.deinit();

    try std.testing.expect(try statement.step());
    const first_name = try statement.read([]const u8, 0, std.testing.allocator);
    defer sqlite.release(std.testing.allocator, first_name);
    try std.testing.expectEqual(@as(i64, 80), try statement.read(i64, 1, std.testing.allocator));
    try std.testing.expectEqualStrings("cpu", first_name);

    try std.testing.expect(try statement.step());
    const second_name = try statement.read([]const u8, 0, std.testing.allocator);
    defer sqlite.release(std.testing.allocator, second_name);
    try std.testing.expectEqualStrings("mem", second_name);

    try std.testing.expect(!(try statement.step()));
}

test "integration: prepare flags include SQLite 3.53 from-ddl mode" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    var statement = try db.prepareWithOptions("select 1", .{ .from_ddl = true });
    defer statement.deinit();

    try std.testing.expect(try statement.step());
    try std.testing.expectEqual(@as(i64, 1), try statement.read(i64, 0, std.testing.allocator));
}

test "integration: SQLite 3.53 json_array_insert is available" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try std.testing.expect(sqlite.sqliteVersionNumber() >= sqlite.minimum_sqlite_version_number);
    try std.testing.expectEqual(sqlite.sqlite_version_number, sqlite.sqliteVersionNumber());

    const value = (try db.one([]const u8, "select json_array_insert(?, '$[1]', ?)", .{ "[1,2,3]", @as(i64, 99) })).?;
    defer sqlite.release(std.testing.allocator, value);

    try std.testing.expectEqualStrings("[1,99,2,3]", value);
}

test "integration: blob streaming round trip" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    try db.exec("create table assets(id integer primary key, data blob not null)", .{});
    try db.exec("insert into assets(data) values (?)", .{sqlite.ZeroBlob{ .length = 11 }});

    const row_id = db.lastInsertRowId();
    var blob = try db.openBlob("assets", "data", row_id, .{ .write = true });
    defer blob.deinit();
    try blob.writeAll("hello world");

    blob.reset();
    const data = try blob.readAllAlloc(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello world", data);
}

test "integration: scalar and aggregate functions" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    const reverse_len = struct {
        fn call(text: []const u8) i64 {
            return @intCast(text.len);
        }
    }.call;

    const RunningTotal = struct {
        const Self = @This();

        total: i64 = 0,

        pub fn step(self: *Self, value: i64) void {
            self.total += value;
        }

        pub fn final(self: *Self) i64 {
            return self.total;
        }
    };

    try db.createScalarFunction("zig_len", reverse_len, .{});
    try db.createAggregateFunction("zig_total", RunningTotal, .{});

    const length = (try db.one(i64, "select zig_len(?)", .{"abcdef"})).?;
    try std.testing.expectEqual(@as(i64, 6), length);

    try db.exec("create table valueset(value integer not null)", .{});
    try db.exec("insert into valueset(value) values (?), (?), (?)", .{ @as(i64, 1), @as(i64, 2), @as(i64, 3) });
    const total = (try db.one(i64, "select zig_total(value) from valueset", .{})).?;
    try std.testing.expectEqual(@as(i64, 6), total);
}

test "integration: context-aware SQL functions" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    const Scale = struct {
        factor: i64,
    };

    var scale = Scale{ .factor = 3 };
    var aggregate_factor: i64 = 2;

    try db.createScalarFunctionWithUserData(
        "zig_scale",
        &scale,
        struct {
            fn call(ctx: sqlite.FunctionContext, value: i64) i64 {
                const scale_ptr = ctx.userContext(*Scale) orelse return value;
                return value * scale_ptr.factor;
            }
        }.call,
        .{},
    );

    try db.createAggregateFunctionWithUserData(
        "zig_scaled_sum",
        &aggregate_factor,
        struct {
            fn step(ctx: sqlite.FunctionContext, value: i64) void {
                const total = ctx.aggregateContext(*i64) orelse return;
                const factor = ctx.userContext(*i64) orelse return;
                total.* += value * factor.*;
            }
        }.step,
        struct {
            fn final(ctx: sqlite.FunctionContext) i64 {
                const total = ctx.aggregateContext(*i64) orelse return 0;
                return total.*;
            }
        }.final,
        .{},
    );

    const scaled = (try db.one(i64, "select zig_scale(?)", .{@as(i64, 4)})).?;
    try std.testing.expectEqual(@as(i64, 12), scaled);

    try db.exec("create table valuebag(value integer not null)", .{});
    try db.exec("insert into valuebag(value) values (?), (?), (?)", .{ @as(i64, 1), @as(i64, 2), @as(i64, 3) });

    const scaled_total = (try db.one(i64, "select zig_scaled_sum(value) from valuebag", .{})).?;
    try std.testing.expectEqual(@as(i64, 12), scaled_total);
}

test "integration: virtual table module" {
    var db = try sqlite.Db.open(std.testing.allocator, .{});
    defer db.deinit();

    const NumbersTable = struct {
        const Self = @This();

        const Row = struct {
            rowid: i64,
            value: i64,
        };

        pub const schema: [:0]const u8 = "create table x(value integer)";
        pub const Cursor = struct {
            const CursorSelf = @This();

            table: *Self,
            current_index: usize = 0,
            eq_value: ?i64 = null,

            pub fn filter(self: *CursorSelf, plan: sqlite.QueryPlan, args: []const sqlite.FilterArg) !void {
                self.current_index = 0;
                self.eq_value = null;

                if (plan.index_number == 1 and args.len > 0) {
                    self.eq_value = try args[0].read(i64);
                }

                self.seekToMatch();
            }

            pub fn next(self: *CursorSelf) !void {
                self.current_index += 1;
                self.seekToMatch();
            }

            pub fn eof(self: *const CursorSelf) bool {
                return self.current_index >= self.table.rows.items.len;
            }

            pub fn column(self: *const CursorSelf, index: usize) !i64 {
                _ = index;
                return self.table.rows.items[self.current_index].value;
            }

            pub fn rowId(self: *const CursorSelf) !i64 {
                return self.table.rows.items[self.current_index].rowid;
            }

            fn seekToMatch(self: *CursorSelf) void {
                while (self.current_index < self.table.rows.items.len) : (self.current_index += 1) {
                    const row = self.table.rows.items[self.current_index];
                    if (self.eq_value == null or row.value == self.eq_value.?) {
                        return;
                    }
                }
            }
        };

        allocator: std.mem.Allocator,
        rows: std.ArrayList(Row),
        next_rowid: i64,

        pub fn init(allocator: std.mem.Allocator, args: [][]const u8) !Self {
            var table = Self{
                .allocator = allocator,
                .rows = .empty,
                .next_rowid = 1,
            };

            for (args) |arg| {
                const parsed = try std.fmt.parseInt(i64, arg, 10);
                _ = try table.insertRow(null, parsed);
            }

            return table;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            self.rows.deinit(self.allocator);
        }

        pub fn bestIndex(self: *Self, info: *sqlite.BestIndexInfo) !void {
            info.setEstimatedCost(@floatFromInt(@max(self.rows.items.len, 1)));
            info.setEstimatedRows(@intCast(@max(self.rows.items.len, 1)));

            var index: usize = 0;
            while (index < info.constraintCount()) : (index += 1) {
                const constraint = info.constraint(index);
                if (!constraint.usable) continue;
                if (constraint.column == 0 and constraint.op == .eq) {
                    info.setConstraintUsage(index, 0, true);
                    info.setIndexNumber(1);
                    try info.setIndexString("value_eq");
                    info.setEstimatedCost(1.0);
                    info.setEstimatedRows(1);
                    info.setUnique(true);
                    return;
                }
            }
        }

        pub fn openCursor(self: *Self, allocator: std.mem.Allocator) !Cursor {
            _ = allocator;
            return .{ .table = self };
        }

        pub fn update(self: *Self, operation: sqlite.UpdateOperation) !?i64 {
            switch (operation.kind) {
                .insert => {
                    const rowid = operation.new_rowid orelse self.next_rowid;
                    const value = try operation.column(0).read(i64);
                    return try self.insertRow(rowid, value);
                },
                .update => {
                    const rowid = operation.old_rowid orelse return error.InvalidParameter;
                    const row_index = self.rowIndexFor(rowid) orelse return error.NotFound;
                    self.rows.items[row_index].rowid = operation.new_rowid orelse rowid;
                    self.rows.items[row_index].value = try operation.column(0).read(i64);
                    return null;
                },
                .delete => {
                    const rowid = operation.old_rowid orelse return error.InvalidParameter;
                    const row_index = self.rowIndexFor(rowid) orelse return error.NotFound;
                    _ = self.rows.orderedRemove(row_index);
                    return null;
                },
            }
        }

        fn insertRow(self: *Self, desired_rowid: ?i64, row_value: i64) !i64 {
            const rowid = desired_rowid orelse self.next_rowid;
            try self.rows.append(self.allocator, .{
                .rowid = rowid,
                .value = row_value,
            });

            if (rowid >= self.next_rowid) {
                self.next_rowid = rowid + 1;
            }

            return rowid;
        }

        fn rowIndexFor(self: *Self, rowid: i64) ?usize {
            for (self.rows.items, 0..) |row, index| {
                if (row.rowid == rowid) return index;
            }
            return null;
        }
    };

    try db.createVirtualTableModule("zig_numbers", NumbersTable);
    try db.exec("create virtual table temp.numbers using zig_numbers(10, 20, 30)", .{});

    try db.exec("insert into numbers(value) values (?)", .{@as(i64, 40)});
    try db.exec("update numbers set value = ? where rowid = ?", .{ @as(i64, 15), @as(i64, 1) });
    try db.exec("delete from numbers where rowid = ?", .{@as(i64, 2)});

    const values = try db.all(i64, "select value from numbers order by value", .{});
    defer sqlite.release(std.testing.allocator, values);

    const ExplainPlan = struct {
        detail: []const u8,
    };

    const explain = (try db.one(ExplainPlan, "explain query plan select value from numbers where value = ?", .{@as(i64, 30)})).?;
    defer sqlite.release(std.testing.allocator, explain);

    try std.testing.expect(std.mem.find(u8, explain.detail, "VIRTUAL TABLE INDEX 1") != null);
    try std.testing.expectEqualSlices(i64, &.{ 15, 30, 40 }, values);

    const matched = try db.all(i64, "select value from numbers where value = ?", .{@as(i64, 30)});
    defer sqlite.release(std.testing.allocator, matched);
    try std.testing.expectEqualSlices(i64, &.{30}, matched);
}
