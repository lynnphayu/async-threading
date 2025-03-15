const std = @import("std");
const http = std.http;
const log = std.log;
const net = std.net;
const xev = @import("xev");
const mem = std.mem;

const ConnectionWrapper = struct { connection: net.Server.Connection, server: *Server };

const RouteHandler = fn (alloc: *std.mem.Allocator, http: *http.Server.Request) anyerror!void;

pub const Server = struct {
    address: *net.Address,
    event_loop: xev.Loop,
    allocator: *std.mem.Allocator,
    tcp_server: net.Server,
    routes: std.AutoHashMap(http.Method, std.StringHashMap(*const RouteHandler)),

    pub fn init(
        address: *net.Address,
        allocator: *std.mem.Allocator,
    ) !Server {
        const server = try address.listen(.{
            .reuse_address = true,
            .reuse_port = true,
        });
        log.debug("initialized tcp server", .{});

        var thread_pool = xev.ThreadPool.init(.{
            .stack_size = 1024 * 1024,
            .max_threads = @as(u32, @intCast(std.Thread.getCpuCount() catch 1)),
        });
        log.debug("initialized thread pool", .{});
        const event_loop = xev.Loop.init(.{ .thread_pool = &thread_pool }) catch |err| {
            log.err("Failed to init event loop: {}", .{err});
            return error.FailedToInitEventLoop;
        };
        log.debug("initialized event loop", .{});

        const route_registry = std.AutoHashMap(http.Method, std.StringHashMap(*const RouteHandler)).init(allocator.*);
        log.debug("initialized route registry", .{});

        return Server{
            .tcp_server = server,
            .routes = route_registry,
            .allocator = allocator,
            .address = address,
            .event_loop = event_loop,
        };
    }

    pub fn deinit(self: *Server) void {
        self.routes.deinit();
        self.tcp_server.deinit();
        self.event_loop.deinit();
    }

    pub fn add(self: *Server, method: http.Method, path: []const u8, handler: *const RouteHandler) !void {
        const method_map = self.routes.getOrPut(method) catch unreachable;
        if (method_map.found_existing == true) {
            try method_map.value_ptr.put(path, handler);
            return;
        }
        var route_map = std.StringHashMap(*const RouteHandler).init(self.allocator.*);
        try route_map.put(path, handler);
        try self.routes.put(method, route_map);
        log.debug("registered route : {} {s}", .{ method, path });
    }

    pub fn accept(self: *Server) anyerror!void {
        log.info("accepting connections on : {}", .{self.address});
        while (self.tcp_server.accept()) |conn| {
            const connection = conn;
            var c: xev.Completion = undefined;
            var async_task = try xev.Async.init();
            var connection_wrapper = ConnectionWrapper{ .connection = connection, .server = self };
            async_task.wait(&self.event_loop, &c, ConnectionWrapper, &connection_wrapper, ev_callback);
            try async_task.notify();
            try self.event_loop.run(.until_done);
        } else |err| {
            log.err("failed to accept connection: {}", .{err});
        }
    }

    fn not_found(data: *http.Server.Request) !void {
        try data.respond("Not Found", .{ .status = http.Status.not_found });
    }

    fn handler_wrapper(data: ConnectionWrapper) !void {
        const conn = data.connection;
        defer conn.stream.close();
        var recv_buf: [1024 * 2]u8 = undefined;

        var blocking_server = http.Server.init(conn, &recv_buf);
        var request = try blocking_server.receiveHead();

        log.info("{} {s}", .{ request.head.method, request.head.target });

        const method_map = data.server.routes.get(request.head.method);
        if (method_map == null) {
            try not_found(&request);
            return;
        }
        const handler = method_map.?.get(request.head.target);
        if (handler == null) {
            try not_found(&request);
            return;
        }
        try handler.?(data.server.allocator, &request);
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
            log.err("handler error: {}", .{err});
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
};
