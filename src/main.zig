const std = @import("std");
const xev = @import("xev");
const server = @import("server.zig");

const Server = server.Server;
// pub const std_options = std.Options{
//     .log_level = std.log.Level.info,
// };

const server_addr = [4]u8{ 0, 0, 0, 0 };
const server_port = 8080;
const max_threads = 4;

fn get_sample(_: *std.mem.Allocator, connection: *std.http.Server.Request) anyerror!void {
    const response = "Hello, World!";
    try connection.respond(response, .{ .status = .ok });
}

fn post_sample(_: *std.mem.Allocator, connection: *std.http.Server.Request) anyerror!void {
    const response = "{\"message\": \"HI!\"}";
    const extra_headers = [_]std.http.Header{.{
        .name = "Content-Type",
        .value = "application/json",
    }};
    try connection.respond(response, .{ .status = .ok, .extra_headers = &extra_headers });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var allocator = gpa.allocator();

    var address = std.net.Address.initIp4(server_addr, server_port);
    var s = try Server.init(&address, &allocator);
    defer s.deinit();
    try s.add(std.http.Method.GET, "/", get_sample);
    try s.add(std.http.Method.POST, "/", post_sample);
    try s.accept();
}
