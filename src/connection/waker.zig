//! io_task wakeup primitive.
//!
//! A pollable file descriptor that a producer thread (publish, subscribe,
//! close, ...) writes to in order to wake the io_task out of a blocking
//! poll() promptly, instead of relying on a short poll timeout. The io_task
//! includes the waker fd in its pollfds; a producer signals it after pushing
//! outbound work.
//!
//! Level-triggered by design: the fd stays readable until io_task drains it.
//! A producer signal that races io_task's drain therefore leaves the fd
//! signaled, so the next poll() returns immediately and io_task re-checks the
//! outbound ring -- no lost wakeup.
//!
//! On Linux this is a single eventfd (read/write share one fd). On other
//! POSIX targets it degrades to a disabled waker (fd = -1, which poll()
//! ignores); those targets fall back to the coarse poll timeout for producer
//! latency. Linux is the only supported deployment target.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

pub const Waker = struct {
    /// -1 means "disabled" (non-Linux fallback). poll() ignores a negative fd.
    fd: posix.fd_t = -1,

    pub const InitError = error{WakerInitFailed};

    pub fn init() InitError!Waker {
        if (builtin.os.tag == .linux) {
            const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .fd = @intCast(rc) },
                else => return error.WakerInitFailed,
            }
        }
        // Non-Linux: disabled waker. Producer wakeup falls back to the coarse
        // poll timeout. Not a supported deployment target.
        return .{ .fd = -1 };
    }

    pub fn deinit(self: *Waker) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    /// True if this waker has a usable fd (Linux eventfd).
    pub fn enabled(self: *const Waker) bool {
        return self.fd >= 0;
    }

    /// Producer: signal io_task. Non-blocking and idempotent -- the fd stays
    /// readable until io_task drains it, so a signal is never lost even if it
    /// races the drain. Safe to call from any thread.
    pub fn wake(self: *const Waker) void {
        if (self.fd < 0) return;
        const one: u64 = 1;
        // A full eventfd counter (EAGAIN) is fine: the fd is already signaled.
        _ = linux.write(self.fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// io_task: fully drain the waker after poll() reports it readable, so the
    /// next idle poll() blocks instead of returning immediately.
    pub fn drain(self: *const Waker) void {
        if (self.fd < 0) return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const rc = linux.read(self.fd, &buf, buf.len);
            const n: isize = @bitCast(rc);
            // EAGAIN (nothing left) or any error -> stop. eventfd reads 8 bytes
            // and resets the counter, so one successful read fully drains it.
            if (n <= 0) break;
            if (@as(usize, @intCast(n)) < buf.len) break;
        }
    }
};

test "waker: signal makes poll return, drain clears it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var waker = try Waker.init();
    defer waker.deinit();
    try std.testing.expect(waker.enabled());

    var fds = [_]posix.pollfd{.{
        .fd = waker.fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    // Idle: poll times out promptly (no signal pending).
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 10));

    // After wake(): poll returns readable immediately.
    waker.wake();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&fds, 1000));
    try std.testing.expect((fds[0].revents & posix.POLL.IN) != 0);

    // Multiple signals then a single drain leaves the fd non-readable.
    waker.wake();
    waker.wake();
    waker.drain();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 10));
}

test "waker: disabled fd is ignored by poll" {
    var waker = Waker{ .fd = -1 };
    try std.testing.expect(!waker.enabled());
    waker.wake(); // no-op, must not crash
    waker.drain(); // no-op
    waker.deinit();
}
