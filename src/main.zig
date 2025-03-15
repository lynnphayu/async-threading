const std = @import("std");
const http = std.http;
const log = std.log;
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
    alloc: *std.mem.Allocator,
    connection: net.Server.Connection,
};

fn handler(data: net.Server.Connection, allocator: *std.mem.Allocator) !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    var header_raw = std.ArrayList(u8).init(allocator.*);
    var body_raw = std.ArrayList(u8).init(allocator.*);
    defer header_raw.deinit();
    defer body_raw.deinit();

    const conn = data;
    defer conn.stream.close();

    // const reader = conn.stream.reader();

    var recv_buf: [1024 * 2]u8 = undefined;

    var blocking_server = http.Server.init(conn, &recv_buf);
    var request = try blocking_server.receiveHead();
    log.info("{any} {s}", .{ request.head.method, request.head.target });

    const reader = try request.reader();
    while (true) {
        reader
            .streamUntilDelimiter(body_raw.writer(), '\r', 1024) catch |err| {
            if (err == error.EndOfStream) break;
            return error.FailedToReadBody;
        };
    }

    const response = body_raw.items;
    const httpHead =
        "HTTP/1.1 200 OK \r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n";
    _ = try conn.stream.writer().print(httpHead, .{
        "application/json",
        response.len,
    });
    _ = try conn.stream.writer().writeAll(response);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var allocator = gpa.allocator();

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
        const connection = conn;
        var c: xev.Completion = undefined;
        var async_task = try xev.Async.init();
        var connection_wrapper = ConnectionWrapper{
            .alloc = &allocator,
            .connection = connection,
        };
        async_task.wait(&event_loop, &c, ConnectionWrapper, &connection_wrapper, callback);
        try async_task.notify();
        try event_loop.run(.until_done);
    } else |err| {
        log.err("Server failed to accept connection: {s}", .{@errorName(err)});
        return error.ServerFailedToAcceptConnection;
    }
}

fn callback(
    userdata: ?*ConnectionWrapper,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.ReadError!void,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = result catch unreachable;

    const time_start = std.time.milliTimestamp();

    handler(userdata.?.connection, userdata.?.alloc) catch |err| {
        log.err("Handler error: {}", .{err});
    };

    const time_end = std.time.milliTimestamp();
    log.info("{d} ms", .{time_end - time_start});
    return .disarm;
}
