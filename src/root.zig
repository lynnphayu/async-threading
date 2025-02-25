const std = @import("std");
const testing = std.testing;

const http = std.http;
const log = std.log.scoped(.server);
const net = std.net;
const xev = @import("xev");
const server_addr = [4]u8{ 0, 0, 0, 0 };
const server_port = 8080;

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn handler(connection: net.Server.Connection, allocator: std.mem.Allocator) !void {
    const read_buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(read_buffer);
    var http_server = std.http.Server.init(connection, read_buffer);
    var request = try http_server.receiveHead();
    // log.info("Received headers: ", .{});
    // var header_iterator = request.iterateHeaders();
    // while (header_iterator.next()) |header| {
    //     log.info("  {s}: {s}", .{ header.name, header.value });
    // }

    const content_reader = try request.reader();
    const body = try content_reader.readAllAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(body);
    // log.info("Received body: {s}", .{body});
    try request.respond("Hello, World!", .{
        .status = .ok,
        .extra_headers = &[_]http.Header{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
    });
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
