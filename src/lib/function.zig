const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const value = @import("value.zig");

/// SQLite callback context for scalar and aggregate functions.
///
/// Use this as the first parameter of a callback registered with
/// `createScalarWithUserData` or `createAggregateWithUserData` when the
/// function needs access to user-provided state or aggregate-local storage.
pub const FunctionContext = struct {
    ctx: ?*c.sqlite3_context,

    /// Returns the pointer that was passed as `user_data` during function registration.
    ///
    /// `T` must be a single-item pointer type such as `*MyState`.
    pub fn userContext(self: FunctionContext, comptime T: type) ?T {
        const types = splitPointerType(T);
        _ = types;

        const raw = c.sqlite3_user_data(self.ctx) orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    /// Returns SQLite-managed aggregate storage for the requested pointer type.
    ///
    /// SQLite initializes this memory to zero on first use. `T` must be a
    /// single-item pointer type such as `*AggregateState`.
    pub fn aggregateContext(self: FunctionContext, comptime T: type) ?T {
        const types = splitPointerType(T);
        const raw = c.sqlite3_aggregate_context(self.ctx, @sizeOf(types.ValueType)) orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    const PointerTypeInfo = struct {
        ValueType: type,
    };

    fn splitPointerType(comptime T: type) PointerTypeInfo {
        return switch (@typeInfo(T)) {
            .pointer => |pointer_info| switch (pointer_info.size) {
                .one => .{ .ValueType = pointer_info.child },
                else => @compileError("function context access requires a single-item pointer, got " ++ @typeName(T)),
            },
            else => @compileError("function context access requires a pointer type, got " ++ @typeName(T)),
        };
    }
};

/// Flags that control how SQLite treats a registered SQL function.
pub const FunctionFlags = struct {
    deterministic: bool = true,
    direct_only: bool = false,
    innocuous: bool = false,
    subtype: bool = false,

    fn toC(self: FunctionFlags) c_int {
        var flags: c_int = c.SQLITE_UTF8;
        if (self.deterministic) flags |= c.SQLITE_DETERMINISTIC;
        if (self.direct_only and @hasDecl(c, "SQLITE_DIRECTONLY")) flags |= c.SQLITE_DIRECTONLY;
        if (self.innocuous and @hasDecl(c, "SQLITE_INNOCUOUS")) flags |= c.SQLITE_INNOCUOUS;
        if (self.subtype and @hasDecl(c, "SQLITE_SUBTYPE")) flags |= c.SQLITE_SUBTYPE;
        return flags;
    }
};

/// Registers a scalar SQL function.
///
/// The callback parameters after any optional `FunctionContext` are mapped from
/// SQLite argument values. The function name is registered on a single `Db`
/// connection.
pub fn createScalar(db_handle: *c.sqlite3, allocator: std.mem.Allocator, comptime name: []const u8, comptime func: anytype, flags: FunctionFlags) errors.Error!void {
    try createScalarWithUserData(db_handle, allocator, name, null, func, flags);
}

/// Registers a scalar SQL function with user-provided callback state.
///
/// If the callback's first parameter is `FunctionContext`, the callback can
/// retrieve `user_data` via `ctx.userContext(...)`.
pub fn createScalarWithUserData(db_handle: *c.sqlite3, allocator: std.mem.Allocator, comptime name: []const u8, user_data: anytype, comptime func: anytype, flags: FunctionFlags) errors.Error!void {
    const z_name = try allocator.dupeZ(u8, name);
    defer allocator.free(z_name);

    const fn_info = switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => |info| info,
        else => @compileError("scalar function must be a function"),
    };
    if (fn_info.is_generic) @compileError("scalar function must not be generic");
    if (fn_info.is_var_args) @compileError("scalar function must not be variadic");

    const has_context = fn_info.params.len > 0 and fn_info.params[0].type.? == FunctionContext;
    const sql_arity = fn_info.params.len - (if (has_context) 1 else 0);
    const raw_user_data = userDataPointer(user_data);

    const Wrapper = struct {
        fn xFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
            if (argc != sql_arity) {
                value.setContextError(ctx, "sqlite-zig scalar function arity mismatch");
                return;
            }

            const ArgsTuple = std.meta.ArgsTuple(@TypeOf(func));
            var args: ArgsTuple = undefined;

            if (has_context) {
                args[0] = .{ .ctx = ctx };
            }

            inline for (fn_info.params[(if (has_context) 1 else 0)..], 0..) |param, index| {
                args[index + (if (has_context) 1 else 0)] = value.readCallbackValue(param.type.?, argv[index].?) catch |err| {
                    value.setContextError(ctx, @errorName(err));
                    return;
                };
            }

            const ReturnType = fn_info.return_type orelse void;
            switch (@typeInfo(ReturnType)) {
                .error_union => {
                    const result = @call(.auto, func, args) catch |err| {
                        value.setContextError(ctx, @errorName(err));
                        return;
                    };
                    value.setContextResult(ctx, result);
                },
                else => {
                    const result = @call(.auto, func, args);
                    value.setContextResult(ctx, result);
                },
            }
        }
    };

    const result = c.sqlite3_create_function_v2(
        db_handle,
        z_name.ptr,
        @intCast(sql_arity),
        flags.toC(),
        raw_user_data,
        Wrapper.xFunc,
        null,
        null,
        null,
    );
    if (result != c.SQLITE_OK) {
        return errors.fromCode(result);
    }
}

