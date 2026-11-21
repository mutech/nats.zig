//! Server Pool for Reconnection
//!
//! Manages multiple servers for reconnection with round-robin rotation.
//! Servers are discovered from initial URL and INFO connect_urls.

const std = @import("std");
const assert = std.debug.assert;
const defaults = @import("../defaults.zig");

/// Maximum number of servers in the pool.
pub const MAX_SERVERS: u8 = defaults.Server.max_pool_size;

/// Maximum URL length.
pub const MAX_URL_LEN: u16 = defaults.Server.max_url_len;

/// Cooldown period after failure before retry (ns).
const FAILURE_COOLDOWN_NS: u64 = defaults.Server.failure_cooldown_ns;

/// URL scheme prefix of UNIX domain socket URLs. Matched without the `//`, so
/// that `nats+uds:/abs` is a UDS URL too and never falls through to TCP.
pub const uds_scheme = "nats+uds:";

/// Parts of a nats+uds URL, as slices into the URL.
pub const UdsUrl = struct {
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    /// Absolute socket path, verbatim.
    path: []const u8,
};

/// Parses a URL starting with `uds_scheme`. Permissive, as nats.py's
/// contract: any URL whose remainder after `nats+uds:` starts with `/` is
/// accepted (`nats+uds:/abs`, `nats+uds:///abs`). Userinfo is taken only from
/// a `//` authority before the path, so an `@` inside the path stays part of
/// the path; a host in the authority is ignored. Rejected is what cannot mean
/// a socket: a port, query, fragment, or a missing or relative path.
pub fn parseUdsUrl(url: []const u8) error{InvalidUrl}!UdsUrl {
    assert(std.mem.startsWith(u8, url, uds_scheme));
    var rest = url[uds_scheme.len..];
    if (std.mem.findAny(u8, rest, "?#") != null) return error.InvalidUrl;

    var result: UdsUrl = .{ .path = undefined };
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const authority_end = std.mem.findScalar(u8, rest, '/') orelse
            return error.InvalidUrl;
        var host = rest[0..authority_end];
        rest = rest[authority_end..];
        if (std.mem.findScalarLast(u8, host, '@')) |at| {
            const userinfo = host[0..at];
            host = host[at + 1 ..];
            if (std.mem.findScalar(u8, userinfo, ':')) |colon| {
                result.user = userinfo[0..colon];
                result.pass = userinfo[colon + 1 ..];
            } else {
                result.user = userinfo;
            }
        }
        // A port (any `:` after the host, past an IPv6 literal) cannot
        // apply to a socket.
        const port_from = if (host.len > 0 and host[0] == '[')
            std.mem.findScalar(u8, host, ']') orelse return error.InvalidUrl
        else
            0;
        if (std.mem.findScalar(u8, host[port_from..], ':') != null)
            return error.InvalidUrl;
    }
    if (rest.len < 2 or rest[0] != '/') return error.InvalidUrl;
    result.path = rest;
    assert(result.path.len >= 2 and result.path[0] == '/');
    return result;
}

/// Server entry in the pool.
pub const Server = struct {
    url: [MAX_URL_LEN]u8 = undefined,
    url_len: u8 = 0,
    host_start: u8 = 0,
    host_len: u8 = 0,
    port: u16 = defaults.Protocol.port,
    consecutive_failures: u8 = 0,
    last_attempt_ns: u64 = 0,
    /// Whether this server uses TLS (from tls:// scheme).
    use_tls: bool = false,
    /// Whether this server is reached over a UNIX domain socket
    /// (from nats+uds:// scheme). When true, getHost() is the socket path.
    is_uds: bool = false,

    /// Get the URL as a slice.
    pub fn getUrl(self: *const Server) []const u8 {
        return self.url[0..self.url_len];
    }

    /// Get the host as a slice.
    pub fn getHost(self: *const Server) []const u8 {
        return self.url[self.host_start..][0..self.host_len];
    }
};

