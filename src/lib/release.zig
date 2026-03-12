const std = @import("std");

pub fn release(allocator: std.mem.Allocator, value: anytype) void {
    releaseType(@TypeOf(value), allocator, value);
}

fn releaseType(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            if (value) |child| {
                releaseType(optional_info.child, allocator, child);
            }
        },
        .pointer => |pointer_info| {
            if (pointer_info.size != .slice) {
                return;
            }

            if (pointer_info.child == u8) {
                allocator.free(value);
                return;
            }

            for (value) |item| {
                releaseType(pointer_info.child, allocator, item);
            }
            allocator.free(value);
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                releaseType(field.type, allocator, @field(value, field.name));
            }
        },
        else => {},
    }
}

test "release frees nested slices" {
    const allocator = std.testing.allocator;

    const Row = struct {
        name: []const u8,
    };

    var rows = try allocator.alloc(Row, 2);
    rows[0] = .{ .name = try allocator.dupe(u8, "alpha") };
    rows[1] = .{ .name = try allocator.dupe(u8, "beta") };

    release(allocator, rows);
}
