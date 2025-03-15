# Async Threading

This is a proof of concept HTTP server in Zig that demonstrates the use of an event loop with thread pool functionality provided by [libxev](https://github.com/mitchellh/libxev).
Libxev offers a unified event loop API abstraction across various platforms, allowing users to incorporate threadpool for resource-intensive operations (though I'm still not clear about the specifics of how they offload some of the computation to threadpool, or oversold?).

The eventloop in libxev is straightforward. They use the same things what other libs and languages use. Epoll or IO_Uring for Linux, Kqueue for Mac, IOCP for Windows, etc. Those are no doubt the most efficient way to handle async tasks at the moment. But the approch they take for threadpool is a little bit different. Especially when it comes to shared memory management for the task queues.

They implement what they call **lock-free unbounded** memory management. The concept is similar to a shared double buffer with additional optimizations that eliminate the need for locks, which ,in turn, reduces contention overhead between threads.

I can not explain it further since I am also still working to fully understand how they took each step of the way. If you'd like to know more, you can check out the original article [Resource efficient Thread Pools](https://zig.news/kprotty/resource-efficient-thread-pools-with-zig-3291).

The thread pool implementation in libxev is almost directly copied from [Zap](https://github.com/kprotty/zap), created by the author of the article I just mentioned above, with very little modification (may be none? i dont know) by Mitchell Hashimoto.

With all that being said, in theory, these ideas should allow an HTTP server to effiently utilize the full capacity of the underlying hardware.

1. Install zig (>=0.14) or `nix develop`
2. `zig build run`

### Dependencies

- Zig (>=0.14)
- libxev (automatically managed by Zig tool chain)