/// Server pool for reconnection rotation.
pub const ServerPool = struct {
    servers: [MAX_SERVERS]Server = undefined,
    count: u8 = 0,
    current_idx: u8 = 0,
    primary_idx: u8 = 0,

    /// Initialize server pool with primary server URL.
    pub fn init(primary_url: []const u8) error{InvalidUrl}!ServerPool {
        var pool: ServerPool = .{};

        if (primary_url.len == 0 or primary_url.len >= MAX_URL_LEN) {
            return error.InvalidUrl;
        }

        pool.addServer(primary_url) catch return error.InvalidUrl;
        pool.primary_idx = 0;

        assert(pool.count > 0);
        return pool;
    }

    /// Add a server to the pool. Returns false if pool is full or URL invalid.
    pub fn addServer(self: *ServerPool, url: []const u8) !void {
        if (self.count >= MAX_SERVERS) return error.PoolFull;
        if (url.len == 0 or url.len >= MAX_URL_LEN) return error.InvalidUrl;

        for (self.servers[0..self.count]) |*existing| {
            if (std.mem.eql(u8, existing.getUrl(), url)) {
                return;
            }
        }

        var server: Server = .{};

        const url_len: u8 = @intCast(url.len);
        @memcpy(server.url[0..url_len], url);
        server.url_len = url_len;

        var remaining = url;

        if (std.mem.startsWith(u8, remaining, "tls://")) {
            remaining = remaining[6..];
            server.host_start = 6;
            server.use_tls = true;
        } else if (std.mem.startsWith(u8, remaining, uds_scheme)) {
            // The socket path is the host; there is no port.
            const path = (try parseUdsUrl(url)).path;
            if (path.len > 255) return error.InvalidUrl;
            server.host_start = @intCast(@intFromPtr(path.ptr) - @intFromPtr(url.ptr));
            server.host_len = @intCast(path.len);
            server.port = 0;
            server.is_uds = true;
            assert(server.host_len > 0);
            self.servers[self.count] = server;
            self.count += 1;
            return;
        } else if (std.mem.startsWith(u8, remaining, "nats://")) {
            remaining = remaining[7..];
            server.host_start = 7;
        }

        if (std.mem.find(u8, remaining, "@")) |at_pos| {
            remaining = remaining[at_pos + 1 ..];
            server.host_start += @intCast(at_pos + 1);
        }

        if (remaining.len > 0 and remaining[0] == '[') {
            // IPv6 literal: [::1]:port
            if (std.mem.find(
                u8,
                remaining,
                "]",
            )) |bracket_end| {
                server.host_start += 1; // skip '['
                server.host_len = @intCast(
                    bracket_end - 1,
                );
                const after = remaining[bracket_end + 1 ..];
                if (after.len > 1 and after[0] == ':') {
                    server.port = std.fmt.parseInt(
                        u16,
                        after[1..],
                        10,
                    ) catch 4222;
                }
            } else {
                // Malformed IPv6 — treat as host
                server.host_len = @intCast(
                    remaining.len,
                );
            }
        } else if (std.mem.find(
            u8,
            remaining,
            ":",
        )) |colon_pos| {
            if (colon_pos > 255) return error.InvalidUrl;
            server.host_len = @intCast(colon_pos);
            server.port = std.fmt.parseInt(
                u16,
                remaining[colon_pos + 1 ..],
                10,
            ) catch 4222;
        } else {
            if (remaining.len > 255)
                return error.InvalidUrl;
            server.host_len = @intCast(remaining.len);
            server.port = 4222;
        }

        assert(server.host_len > 0);
        assert(server.port > 0);

        self.servers[self.count] = server;
        self.count += 1;
    }

    /// Add servers from ServerInfo connect_urls.
    /// Returns the number of new servers that were added (not duplicates).
    pub fn addFromConnectUrls(
        self: *ServerPool,
        urls: []const [256]u8,
        lens: []const u8,
        count: u8,
    ) u8 {
        assert(urls.len >= count);
        assert(lens.len >= count);

        const before = self.count;
        for (0..count) |i| {
            const len = lens[i];
            if (len == 0) continue;
            const url = urls[i][0..len];
            self.addServer(url) catch continue;
        }
        return self.count - before;
    }

    /// Get next server for connection attempt (round-robin).
    /// Skips servers that failed recently (cooldown).
    /// Returns null if all servers are on cooldown.
    pub fn nextServer(self: *ServerPool, now_ns: u64) ?*Server {
        if (self.count == 0) return null;

        assert(self.count > 0);
        assert(self.current_idx < self.count);

        var attempts: u8 = 0;
        while (attempts < self.count) : (attempts += 1) {
            self.current_idx = (self.current_idx + 1) % self.count;
            var server = &self.servers[self.current_idx];

            if (server.consecutive_failures > 0) {
                const cooldown = FAILURE_COOLDOWN_NS *
                    @as(u64, server.consecutive_failures);
                if (now_ns - server.last_attempt_ns < cooldown) {
                    continue;
                }
            }

            server.last_attempt_ns = now_ns;
            return server;
        }

        return null;
    }

    /// Mark current server as failed.
    pub fn markCurrentFailed(self: *ServerPool) void {
        if (self.count == 0) return;
        assert(self.current_idx < self.count);

        var server = &self.servers[self.current_idx];
        if (server.consecutive_failures < 255) {
            server.consecutive_failures += 1;
        }
    }

    /// Reset all failure counts (called on successful connect).
    pub fn resetFailures(self: *ServerPool) void {
        for (self.servers[0..self.count]) |*server| {
            server.consecutive_failures = 0;
        }
    }

    /// Get current server URL as slice.
    pub fn currentUrl(self: *const ServerPool) []const u8 {
        if (self.count == 0) return "none";
        assert(self.current_idx < self.count);
        return self.servers[self.current_idx].getUrl();
    }

    /// Get current server.
    pub fn current(self: *ServerPool) ?*Server {
        if (self.count == 0) return null;
        assert(self.current_idx < self.count);
        return &self.servers[self.current_idx];
    }

    /// Get server count.
    pub fn serverCount(self: *const ServerPool) u8 {
        return self.count;
    }
};

