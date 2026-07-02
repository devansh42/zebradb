const std = @import("std");
pub const defaultEndian = std.builtin.Endian.little;
pub fn writeInt(comptime T: type, wr: *std.Io.Writer, value: T) !void {
    try wr.writeInt(T, value, defaultEndian);
}
pub fn readInt(comptime T: type, rd: *std.Io.Reader, val: *T) !void {
    val.* = try rd.takeInt(T, defaultEndian);
}
