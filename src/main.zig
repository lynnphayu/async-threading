const std = @import("std");
const http = std.http;
const log = std.log.scoped(.server);
const thread_log = std.log.scoped(.thread);
const net = std.net;
const xev = @import("xev");
const mem = std.mem;

const server_addr = [4]u8{ 0, 0, 0, 0 };
const server_port = 8080;
const max_threads = 4;

const RequestJob = struct {
    task: xev.ThreadPool.Task,
    connection: *net.Server.Connection,
    allocator: *std.mem.Allocator,
};

const EventLoop = struct {
    loop: xev.Loop,
    occupied: bool,
};

const EventLoopList = std.ArrayList(EventLoop);

const ConnectionWrapper = struct {
    connection: net.Server.Connection,
};

fn handler(data: *net.Server.Connection) !void {
    const conn = data;
    defer conn.stream.close();

    var recv_buf: [1024]u8 = undefined;
    _ = try conn.stream.read(&recv_buf);

    const headers = try http.Server.Request.Head.parse(&recv_buf);
    log.info("Request: {}", .{headers.method});

    const response = "{\"message\": \"HI!\"}";
    const httpHead =
        "HTTP/1.1 200 OK \r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n";
    _ = try conn.stream.writer().print(httpHead, .{
        "text/json",
        response.len,
    });
    _ = try conn.stream.writer().writeAll(response);
}

pub fn main() !void {
    const address = net.Address.initIp4(server_addr, server_port);
    var server = try address.listen(.{
        .reuse_address = true,
        .reuse_port = true,
    });
    defer server.deinit();

    var thread_pool = xev.ThreadPool.init(.{
        .stack_size = 1024 * 1024,
        .max_threads = max_threads,
    });
    defer thread_pool.deinit();
    var event_loop = xev.Loop.init(.{ .thread_pool = &thread_pool }) catch |err| {
        log.err("Failed to init event loop: {}", .{err});
        return error.FailedToInitEventLoop;
    };
    defer event_loop.deinit();

    log.info("Starting server on {s}:{d}", .{ server_addr, server_port });

    while (server.accept()) |conn| {
        var connection = conn;
        var c: xev.Completion = undefined;
        var async_task = try xev.Async.init();
        async_task.wait(&event_loop, &c, net.Server.Connection, &connection, callback);
        try async_task.notify();
        try event_loop.run(.until_done);
    } else |err| {
        log.err("Server failed to accept connection: {s}", .{@errorName(err)});
        return error.ServerFailedToAcceptConnection;
    }
}

fn callback(
    userdata: ?*net.Server.Connection,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.ReadError!void,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = result catch unreachable;

    handler(userdata.?) catch |err| {
        thread_log.err("Handler error: {}", .{err});
    };
    return .disarm;
}