/// Registers an aggregate SQL function backed by a Zig state type.
///
/// `Aggregate` must provide `step(self, ...)` and `final(self)` methods. The
/// state is created lazily per aggregate invocation.
pub fn createAggregate(db_handle: *c.sqlite3, allocator: std.mem.Allocator, comptime name: []const u8, comptime Aggregate: type, flags: FunctionFlags) errors.Error!void {
    const z_name = try allocator.dupeZ(u8, name);
    defer allocator.free(z_name);

    if (!@hasDecl(Aggregate, "step")) @compileError("aggregate type must define step(self, ...)");
    if (!@hasDecl(Aggregate, "final")) @compileError("aggregate type must define final(self)");

    const step_fn = Aggregate.step;
    const final_fn = Aggregate.final;
    const step_info = @typeInfo(@TypeOf(step_fn)).@"fn";
    const final_info = @typeInfo(@TypeOf(final_fn)).@"fn";

    if (step_info.params.len < 1 or step_info.params[0].type.? != *Aggregate) {
        @compileError("aggregate step must have first parameter *Aggregate");
    }
    if (final_info.params.len != 1 or final_info.params[0].type.? != *Aggregate) {
        @compileError("aggregate final must have signature final(self: *Aggregate)");
    }

    const State = struct {
        initialized: u8 = 0,
        value: Aggregate = undefined,
    };

    const Wrapper = struct {
        fn getState(ctx: ?*c.sqlite3_context) ?*State {
            const raw = c.sqlite3_aggregate_context(ctx, @sizeOf(State)) orelse return null;
            const state: *State = @ptrCast(@alignCast(raw));
            if (state.initialized == 0) {
                if (@hasDecl(Aggregate, "init")) {
                    state.value = Aggregate.init();
                } else {
                    state.value = std.mem.zeroes(Aggregate);
                }
                state.initialized = 1;
            }
            return state;
        }

        fn xStep(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
            if (argc != step_info.params.len - 1) {
                value.setContextError(ctx, "sqlite-zig aggregate arity mismatch");
                return;
            }

            const state = getState(ctx) orelse {
                value.setContextError(ctx, "sqlite-zig aggregate context allocation failed");
                return;
            };

            const ArgsTuple = std.meta.ArgsTuple(@TypeOf(step_fn));
            var args: ArgsTuple = undefined;
            args[0] = &state.value;

            inline for (step_info.params[1..], 0..) |param, index| {
                args[index + 1] = value.readCallbackValue(param.type.?, argv[index].?) catch |err| {
                    value.setContextError(ctx, @errorName(err));
                    return;
                };
            }

            const ReturnType = step_info.return_type orelse void;
            switch (@typeInfo(ReturnType)) {
                .error_union => {
                    _ = @call(.auto, step_fn, args) catch |err| {
                        value.setContextError(ctx, @errorName(err));
                    };
                },
                else => _ = @call(.auto, step_fn, args),
            }
        }

        fn xFinal(ctx: ?*c.sqlite3_context) callconv(.c) void {
            const state = getState(ctx) orelse {
                value.setContextError(ctx, "sqlite-zig aggregate context allocation failed");
                return;
            };

            const ReturnType = final_info.return_type orelse void;
            switch (@typeInfo(ReturnType)) {
                .error_union => {
                    const result = final_fn(&state.value) catch |err| {
                        value.setContextError(ctx, @errorName(err));
                        return;
                    };
                    value.setContextResult(ctx, result);
                },
                else => value.setContextResult(ctx, final_fn(&state.value)),
            }
        }
    };

    const result = c.sqlite3_create_function_v2(
        db_handle,
        z_name.ptr,
        step_info.params.len - 1,
        flags.toC(),
        null,
        null,
        Wrapper.xStep,
        Wrapper.xFinal,
        null,
    );
    if (result != c.SQLITE_OK) {
        return errors.fromCode(result);
    }
}

