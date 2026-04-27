const std = @import("std");
const Db = @import("db.zig").Db;
const OpenOptions = @import("db.zig").OpenOptions;
const errors = @import("errors.zig");

pub const Pool = struct {
    allocator: std.mem.Allocator,
    databases: []Db,
    available: []usize,
    available_count: usize,
    closed: bool = false,
    mutex: std.atomic.Mutex = .unlocked,

    pub const Config = struct {
        size: usize = 4,
        options: OpenOptions = .{},
    };

    pub const Lease = struct {
        pool: *Pool,
        db: *Db,
        slot_index: usize,
        released: bool = false,

        pub fn release(self: *Lease) void {
            if (self.released) return;
            self.released = true;
            self.pool.releaseSlot(self.slot_index);
        }

        pub fn deinit(self: *Lease) void {
            self.release();
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) errors.Error!Pool {
        var databases = try allocator.alloc(Db, config.size);
        errdefer allocator.free(databases);

        var available = try allocator.alloc(usize, config.size);
        errdefer allocator.free(available);

        var open_options = config.options;
        var shared_path: ?[]u8 = null;
        defer if (shared_path) |path| allocator.free(path);

        if (open_options.path == null) {
            shared_path = try std.fmt.allocPrint(
                allocator,
                "file:sqlite-zig-pool-{x}?mode=memory&cache=shared",
                .{@intFromPtr(databases.ptr)},
            );
            open_options.path = shared_path.?;
            open_options.uri = true;
            open_options.shared_cache = true;
        }

        var opened: usize = 0;
        errdefer {
            for (databases[0..opened]) |*db| {
                db.deinit();
            }
        }

        for (0..config.size) |index| {
            databases[index] = try Db.open(allocator, open_options);
            available[index] = index;
            opened += 1;
        }

        return .{
            .allocator = allocator,
            .databases = databases,
            .available = available,
            .available_count = config.size,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.lock();
        self.closed = true;
        self.unlock();

        for (self.databases) |*db| {
            db.deinit();
        }
        self.allocator.free(self.databases);
        self.allocator.free(self.available);
    }

    pub fn acquire(self: *Pool) errors.Error!Lease {
        while (true) {
            self.lock();

            if (self.closed) {
                self.unlock();
                return error.PoolClosed;
            }

            if (self.available_count > 0) {
                self.available_count -= 1;
                const slot_index = self.available[self.available_count];
                self.unlock();
                return .{
                    .pool = self,
                    .db = &self.databases[slot_index],
                    .slot_index = slot_index,
                };
            }

            self.unlock();
            std.Thread.yield() catch {};
        }
    }

    fn releaseSlot(self: *Pool, slot_index: usize) void {
        self.lock();
        defer self.unlock();

        if (self.closed) {
            return;
        }

        self.available[self.available_count] = slot_index;
        self.available_count += 1;
    }

    fn lock(self: *Pool) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Pool) void {
        self.mutex.unlock();
    }
};

test "pool supports concurrent access" {
    var pool = try Pool.init(std.testing.allocator, .{
        .size = 2,
        .options = .{},
    });
    defer pool.deinit();

    {
        var lease = try pool.acquire();
        defer lease.deinit();

        try lease.db.exec("create table counters(value integer not null)", .{});
        try lease.db.exec("insert into counters(value) values (0)", .{});
    }

    const Worker = struct {
        fn run(worker_pool: *Pool) !void {
            for (0..200) |_| {
                var lease = try worker_pool.acquire();
                defer lease.deinit();
                try lease.db.exec("update counters set value = value + 1", .{});
            }
        }
    };

    const a = try std.Thread.spawn(.{}, Worker.run, .{&pool});
    const b = try std.Thread.spawn(.{}, Worker.run, .{&pool});
    a.join();
    b.join();

    var lease = try pool.acquire();
    defer lease.deinit();

    const count = (try lease.db.one(i64, "select value from counters", .{})).?;
    try std.testing.expectEqual(@as(i64, 400), count);
}