test "server pool init" {
    const pool = try ServerPool.init("nats://localhost:4222");
    try std.testing.expectEqual(@as(u8, 1), pool.count);
    try std.testing.expectEqualStrings(
        "nats://localhost:4222",
        pool.servers[0].getUrl(),
    );
    try std.testing.expectEqualStrings("localhost", pool.servers[0].getHost());
    try std.testing.expectEqual(@as(u16, 4222), pool.servers[0].port);
}

test "server pool init with auth" {
    const pool = try ServerPool.init("nats://user:pass@localhost:4222");
    try std.testing.expectEqual(@as(u8, 1), pool.count);
    try std.testing.expectEqualStrings("localhost", pool.servers[0].getHost());
    try std.testing.expectEqual(@as(u16, 4222), pool.servers[0].port);
}

test "server pool init without port" {
    const pool = try ServerPool.init("nats://localhost");
    try std.testing.expectEqual(@as(u8, 1), pool.count);
    try std.testing.expectEqualStrings("localhost", pool.servers[0].getHost());
    try std.testing.expectEqual(@as(u16, 4222), pool.servers[0].port);
}

test "server pool init without scheme" {
    const pool = try ServerPool.init("localhost:4222");
    try std.testing.expectEqual(@as(u8, 1), pool.count);
    try std.testing.expectEqualStrings("localhost", pool.servers[0].getHost());
    try std.testing.expectEqual(@as(u16, 4222), pool.servers[0].port);
}

test "server pool add servers" {
    var pool = try ServerPool.init("nats://server1:4222");
    try pool.addServer("nats://server2:4222");
    try pool.addServer("nats://server3:4222");

    try std.testing.expectEqual(@as(u8, 3), pool.count);
}