/// Registers an aggregate SQL function that uses `FunctionContext` instead of a
/// dedicated aggregate type.
///
/// This is useful when the callback needs both user-provided state and
/// SQLite-managed aggregate-local storage via `ctx.aggregateContext(...)`.
pub fn createAggregateWithUserData(db_handle: *c.sqlite3, allocator: std.mem.Allocator, comptime name: []const u8, user_data: anytype, comptime step_func: anytype, comptime final_func: anytype, flags: FunctionFlags) errors.Error!void {
    const z_name = try allocator.dupeZ(u8, name);
    defer allocator.free(z_name);

    const step_info = switch (@typeInfo(@TypeOf(step_func))) {
        .@"fn" => |info| info,
        else => @compileError("aggregate step function must be a function"),
    };
    const final_info = switch (@typeInfo(@TypeOf(final_func))) {
        .@"fn" => |info| info,
        else => @compileError("aggregate final function must be a function"),
    };

    if (step_info.is_generic or step_info.is_var_args) @compileError("aggregate step function must be a non-generic, non-variadic function");
    if (final_info.is_generic or final_info.is_var_args) @compileError("aggregate final function must be a non-generic, non-variadic function");
    if (step_info.params.len < 1 or step_info.params[0].type.? != FunctionContext) {
        @compileError("aggregate step function must start with FunctionContext");
    }
    if (final_info.params.len != 1 or final_info.params[0].type.? != FunctionContext) {
        @compileError("aggregate final function must have signature fn (ctx: FunctionContext)");
    }

    const raw_user_data = userDataPointer(user_data);

    const Wrapper = struct {
        fn xStep(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
            if (argc != step_info.params.len - 1) {
                value.setContextError(ctx, "sqlite-zig aggregate arity mismatch");
                return;
            }

            const ArgsTuple = std.meta.ArgsTuple(@TypeOf(step_func));
            var args: ArgsTuple = undefined;
            args[0] = .{ .ctx = ctx };

            inline for (step_info.params[1..], 0..) |param, index| {
                args[index + 1] = value.readCallbackValue(param.type.?, argv[index].?) catch |err| {
                    value.setContextError(ctx, @errorName(err));
                    return;
                };
            }

            const ReturnType = step_info.return_type orelse void;
            switch (@typeInfo(ReturnType)) {
                .error_union => {
                    _ = @call(.auto, step_func, args) catch |err| {
                        value.setContextError(ctx, @errorName(err));
                    };
                },
                else => _ = @call(.auto, step_func, args),
            }
        }

        fn xFinal(ctx: ?*c.sqlite3_context) callconv(.c) void {
            const args = .{FunctionContext{ .ctx = ctx }};
            const ReturnType = final_info.return_type orelse void;

            switch (@typeInfo(ReturnType)) {
                .error_union => {
                    const result = @call(.auto, final_func, args) catch |err| {
                        value.setContextError(ctx, @errorName(err));
                        return;
                    };
                    value.setContextResult(ctx, result);
                },
                else => value.setContextResult(ctx, @call(.auto, final_func, args)),
            }
        }
    };

    const result = c.sqlite3_create_function_v2(
        db_handle,
        z_name.ptr,
        @intCast(step_info.params.len - 1),
        flags.toC(),
        raw_user_data,
        null,
        Wrapper.xStep,
        Wrapper.xFinal,
        null,
    );
    if (result != c.SQLITE_OK) {
        return errors.fromCode(result);
    }
}

fn userDataPointer(user_data: anytype) ?*anyopaque {
    const T = @TypeOf(user_data);
    if (T == @TypeOf(null)) return null;

    return switch (@typeInfo(T)) {
        .pointer => |pointer_info| switch (pointer_info.size) {
            .one, .many, .c => @ptrCast(@constCast(user_data)),
            else => @compileError("user data must be a pointer or null, got " ++ @typeName(T)),
        },
        else => @compileError("user data must be a pointer or null, got " ++ @typeName(T)),
    };
}
