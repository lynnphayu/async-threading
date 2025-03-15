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
    connection: net.Server.Connection,
    route_registry: *RouteRegistry,
};

const RouteHandler = fn (alloc: *std.mem.Allocator, http: *http.Server.Request) anyerror!void;

const RouteRegistry = struct {
    allocator: *std.mem.Allocator,
    routes: std.AutoHashMap(http.Method, std.StringHashMap(*const RouteHandler)),
    pub fn init(allocator: *std.mem.Allocator) RouteRegistry {
        return RouteRegistry{
            .allocator = allocator,
            .routes = std.AutoHashMap(http.Method, std.StringHashMap(*const RouteHandler)).init(allocator.*),
        };
    }
    pub fn add(self: *RouteRegistry, method: http.Method, path: []const u8, handler: *const RouteHandler) !void {
        const method_map = self.routes.getOrPut(method) catch unreachable;
        if (method_map.found_existing == true) {
            try method_map.value_ptr.put(path, handler);
        }
        var route_map = std.StringHashMap(*const RouteHandler).init(self.allocator.*);
        try route_map.put(path, handler);
        try self.routes.put(method, route_map);
    }
};

fn handler_wrapper(data: ConnectionWrapper) !void {
    // const header_map = std.StringHashMap([]const u8).init(allocator.*);

    const conn = data.connection;
    defer conn.stream.close();
    var recv_buf: [1024 * 2]u8 = undefined;

    var blocking_server = http.Server.init(conn, &recv_buf);
    var request = try blocking_server.receiveHead();

    log.info("{} {s}", .{ request.head.method, request.head.target });
    const method_map = data.route_registry.routes.get(request.head.method) orelse return error.RouteNotFound;
    const handler = method_map.get(request.head.target) orelse return error.RouteNotFound;
    try handler(data.route_registry.allocator, &request);

    // var headers = request.iterateHeaders();
    // while (headers.next()) |header| {
    //     try header_map.put(header.name, header.value);
    // }

    // change header map to json and print out
    // print out header map
    // var it = header_map.iterator();
    // while (it.next()) |entry| {
    //     log.info("{s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
    // }

    // const reader = try request.reader();
    // while (true) {
    //     reader
    //         .streamUntilDelimiter(body_raw.writer(), '\r', 1024) catch |err| {
    //         if (err == error.EndOfStream) break;
    //         return error.FailedToReadBody;
    //     };
    // }

    // const response = body_raw.items;
    // const httpHead =
    //     "HTTP/1.1 200 OK \r\n" ++
    //     "Connection: close\r\n" ++
    //     "Content-Type: {s}\r\n" ++
    //     "Content-Length: {}\r\n" ++
    //     "\r\n";
    // _ = try conn.stream.writer().print(httpHead, .{
    //     "application/json",
    //     response.len,
    // });
    // _ = try conn.stream.writer().writeAll(response);
}

fn poc_handler(_: *std.mem.Allocator, connection: *http.Server.Request) anyerror!void {
    const response = "Hello, World!";
    try connection.respond(response, .{ .status = .ok });
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
        .max_threads = @as(u32, @intCast(std.Thread.getCpuCount() catch 1)),
    });
    defer thread_pool.deinit();
    var event_loop = xev.Loop.init(.{ .thread_pool = &thread_pool }) catch |err| {
        log.err("Failed to init event loop: {}", .{err});
        return error.FailedToInitEventLoop;
    };
    defer event_loop.deinit();

    log.info("Listening on {}", .{address});
    var route_registry = RouteRegistry.init(&allocator);

    try route_registry.add(.GET, "/", poc_handler);

    while (server.accept()) |conn| {
        const connection = conn;
        var c: xev.Completion = undefined;
        var async_task = try xev.Async.init();
        var connection_wrapper = ConnectionWrapper{
            .route_registry = &route_registry,
            .connection = connection,
        };
        async_task.wait(&event_loop, &c, ConnectionWrapper, &connection_wrapper, ev_callback);
        try async_task.notify();
        try event_loop.run(.until_done);
    } else |err| {
        log.err("Server failed to accept connection: {s}", .{@errorName(err)});
        return error.ServerFailedToAcceptConnection;
    }
}

fn ev_callback(
    userdata: ?*ConnectionWrapper,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.ReadError!void,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = result catch unreachable;

    const time_start = std.time.microTimestamp();

    handler_wrapper(userdata.?.*) catch |err| {
        log.err("Handler error: {}", .{err});
    };
    const diff = std.time.microTimestamp() - time_start;
    var unit = " us";
    var diff_to_show = diff;
    if (diff > std.time.us_per_ms) {
        unit = " ms";
        diff_to_show = @rem(diff, std.time.us_per_ms);
    }
    if (diff > std.time.us_per_s) {
        unit = "sec";
        diff_to_show = @rem(diff, std.time.us_per_ms);
    }
    if (diff > std.time.ms_per_min) {
        unit = "min";
        diff_to_show = @rem(diff, std.time.us_per_ms);
    }

    log.info("{d} {s}", .{ diff_to_show, unit });
    return .disarm;
}
