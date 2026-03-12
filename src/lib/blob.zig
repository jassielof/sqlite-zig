const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");

pub const Blob = struct {
    handle: *c.sqlite3_blob,
    size: usize,
    offset: usize = 0,

    pub const DatabaseName = union(enum) {
        main,
        temp,
        attached: []const u8,
    };

    pub const OpenOptions = struct {
        database: DatabaseName = .main,
        write: bool = false,
    };

    pub fn deinit(self: *Blob) void {
        _ = c.sqlite3_blob_close(self.handle);
    }

    pub fn reset(self: *Blob) void {
        self.offset = 0;
    }

    pub fn seekTo(self: *Blob, offset: usize) errors.Error!void {
        if (offset > self.size) {
            return error.Range;
        }
        self.offset = offset;
    }

    pub fn read(self: *Blob, buffer: []u8) errors.Error!usize {
        if (self.offset >= self.size) {
            return 0;
        }

        const remaining = self.size - self.offset;
        const chunk = if (buffer.len > remaining) buffer[0..remaining] else buffer;
        const result = c.sqlite3_blob_read(
            self.handle,
            chunk.ptr,
            @intCast(chunk.len),
            @intCast(self.offset),
        );
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }

        self.offset += chunk.len;
        return chunk.len;
    }

    pub fn readAllAlloc(self: *Blob, allocator: std.mem.Allocator) errors.Error![]u8 {
        const current_offset = self.offset;
        defer self.offset = current_offset;

        try self.seekTo(0);
        const data = try allocator.alloc(u8, self.size);
        errdefer allocator.free(data);

        var written: usize = 0;
        while (written < data.len) {
            const read_count = try self.read(data[written..]);
            if (read_count == 0) break;
            written += read_count;
        }
        return data[0..written];
    }

    pub fn write(self: *Blob, data: []const u8) errors.Error!usize {
        if (data.len == 0) return 0;

        const remaining = self.size - self.offset;
        const chunk = if (data.len > remaining) data[0..remaining] else data;
        const result = c.sqlite3_blob_write(
            self.handle,
            chunk.ptr,
            @intCast(chunk.len),
            @intCast(self.offset),
        );
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }

        self.offset += chunk.len;
        return chunk.len;
    }

    pub fn writeAll(self: *Blob, data: []const u8) errors.Error!void {
        if (data.len > self.size - self.offset) {
            return error.TooBig;
        }

        var written: usize = 0;
        while (written < data.len) {
            written += try self.write(data[written..]);
        }
    }

    pub fn reopen(self: *Blob, row_id: i64) errors.Error!void {
        const result = c.sqlite3_blob_reopen(self.handle, row_id);
        if (result != c.SQLITE_OK) {
            return errors.fromCode(result);
        }

        self.size = @intCast(c.sqlite3_blob_bytes(self.handle));
        self.offset = 0;
    }
};
