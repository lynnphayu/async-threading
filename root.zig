const std = @import("std");
const testing = std.testing;
const xev = @import("xev");

const http = std.http;
const log = std.log.scoped(.server);
const net = std.net;

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const address = net.Address.initIp4(server_addr, server_port);
    var server = try address.listen(.{});
    defer server.deinit();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    try loop.run(.until_done);

    log.info("Starting server on {s}:{d}", .{ server_addr, server_port });
    while (true) {
        const connection = try server.accept();
        const addr = connection.address;
        log.info("Server accepting connection from {}", .{addr.in.getPort()});
        defer connection.stream.close();
        // try handler(connection, allocator);
        var proc = try xev.Process.init();
        defer proc.deinit();
        var completion: xev.Completion = undefined;
        try proc.wait(loop, &completion, net.Server.Connection, connection, null);
    }
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