test "server pool deduplication" {
    var pool = try ServerPool.init("nats://localhost:4222");
    try pool.addServer("nats://localhost:4222"); // Duplicate
    try pool.addServer("nats://localhost:4222"); // Duplicate

    try std.testing.expectEqual(@as(u8, 1), pool.count);
}

test "server pool rotation" {
    var pool = try ServerPool.init("nats://server1:4222");
    try pool.addServer("nats://server2:4222");
    try pool.addServer("nats://server3:4222");

    const now: u64 = 1000000000000;

    // Should rotate through servers
    const s1 = pool.nextServer(now).?;
    try std.testing.expectEqualStrings("nats://server2:4222", s1.getUrl());

    const s2 = pool.nextServer(now).?;
    try std.testing.expectEqualStrings("nats://server3:4222", s2.getUrl());

    const s3 = pool.nextServer(now).?;
    try std.testing.expectEqualStrings("nats://server1:4222", s3.getUrl());
}

test "server pool failure tracking" {
    var pool = try ServerPool.init("nats://server1:4222");

    var now: u64 = 1000000000000;

    // Get server and mark as failed
    _ = pool.nextServer(now);
    pool.markCurrentFailed();

    try std.testing.expectEqual(@as(u8, 1), pool.servers[0].consecutive_failures);

    // Should be on cooldown
    now += 1000000000; // +1 second (cooldown is 5 seconds)
    try std.testing.expect(pool.nextServer(now) == null);

    // After cooldown, should be available
    now += 10000000000; // +10 seconds
    try std.testing.expect(pool.nextServer(now) != null);
}

test "server pool reset failures" {
    var pool = try ServerPool.init("nats://server1:4222");

    _ = pool.nextServer(0);
    pool.markCurrentFailed();
    pool.markCurrentFailed();

    try std.testing.expectEqual(@as(u8, 2), pool.servers[0].consecutive_failures);

    pool.resetFailures();

    try std.testing.expectEqual(@as(u8, 0), pool.servers[0].consecutive_failures);
}

test "server pool empty url" {
    const result = ServerPool.init("");
    try std.testing.expectError(error.InvalidUrl, result);
}

test "server pool tls scheme" {
    const pool = try ServerPool.init("tls://secure.example.com:4222");
    try std.testing.expectEqual(@as(u8, 1), pool.count);
    try std.testing.expectEqualStrings("secure.example.com", pool.servers[0].getHost());
    try std.testing.expectEqual(@as(u16, 4222), pool.servers[0].port);
    try std.testing.expect(pool.servers[0].use_tls);
}

test "server pool nats scheme not tls" {
    const pool = try ServerPool.init("nats://localhost:4222");
    try std.testing.expect(!pool.servers[0].use_tls);
}

test "server pool mixed schemes" {
    var pool = try ServerPool.init("nats://server1:4222");
    try pool.addServer("tls://server2:4222");

    try std.testing.expectEqual(@as(u8, 2), pool.count);
    try std.testing.expect(!pool.servers[0].use_tls);
    try std.testing.expect(pool.servers[1].use_tls);
}

test "server pool nats+uds scheme" {
    const pool = try ServerPool.init("nats+uds:///run/snats/snats.sock");
    try std.testing.expectEqual(@as(u8, 1), pool.count);
    try std.testing.expect(pool.servers[0].is_uds);
    try std.testing.expect(!pool.servers[0].use_tls);
    try std.testing.expectEqualStrings(
        "/run/snats/snats.sock",
        pool.servers[0].getHost(),
    );
    try std.testing.expectEqual(@as(u16, 0), pool.servers[0].port);
}

test "server pool nats+uds with user" {
    const pool = try ServerPool.init("nats+uds://user:pass@/tmp/snats.sock");
    try std.testing.expect(pool.servers[0].is_uds);
    try std.testing.expectEqualStrings("/tmp/snats.sock", pool.servers[0].getHost());
}

test "server pool nats+uds missing path" {
    try std.testing.expectError(error.InvalidUrl, ServerPool.init("nats+uds://"));
}

