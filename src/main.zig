const std = @import("std");
const http = std.http;
const log = std.log.scoped(.server);
const net = std.net;
const xev = @import("xev");

const server_addr = [4]u8{ 0, 0, 0, 0 };
const server_port = 8080;

const RequestJob = struct {
    task: xev.ThreadPool.Task,
    connection: net.Server.Connection,
    arena: std.heap.ArenaAllocator,
};

fn handler(connection: net.Server.Connection) !void {
    log.info("Threadpool job processing", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

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
    log.info("Received body: {s}", .{body});
    try request.respond("Hello, World!", .{
        .status = .ok,
        .extra_headers = &[_]http.Header{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
    });
    log.info("Responded to request", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const address = net.Address.initIp4(server_addr, server_port);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    var thread_pool = xev.ThreadPool.init(.{
        .stack_size = 1024 * 1024,
        .max_threads = 4,
    });
    defer thread_pool.deinit();

    // var loop = try xev.Loop.init(.{});
    // defer loop.deinit();

    log.info("Starting server on {s}:{d}", .{ server_addr, server_port });

    while (true) {
        const connection = try server.accept();
        const addr = connection.address;
        log.info("Server accepting connection from {}", .{addr.in.getPort()});

        var arena = std.heap.ArenaAllocator.init(allocator);
        var request_job = try arena.allocator().create(RequestJob);
        request_job.* = RequestJob{
            .task = xev.ThreadPool.Task{
                .callback = threadpool_job,
            },
            .connection = connection,
            .arena = arena,
        };

        thread_pool.schedule(xev.ThreadPool.Batch.from(&request_job.task));

        // var proc = try xev.Async.init();
        // defer proc.deinit();
        // var completion: xev.Completion = undefined;
        // proc.wait(&loop, &completion, http.Server.Request, &request, timerCallback);
        // try proc.notify();
        // try loop.run(.until_done);

        // Create the request task

    }
}

fn threadpool_job(task: *xev.ThreadPool.Task) void {
    const request_job = @as(*RequestJob, @fieldParentPtr("task", task));
    handler(request_job.connection) catch unreachable;
    request_job.connection.stream.close();
}

fn timerCallback(
    userdata: ?*http.Server.Request,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.ReadError!void,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = result catch unreachable;

    log.info("Timer callback", .{});
    handler(userdata) catch unreachable;
    return .disarm;
}
