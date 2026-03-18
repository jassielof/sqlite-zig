const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const value = @import("value.zig");

/// A virtual table argument passed to `Cursor.filter` or `Table.update`.
pub const FilterArg = value.FilterArg;

/// SQLite WHERE-clause operator kinds reported to `bestIndex`.
pub const ConstraintOp = enum(u8) {
    eq = c.SQLITE_INDEX_CONSTRAINT_EQ,
    gt = c.SQLITE_INDEX_CONSTRAINT_GT,
    le = c.SQLITE_INDEX_CONSTRAINT_LE,
    lt = c.SQLITE_INDEX_CONSTRAINT_LT,
    ge = c.SQLITE_INDEX_CONSTRAINT_GE,
    match = c.SQLITE_INDEX_CONSTRAINT_MATCH,
    like = c.SQLITE_INDEX_CONSTRAINT_LIKE,
    glob = c.SQLITE_INDEX_CONSTRAINT_GLOB,
    regexp = c.SQLITE_INDEX_CONSTRAINT_REGEXP,
    ne = c.SQLITE_INDEX_CONSTRAINT_NE,
    is_not = c.SQLITE_INDEX_CONSTRAINT_ISNOT,
    is_not_null = c.SQLITE_INDEX_CONSTRAINT_ISNOTNULL,
    is_null = c.SQLITE_INDEX_CONSTRAINT_ISNULL,
    is_ = c.SQLITE_INDEX_CONSTRAINT_IS,
    limit = c.SQLITE_INDEX_CONSTRAINT_LIMIT,
    offset = c.SQLITE_INDEX_CONSTRAINT_OFFSET,
    function = c.SQLITE_INDEX_CONSTRAINT_FUNCTION,

    fn fromC(op: u8) ConstraintOp {
        return switch (op) {
            c.SQLITE_INDEX_CONSTRAINT_EQ => .eq,
            c.SQLITE_INDEX_CONSTRAINT_GT => .gt,
            c.SQLITE_INDEX_CONSTRAINT_LE => .le,
            c.SQLITE_INDEX_CONSTRAINT_LT => .lt,
            c.SQLITE_INDEX_CONSTRAINT_GE => .ge,
            c.SQLITE_INDEX_CONSTRAINT_MATCH => .match,
            c.SQLITE_INDEX_CONSTRAINT_LIKE => .like,
            c.SQLITE_INDEX_CONSTRAINT_GLOB => .glob,
            c.SQLITE_INDEX_CONSTRAINT_REGEXP => .regexp,
            c.SQLITE_INDEX_CONSTRAINT_NE => .ne,
            c.SQLITE_INDEX_CONSTRAINT_ISNOT => .is_not,
            c.SQLITE_INDEX_CONSTRAINT_ISNOTNULL => .is_not_null,
            c.SQLITE_INDEX_CONSTRAINT_ISNULL => .is_null,
            c.SQLITE_INDEX_CONSTRAINT_IS => .is_,
            c.SQLITE_INDEX_CONSTRAINT_LIMIT => .limit,
            c.SQLITE_INDEX_CONSTRAINT_OFFSET => .offset,
            else => .function,
        };
    }
};

/// A single WHERE-clause constraint visible to `bestIndex`.
pub const Constraint = struct {
    column: i32,
    op: ConstraintOp,
    usable: bool,
};

/// A single ORDER BY term visible to `bestIndex`.
pub const OrderBy = struct {
    column: i32,
    desc: bool,
};

/// The query plan data chosen in `bestIndex` and later provided to `Cursor.filter`.
pub const QueryPlan = struct {
    index_number: i32 = 0,
    index_string: ?[]const u8 = null,
};

/// The kind of write operation requested for a virtual table.
pub const UpdateKind = enum {
    delete,
    insert,
    update,
};

/// A write request delivered to `Table.update`.
///
/// For inserts, `old_rowid` is null. For deletes, `columns` is empty.
pub const UpdateOperation = struct {
    kind: UpdateKind,
    old_rowid: ?i64,
    new_rowid: ?i64,
    columns: []const FilterArg,

    /// Returns the value assigned to a declared virtual-table column.
    pub fn column(self: UpdateOperation, index: usize) FilterArg {
        return self.columns[index];
    }
};

