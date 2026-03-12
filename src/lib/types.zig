pub const TextValue = struct {
    data: []const u8,
};

pub const BlobValue = struct {
    data: []const u8,
};

pub const ZeroBlob = struct {
    length: usize,
};