test "parseUdsUrl accepts path forms" {
    const Case = struct {
        url: []const u8,
        path: []const u8,
        user: ?[]const u8 = null,
        pass: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{ .url = "nats+uds:///tmp/x.sock", .path = "/tmp/x.sock" },
        .{ .url = "nats+uds:/tmp/x.sock", .path = "/tmp/x.sock" },
        .{ .url = "nats+uds://localhost/tmp/x.sock", .path = "/tmp/x.sock" },
        .{ .url = "nats+uds://[::1]/tmp/x.sock", .path = "/tmp/x.sock" },
        .{ .url = "nats+uds:///tmp/dir:weird/x.sock", .path = "/tmp/dir:weird/x.sock" },
        // An `@` in the path is part of the path, never userinfo.
        .{ .url = "nats+uds:///run/a@b/s.sock", .path = "/run/a@b/s.sock" },
        .{ .url = "nats+uds:/run/a@b/s.sock", .path = "/run/a@b/s.sock" },
        .{
            .url = "nats+uds://user:pass@/tmp/x.sock",
            .path = "/tmp/x.sock",
            .user = "user",
            .pass = "pass",
        },
        .{ .url = "nats+uds://user@/tmp/x.sock", .path = "/tmp/x.sock", .user = "user" },
        .{
            .url = "nats+uds://u:p@localhost/run/a@b/s.sock",
            .path = "/run/a@b/s.sock",
            .user = "u",
            .pass = "p",
        },
    };
    for (cases) |c| {
        const parsed = try parseUdsUrl(c.url);
        try std.testing.expectEqualStrings(c.path, parsed.path);
        if (c.user) |u| {
            try std.testing.expectEqualStrings(u, parsed.user.?);
        } else try std.testing.expect(parsed.user == null);
        if (c.pass) |pw| {
            try std.testing.expectEqualStrings(pw, parsed.pass.?);
        } else try std.testing.expect(parsed.pass == null);
    }
}

test "parseUdsUrl rejects what cannot be a socket" {
    const urls = [_][]const u8{
        "nats+uds://localhost:4222/tmp/x.sock",
        "nats+uds://:4222/tmp/x.sock",
        "nats+uds://user:pass@localhost:4222/tmp/x.sock",
        "nats+uds://[::1]:4222/tmp/x.sock",
        "nats+uds:",
        "nats+uds:/",
        "nats+uds://",
        "nats+uds:///",
        "nats+uds:relative.sock",
        "nats+uds://sock",
        "nats+uds://localhost",
        "nats+uds://user@",
        "nats+uds:///tmp/x.sock?mode=rw",
        "nats+uds:///tmp/x.sock#frag",
        "nats+uds:/tmp/x.sock?mode=rw",
    };
    for (urls) |url| {
        try std.testing.expectError(error.InvalidUrl, parseUdsUrl(url));
    }
}

test "server pool nats+uds forms" {
    var pool = try ServerPool.init("nats+uds:/run/snats/snats.sock");
    try pool.addServer("nats+uds:///run/a@b/s.sock");
    try std.testing.expectEqual(@as(u8, 2), pool.count);
    try std.testing.expect(pool.servers[0].is_uds);
    try std.testing.expectEqualStrings("/run/snats/snats.sock", pool.servers[0].getHost());
    try std.testing.expect(pool.servers[1].is_uds);
    try std.testing.expectEqualStrings("/run/a@b/s.sock", pool.servers[1].getHost());
    try std.testing.expectEqual(@as(u16, 0), pool.servers[1].port);

    // Never reinterpreted as TCP.
    try std.testing.expectError(error.InvalidUrl, pool.addServer("nats+uds:relative.sock"));
    try std.testing.expectError(error.InvalidUrl, pool.addServer("nats+uds://localhost:4222/s"));
    try std.testing.expectEqual(@as(u8, 2), pool.count);
}

test "server pool nats scheme not uds" {
    const pool = try ServerPool.init("nats://localhost:4222");
    try std.testing.expect(!pool.servers[0].is_uds);
}