/// Mutable planner state passed to `Table.bestIndex`.
///
/// This wraps `sqlite3_index_info` and exposes the parts most virtual tables
/// need when deciding constraint usage, index identifiers, and scan costs.
pub const BestIndexInfo = struct {
    raw: *c.sqlite3_index_info,

    /// Returns the number of available WHERE-clause constraints.
    pub fn constraintCount(self: BestIndexInfo) usize {
        return @intCast(self.raw.nConstraint);
    }

    /// Returns a specific WHERE-clause constraint.
    pub fn constraint(self: BestIndexInfo, index: usize) Constraint {
        const raw_constraint = self.raw.aConstraint[index];
        return .{
            .column = raw_constraint.iColumn,
            .op = ConstraintOp.fromC(raw_constraint.op),
            .usable = raw_constraint.usable != 0,
        };
    }

    /// Returns the number of ORDER BY terms that SQLite would like satisfied.
    pub fn orderByCount(self: BestIndexInfo) usize {
        return @intCast(self.raw.nOrderBy);
    }

    /// Returns a specific ORDER BY term.
    pub fn orderBy(self: BestIndexInfo, index: usize) OrderBy {
        const raw_order = self.raw.aOrderBy[index];
        return .{
            .column = raw_order.iColumn,
            .desc = raw_order.desc != 0,
        };
    }

    /// Marks whether a constraint should be forwarded to `Cursor.filter`.
    ///
    /// `argv_index` is zero-based here and is converted to SQLite's one-based
    /// `argvIndex` convention internally.
    pub fn setConstraintUsage(self: BestIndexInfo, constraint_index: usize, argv_index: ?usize, omit: bool) void {
        self.raw.aConstraintUsage[constraint_index].argvIndex = if (argv_index) |index| @intCast(index + 1) else 0;
        self.raw.aConstraintUsage[constraint_index].omit = if (omit) 1 else 0;
    }

    /// Sets the integer plan identifier passed back to `Cursor.filter`.
    pub fn setIndexNumber(self: BestIndexInfo, index_number: i32) void {
        self.raw.idxNum = @intCast(index_number);
    }

    /// Sets the string plan identifier passed back to `Cursor.filter`.
    ///
    /// The string is copied into SQLite-managed memory.
    pub fn setIndexString(self: BestIndexInfo, index_string: ?[]const u8) errors.Error!void {
        if (self.raw.needToFreeIdxStr != 0 and self.raw.idxStr != null) {
            c.sqlite3_free(self.raw.idxStr);
        }

        if (index_string) |text| {
            const raw_text = c.sqlite3_malloc64(text.len + 1) orelse return error.OutOfMemory;
            const bytes: [*]u8 = @ptrCast(raw_text);
            @memcpy(bytes[0..text.len], text);
            bytes[text.len] = 0;
            self.raw.idxStr = @ptrCast(raw_text);
            self.raw.needToFreeIdxStr = 1;
        } else {
            self.raw.idxStr = null;
            self.raw.needToFreeIdxStr = 0;
        }
    }

    /// Declares that the cursor output already satisfies the requested ORDER BY.
    pub fn setOrderByConsumed(self: BestIndexInfo, consumed: bool) void {
        self.raw.orderByConsumed = if (consumed) 1 else 0;
    }

    /// Sets the planner cost estimate for the selected strategy.
    pub fn setEstimatedCost(self: BestIndexInfo, cost: f64) void {
        self.raw.estimatedCost = cost;
    }

    /// Sets the estimated number of rows for the selected strategy.
    pub fn setEstimatedRows(self: BestIndexInfo, rows: i64) void {
        if (@hasField(c.sqlite3_index_info, "estimatedRows")) {
            self.raw.estimatedRows = rows;
        }
    }

    /// Marks whether the selected strategy can return at most one row.
    pub fn setUnique(self: BestIndexInfo, unique: bool) void {
        if (@hasField(c.sqlite3_index_info, "idxFlags")) {
            if (unique) {
                self.raw.idxFlags |= c.SQLITE_INDEX_SCAN_UNIQUE;
            } else {
                self.raw.idxFlags &= ~@as(c_int, c.SQLITE_INDEX_SCAN_UNIQUE);
            }
        }
    }

    /// Requests hex formatting for `idxNum` in `EXPLAIN QUERY PLAN` output.
    pub fn setExplainIndexAsHex(self: BestIndexInfo, enabled: bool) void {
        if (@hasField(c.sqlite3_index_info, "idxFlags")) {
            if (enabled) {
                self.raw.idxFlags |= c.SQLITE_INDEX_SCAN_HEX;
            } else {
                self.raw.idxFlags &= ~@as(c_int, c.SQLITE_INDEX_SCAN_HEX);
            }
        }
    }

    /// Returns the bitmask of columns that may be required by the query.
    pub fn colUsed(self: BestIndexInfo) u64 {
        if (@hasField(c.sqlite3_index_info, "colUsed")) {
            return self.raw.colUsed;
        }
        return std.math.maxInt(u64);
    }

    fn setDefaults(self: BestIndexInfo) void {
        self.setIndexNumber(0);
        self.raw.idxStr = null;
        self.raw.needToFreeIdxStr = 0;
        self.setOrderByConsumed(false);
        self.setEstimatedCost(1_000_000.0);
        self.setEstimatedRows(1_000_000);
        if (@hasField(c.sqlite3_index_info, "idxFlags")) {
            self.raw.idxFlags = 0;
        }
    }
};

/// Registers a virtual table module on a single database connection.
///
/// `Table` must define `schema`, `Cursor`, `init`, and `openCursor`. Optional
/// hooks include `bestIndex`, `update`, and transaction lifecycle methods such
/// as `begin`, `commit`, `rollback`, and savepoint handlers.
pub fn createModule(db_handle: *c.sqlite3, allocator: std.mem.Allocator, comptime name: []const u8, comptime Table: type) errors.Error!void {
    if (!@hasDecl(Table, "schema")) @compileError("virtual table type must define `pub const schema: [:0]const u8`");
    if (!@hasDecl(Table, "Cursor")) @compileError("virtual table type must define `pub const Cursor`");
    if (!@hasDecl(Table, "init")) @compileError("virtual table type must define `init(allocator, args)`");
    if (!@hasDecl(Table, "openCursor")) @compileError("virtual table type must define `openCursor(self, allocator)`");

    const Cursor = Table.Cursor;
    const schema = @field(Table, "schema");

    const ModuleContext = struct {
        allocator: std.mem.Allocator,
    };

    const State = struct {
        const Self = @This();

        vtab: c.sqlite3_vtab = std.mem.zeroes(c.sqlite3_vtab),
        allocator: std.mem.Allocator,
        table: Table,

        fn deinit(self: *Self) void {
            if (@hasDecl(Table, "deinit")) {
                self.table.deinit(self.allocator);
            }
            self.allocator.destroy(self);
        }
    };

    const CursorState = struct {
        const Self = @This();

        vtab_cursor: c.sqlite3_vtab_cursor = std.mem.zeroes(c.sqlite3_vtab_cursor),
        allocator: std.mem.Allocator,
        state: *State,
        cursor: Cursor,

        fn deinit(self: *Self) void {
            if (@hasDecl(Cursor, "deinit")) {
                self.cursor.deinit(self.allocator);
            }
            self.allocator.destroy(self);
        }
    };

    const Wrapper = struct {
        fn getContext(raw: ?*anyopaque) *ModuleContext {
            return @ptrCast(@alignCast(raw.?));
        }

        fn getState(vtab: [*c]c.sqlite3_vtab) *State {
            const raw_state: *allowzero State = @fieldParentPtr("vtab", vtab);
            return @ptrCast(raw_state);
        }

        fn getCursorState(vtab_cursor: [*c]c.sqlite3_vtab_cursor) *CursorState {
            const raw_cursor_state: *allowzero CursorState = @fieldParentPtr("vtab_cursor", vtab_cursor);
            return @ptrCast(raw_cursor_state);
        }

        fn allocError(message: []const u8) ?[*c]u8 {
            const raw = c.sqlite3_malloc64(message.len + 1) orelse return null;
            const bytes: [*]u8 = @ptrCast(raw);
            @memcpy(bytes[0..message.len], message);
            bytes[message.len] = 0;
            return @ptrCast(raw);
        }

        fn setVtabError(vtab: *c.sqlite3_vtab, err: anyerror) void {
            if (allocError(@errorName(err))) |message| {
                vtab.zErrMsg = message;
            }
        }

        fn parseArgs(alloc: std.mem.Allocator, argc: c_int, argv: [*c]const [*c]const u8) ![][]const u8 {
            const count: usize = @intCast(if (argc > 3) argc - 3 else 0);
            var args = try alloc.alloc([]const u8, count);
            for (0..count) |index| {
                args[index] = std.mem.span(argv[index + 3]);
            }
            return args;
        }

        fn resultCodeFromError(err: anyerror) c_int {
            return switch (err) {
                error.Abort => c.SQLITE_ABORT,
                error.Busy => c.SQLITE_BUSY,
                error.Constraint => c.SQLITE_CONSTRAINT,
                error.Interrupt => c.SQLITE_INTERRUPT,
                error.Locked => c.SQLITE_LOCKED,
                error.OutOfMemory => c.SQLITE_NOMEM,
                error.ReadOnly => c.SQLITE_READONLY,
                error.TooBig => c.SQLITE_TOOBIG,
                else => c.SQLITE_ERROR,
            };
        }

        fn createState(db: ?*c.sqlite3, module_ctx: *ModuleContext, argc: c_int, argv: [*c]const [*c]const u8, out_vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]u8) c_int {
            var arena = std.heap.ArenaAllocator.init(module_ctx.allocator);
            defer arena.deinit();

            const args = parseArgs(arena.allocator(), argc, argv) catch {
                if (allocError("sqlite-zig virtual table args allocation failed")) |message| {
                    err_str.* = message;
                }
                return c.SQLITE_NOMEM;
            };

            var state = module_ctx.allocator.create(State) catch {
                if (allocError("sqlite-zig virtual table allocation failed")) |message| {
                    err_str.* = message;
                }
                return c.SQLITE_NOMEM;
            };
            errdefer module_ctx.allocator.destroy(state);

            const table = Table.init(module_ctx.allocator, args) catch |err| {
                if (allocError(@errorName(err))) |message| {
                    err_str.* = message;
                }
                return resultCodeFromError(err);
            };

            state.* = .{
                .allocator = module_ctx.allocator,
                .table = table,
            };
            out_vtab.* = @ptrCast(state);

            const declare_result = c.sqlite3_declare_vtab(db, schema.ptr);
            if (declare_result != c.SQLITE_OK) {
                state.deinit();
                if (allocError("sqlite-zig virtual table schema declaration failed")) |message| {
                    err_str.* = message;
                }
                return declare_result;
            }

            return c.SQLITE_OK;
        }

        fn invokeFilter(cursor_state: *CursorState, plan: QueryPlan, args: []const FilterArg) anyerror!void {
            const filter_info = @typeInfo(@TypeOf(Cursor.filter)).@"fn";

            if (filter_info.params.len == 2) {
                try cursor_state.cursor.filter(args);
                return;
            }
            if (filter_info.params.len == 3 and filter_info.params[1].type.? == QueryPlan) {
                try cursor_state.cursor.filter(plan, args);
                return;
            }

            @compileError("virtual table cursor filter must be filter(self, args) or filter(self, plan, args)");
        }

        fn readOptionalRowId(raw: *c.sqlite3_value) errors.Error!?i64 {
            if (c.sqlite3_value_type(raw) == c.SQLITE_NULL) return null;
            return try value.readCallbackValue(i64, raw);
        }

        fn invokeTableNoArg(state: *State, comptime method_name: []const u8) anyerror!void {
            if (@hasDecl(Table, method_name)) {
                try @field(state.table, method_name)();
            }
        }

        fn xCreate(db: ?*c.sqlite3, raw_ctx: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, out_vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]u8) callconv(.c) c_int {
            return createState(db, getContext(raw_ctx), argc, argv, out_vtab, err_str);
        }

        fn xConnect(db: ?*c.sqlite3, raw_ctx: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, out_vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]u8) callconv(.c) c_int {
            return createState(db, getContext(raw_ctx), argc, argv, out_vtab, err_str);
        }

        fn xBestIndex(vtab: [*c]c.sqlite3_vtab, index_info: [*c]c.sqlite3_index_info) callconv(.c) c_int {
            const state = getState(vtab);
            var info = BestIndexInfo{ .raw = index_info };
            info.setDefaults();

            if (@hasDecl(Table, "bestIndex")) {
                state.table.bestIndex(&info) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                };
            }

            return c.SQLITE_OK;
        }

        fn xDisconnect(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            const state = getState(vtab);
            state.deinit();
            return c.SQLITE_OK;
        }

        fn xDestroy(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            return xDisconnect(vtab);
        }

        fn xOpen(vtab: [*c]c.sqlite3_vtab, out_cursor: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const state = getState(vtab);
            const cursor_state = state.allocator.create(CursorState) catch return c.SQLITE_NOMEM;
            errdefer state.allocator.destroy(cursor_state);

            const cursor = state.table.openCursor(state.allocator) catch |err| {
                return resultCodeFromError(err);
            };
            cursor_state.* = .{
                .allocator = state.allocator,
                .state = state,
                .cursor = cursor,
            };
            out_cursor.* = @ptrCast(cursor_state);
            return c.SQLITE_OK;
        }

        fn xClose(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const cursor_state = getCursorState(vtab_cursor);
            cursor_state.deinit();
            return c.SQLITE_OK;
        }

        fn xFilter(vtab_cursor: [*c]c.sqlite3_vtab_cursor, idx_num: c_int, idx_str: [*c]const u8, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) c_int {
            const cursor_state = getCursorState(vtab_cursor);
            var arena = std.heap.ArenaAllocator.init(cursor_state.allocator);
            defer arena.deinit();

            const count: usize = @intCast(argc);
            const args = arena.allocator().alloc(FilterArg, count) catch return c.SQLITE_NOMEM;
            for (0..count) |index| {
                args[index] = .{ .raw = argv[index].? };
            }

            const plan: QueryPlan = .{
                .index_number = @intCast(idx_num),
                .index_string = if (idx_str == null) null else std.mem.span(idx_str),
            };

            invokeFilter(cursor_state, plan, args) catch |err| {
                setVtabError(&cursor_state.state.vtab, err);
                return resultCodeFromError(err);
            };
            return c.SQLITE_OK;
        }

        fn xNext(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const cursor_state = getCursorState(vtab_cursor);
            cursor_state.cursor.next() catch |err| {
                setVtabError(&cursor_state.state.vtab, err);
                return resultCodeFromError(err);
            };
            return c.SQLITE_OK;
        }

        fn xEof(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
            const cursor_state = getCursorState(vtab_cursor);
            return if (cursor_state.cursor.eof()) 1 else 0;
        }

        fn xColumn(vtab_cursor: [*c]c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, n: c_int) callconv(.c) c_int {
            const cursor_state = getCursorState(vtab_cursor);
            const column_value = cursor_state.cursor.column(@intCast(n)) catch |err| {
                value.setContextError(ctx, @errorName(err));
                setVtabError(&cursor_state.state.vtab, err);
                return resultCodeFromError(err);
            };
            value.setContextResult(ctx, column_value);
            return c.SQLITE_OK;
        }

        fn xRowid(vtab_cursor: [*c]c.sqlite3_vtab_cursor, out_rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
            const cursor_state = getCursorState(vtab_cursor);
            out_rowid.* = cursor_state.cursor.rowId() catch |err| {
                setVtabError(&cursor_state.state.vtab, err);
                return resultCodeFromError(err);
            };
            return c.SQLITE_OK;
        }

        fn xUpdate(vtab: [*c]c.sqlite3_vtab, argc: c_int, argv: [*c]?*c.sqlite3_value, out_rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
            const state = getState(vtab);
            if (!@hasDecl(Table, "update")) {
                return c.SQLITE_READONLY;
            }

            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();

            const value_count: usize = @intCast(if (argc > 2) argc - 2 else 0);
            const columns = arena.allocator().alloc(FilterArg, value_count) catch return c.SQLITE_NOMEM;
            for (0..value_count) |index| {
                columns[index] = .{ .raw = argv[index + 2].? };
            }

            const argc_usize: usize = @intCast(argc);
            const operation: UpdateOperation = if (argc_usize == 1) .{
                .kind = .delete,
                .old_rowid = readOptionalRowId(argv[0].?) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                },
                .new_rowid = null,
                .columns = &.{},
            } else blk: {
                const old_rowid = readOptionalRowId(argv[0].?) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                };
                const new_rowid = readOptionalRowId(argv[1].?) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                };

                break :blk .{
                    .kind = if (old_rowid == null) UpdateKind.insert else UpdateKind.update,
                    .old_rowid = old_rowid,
                    .new_rowid = new_rowid,
                    .columns = columns,
                };
            };

            const inserted_rowid = state.table.update(operation) catch |err| {
                setVtabError(&state.vtab, err);
                return resultCodeFromError(err);
            };

            if (operation.kind == .insert and inserted_rowid != null) {
                out_rowid.* = inserted_rowid.?;
            }
            return c.SQLITE_OK;
        }

        fn xBegin(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            const state = getState(vtab);
            invokeTableNoArg(state, "begin") catch |err| {
                setVtabError(&state.vtab, err);
                return resultCodeFromError(err);
            };
            return c.SQLITE_OK;
        }

        fn xSync(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            const state = getState(vtab);
            invokeTableNoArg(state, "sync") catch |err| {
                setVtabError(&state.vtab, err);
                return resultCodeFromError(err);
            };
            return c.SQLITE_OK;
        }

        fn xCommit(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            const state = getState(vtab);
            invokeTableNoArg(state, "commit") catch |err| {
                setVtabError(&state.vtab, err);
                return resultCodeFromError(err);
            };
            return c.SQLITE_OK;
        }

        fn xRollback(vtab: [*c]c.sqlite3_vtab) callconv(.c) c_int {
            const state = getState(vtab);
            invokeTableNoArg(state, "rollback") catch |err| {
                setVtabError(&state.vtab, err);
                return resultCodeFromError(err);
            };
            return c.SQLITE_OK;
        }

        fn xRename(vtab: [*c]c.sqlite3_vtab, new_name: [*c]const u8) callconv(.c) c_int {
            const state = getState(vtab);
            if (@hasDecl(Table, "rename")) {
                state.table.rename(std.mem.span(new_name)) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                };
            }
            return c.SQLITE_OK;
        }

        fn xSavepoint(vtab: [*c]c.sqlite3_vtab, savepoint_id: c_int) callconv(.c) c_int {
            const state = getState(vtab);
            if (@hasDecl(Table, "savepoint")) {
                state.table.savepoint(@intCast(savepoint_id)) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                };
            }
            return c.SQLITE_OK;
        }

        fn xRelease(vtab: [*c]c.sqlite3_vtab, savepoint_id: c_int) callconv(.c) c_int {
            const state = getState(vtab);
            if (@hasDecl(Table, "release")) {
                state.table.release(@intCast(savepoint_id)) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                };
            }
            return c.SQLITE_OK;
        }

        fn xRollbackTo(vtab: [*c]c.sqlite3_vtab, savepoint_id: c_int) callconv(.c) c_int {
            const state = getState(vtab);
            if (@hasDecl(Table, "rollbackTo")) {
                state.table.rollbackTo(@intCast(savepoint_id)) catch |err| {
                    setVtabError(&state.vtab, err);
                    return resultCodeFromError(err);
                };
            }
            return c.SQLITE_OK;
        }

        fn xDestroyModule(raw_ctx: ?*anyopaque) callconv(.c) void {
            const ctx: *ModuleContext = @ptrCast(@alignCast(raw_ctx.?));
            ctx.allocator.destroy(ctx);
        }
    };

    const Static = struct {
        const module = blk: {
            var module_value = std.mem.zeroes(c.sqlite3_module);
            module_value.iVersion = 2;
            module_value.xCreate = Wrapper.xCreate;
            module_value.xConnect = Wrapper.xConnect;
            module_value.xBestIndex = Wrapper.xBestIndex;
            module_value.xDisconnect = Wrapper.xDisconnect;
            module_value.xDestroy = Wrapper.xDestroy;
            module_value.xOpen = Wrapper.xOpen;
            module_value.xClose = Wrapper.xClose;
            module_value.xFilter = Wrapper.xFilter;
            module_value.xNext = Wrapper.xNext;
            module_value.xEof = Wrapper.xEof;
            module_value.xColumn = Wrapper.xColumn;
            module_value.xRowid = Wrapper.xRowid;
            module_value.xUpdate = Wrapper.xUpdate;
            module_value.xBegin = Wrapper.xBegin;
            module_value.xSync = Wrapper.xSync;
            module_value.xCommit = Wrapper.xCommit;
            module_value.xRollback = Wrapper.xRollback;
            module_value.xRename = Wrapper.xRename;
            module_value.xSavepoint = Wrapper.xSavepoint;
            module_value.xRelease = Wrapper.xRelease;
            module_value.xRollbackTo = Wrapper.xRollbackTo;
            break :blk module_value;
        };
    };

    const z_name = try allocator.dupeZ(u8, name);
    defer allocator.free(z_name);

    const module_context = try allocator.create(ModuleContext);
    errdefer allocator.destroy(module_context);
    module_context.* = .{ .allocator = allocator };

    const result = c.sqlite3_create_module_v2(
        db_handle,
        z_name.ptr,
        &Static.module,
        module_context,
        Wrapper.xDestroyModule,
    );
    if (result != c.SQLITE_OK) {
        return errors.fromCode(result);
    }
}
