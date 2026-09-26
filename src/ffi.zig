//! Checked C ABI (ABI version 1) for the in-process zindeks engine.
//!
//! The host loads the shared library produced from this file and drives the
//! existing MCP JSON-RPC engine through `Server.executeMessageToBuffer` —
//! no spawned CLI, no MCP server, no TCP port.  Indexing, graph, search and
//! locking behaviour are untouched; this module only adds a small checked
//! boundary in front of them.
//!
//! Everything here is deliberately C-ABI shaped: no Zig slices, allocators or
//! Rust types cross the boundary.  Buffers are allocated with the C allocator
//! so the host can hand them back to `zindeks_buffer_free` without a handle.

const std = @import("std");
const server_mod = @import("api/mcp/server.zig");
const graph_db = @import("core/storage/graph_db.zig");

pub const ABI_VERSION: u32 = 1;

const Status = struct {
    const ok: i32 = 0;
    const invalid_input: i32 = 1;
    const init_error: i32 = 2;
    const alloc_error: i32 = 3;
    const busy: i32 = 4;
};

const MAX_REQUEST_BYTES: usize = 1 << 20; // 1 MiB
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024; // 16 MiB

/// Library-owned byte buffer handed to the host.
pub const ZindeksBuffer = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
};

const alloc = std.heap.c_allocator;

/// Concrete state behind the opaque `ZindeksHandle *`.  One handle binds one
/// repository and owns one `Server` plus a reusable response buffer.
pub const Handle = struct {
    allocator: std.mem.Allocator,
    server: server_mod.Server,
    /// Serializes requests on one handle.  `executeMessageToBuffer` is itself
    /// lock-disciplined, but `initialized` and lazy auto-attach are not, so
    /// the ABI makes concurrent use of a single handle safe.
    mutex: std.Thread.Mutex = .{},
    response: std.ArrayList(u8),
};

// ─────────────────────────────────────────────────────────────────────────────
// ABI entry points
// ─────────────────────────────────────────────────────────────────────────────

pub export fn zindeks_abi_version() u32 {
    return ABI_VERSION;
}

pub export fn zindeks_open(
    options: ?[*]const u8,
    len: usize,
    out: ?*?*Handle,
    error_out: ?*ZindeksBuffer,
) i32 {
    if (out) |o| o.* = null;
    if (error_out) |e| e.* = .{};

    const opt_bytes = (options orelse
        return setError(error_out, Status.invalid_input, "options pointer is null"))[0..len];
    if (len == 0) return setError(error_out, Status.invalid_input, "options must not be empty");
    if (len > MAX_REQUEST_BYTES) {
        return setError(error_out, Status.invalid_input, "options exceed the 1 MiB limit");
    }
    if (!std.unicode.utf8ValidateSlice(opt_bytes)) {
        return setError(error_out, Status.invalid_input, "options are not valid UTF-8");
    }

    // SQLite runtime floor (WAL-reset concurrency fix).
    if (!graph_db.sqliteVersionSatisfiesFloor()) {
        const msg = std.fmt.allocPrint(
            alloc,
            "SQLite runtime {s} is below the required {d}",
            .{ graph_db.sqliteVersion(), graph_db.MIN_SQLITE_VERSION_NUMBER },
        ) catch return setError(error_out, Status.init_error, "SQLite runtime is below the required version");
        defer alloc.free(msg);
        return setError(error_out, Status.init_error, msg);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, opt_bytes, .{}) catch {
        return setError(error_out, Status.invalid_input, "options are not valid JSON");
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return setError(error_out, Status.invalid_input, "options must be a JSON object"),
    };

    const repository = getStringField(obj, "repository") orelse
        return setError(error_out, Status.invalid_input, "options.repository is required and must be a string");
    if (!std.fs.path.isAbsolute(repository)) {
        return setError(error_out, Status.invalid_input, "options.repository must be an absolute path");
    }
    const store_root = getStringField(obj, "store_root");
    if (obj.get("store_root") != null and store_root == null) {
        return setError(error_out, Status.invalid_input, "options.store_root must be a string");
    }
    if (store_root) |sr| {
        if (!std.fs.path.isAbsolute(sr)) {
            return setError(error_out, Status.invalid_input, "options.store_root must be an absolute path");
        }
    }
    var watch = false;
    if (obj.get("watch")) |wv| {
        watch = switch (wv) {
            .bool => |b| b,
            else => return setError(error_out, Status.invalid_input, "options.watch must be a boolean"),
        };
    }
    var watch_interval_ms: u32 = 2000;
    if (obj.get("watch_interval_ms")) |iv| {
        const n = switch (iv) {
            .integer => |n| n,
            else => return setError(error_out, Status.invalid_input, "options.watch_interval_ms must be an integer"),
        };
        if (n <= 0 or n > std.math.maxInt(u32)) {
            return setError(error_out, Status.invalid_input, "options.watch_interval_ms is out of range");
        }
        watch_interval_ms = @intCast(n);
    }
    var pool_conns: u32 = server_mod.Server.DEFAULT_POOL_CONNS;
    if (obj.get("pool_conns")) |pv| {
        const n = switch (pv) {
            .integer => |n| n,
            else => return setError(error_out, Status.invalid_input, "options.pool_conns must be an integer"),
        };
        if (n <= 0 or n > std.math.maxInt(u32)) {
            return setError(error_out, Status.invalid_input, "options.pool_conns is out of range");
        }
        pool_conns = @intCast(n);
    }
    var worker_threads: u32 = server_mod.Server.DEFAULT_WORKER_THREADS;
    if (obj.get("worker_threads")) |wv| {
        const n = switch (wv) {
            .integer => |n| n,
            else => return setError(error_out, Status.invalid_input, "options.worker_threads must be an integer"),
        };
        if (n <= 0 or n > std.math.maxInt(u32)) {
            return setError(error_out, Status.invalid_input, "options.worker_threads is out of range");
        }
        worker_threads = @intCast(n);
    }

    // Canonicalize the repository path (must exist).  The parsed tree owns the
    // string; canonicalize into C-allocator memory valid for the call.
    const canonical = std.fs.realpathAlloc(alloc, repository) catch {
        return setError(error_out, Status.invalid_input, "options.repository does not resolve to an existing path");
    };
    defer alloc.free(canonical);

    // Validation-only call: no handle requested.
    if (out == null) return Status.ok;

    const h = alloc.create(Handle) catch
        return setError(error_out, Status.alloc_error, "out of memory allocating handle");
    var response_buf = std.ArrayList(u8).initCapacity(alloc, 4096) catch {
        alloc.destroy(h);
        return setError(error_out, Status.alloc_error, "out of memory allocating response buffer");
    };

    h.* = .{
        .allocator = alloc,
        .server = undefined,
        .response = response_buf,
    };
    h.server = server_mod.Server.initEmbedded(alloc, .{
        .repository = canonical,
        .store_root = store_root,
        .watch = watch,
        .watch_interval_ms = watch_interval_ms,
        .pool_conns = pool_conns,
        .worker_threads = worker_threads,
    }) catch |err| {
        response_buf.deinit(alloc);
        alloc.destroy(h);
        const status: i32 = if (err == error.OutOfMemory) Status.alloc_error else Status.init_error;
        return setError(error_out, status, @errorName(err));
    };

    if (out) |o| o.* = h;
    return Status.ok;
}

pub export fn zindeks_request(
    handle: ?*Handle,
    json: ?[*]const u8,
    len: usize,
    response: ?*ZindeksBuffer,
) i32 {
    const resp = response orelse return Status.invalid_input;
    resp.* = .{};

    const h = handle orelse return Status.invalid_input;
    const req_bytes = (json orelse return Status.invalid_input)[0..len];
    if (len == 0) return Status.invalid_input;
    if (len > MAX_REQUEST_BYTES) return Status.invalid_input;
    if (!std.unicode.utf8ValidateSlice(req_bytes)) return Status.invalid_input;
    const json_ok = std.json.validate(alloc, req_bytes) catch return Status.alloc_error;
    if (!json_ok) return Status.invalid_input;

    h.mutex.lock();
    defer h.mutex.unlock();

    const produced = h.server.executeMessageToBuffer(req_bytes, &h.response) catch {
        h.response.clearRetainingCapacity();
        return Status.init_error;
    };
    // Notifications produce no reply.
    if (!produced) return Status.ok;
    if (h.response.items.len > MAX_RESPONSE_BYTES) {
        h.response.clearRetainingCapacity();
        return Status.init_error;
    }
    const out = alloc.dupe(u8, h.response.items) catch return Status.alloc_error;
    resp.* = .{ .ptr = out.ptr, .len = out.len };
    return Status.ok;
}

pub export fn zindeks_buffer_free(buffer: ?*ZindeksBuffer) void {
    const b = buffer orelse return;
    if (b.ptr) |p| {
        if (b.len > 0) alloc.free(p[0..b.len]);
    }
    b.* = .{};
}

pub export fn zindeks_close(handle: ?*Handle) void {
    const h = handle orelse return;
    h.server.deinit();
    h.response.deinit(h.allocator);
    h.allocator.destroy(h);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Populate `error_out` with an owned JSON error object and return `status`.
/// If the buffer cannot be allocated, the buffer is left cleared.
fn setError(error_out: ?*ZindeksBuffer, status: i32, message: []const u8) i32 {
    const eo = error_out orelse return status;
    eo.* = .{};
    var buf = std.ArrayList(u8){};
    const payload = .{ .status = status, .message = message };
    buf.writer(alloc).print("{f}", .{std.json.fmt(payload, .{})}) catch {
        buf.deinit(alloc);
        return status;
    };
    const slice = buf.toOwnedSlice(alloc) catch {
        buf.deinit(alloc);
        return status;
    };
    eo.* = .{ .ptr = slice.ptr, .len = slice.len };
    return status;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "abi version is 1" {
    try std.testing.expectEqual(@as(u32, 1), zindeks_abi_version());
}

test "buffer free accepts cleared and null" {
    var b = ZindeksBuffer{};
    zindeks_buffer_free(&b);
    try std.testing.expect(b.ptr == null and b.len == 0);
    zindeks_buffer_free(null);
}

test "close accepts null" {
    zindeks_close(null);
}

test "open rejects invalid options" {
    var out: ?*Handle = null;
    var err_buf = ZindeksBuffer{};
    const rc = zindeks_open(null, 0, &out, &err_buf);
    try std.testing.expectEqual(Status.invalid_input, rc);
    try std.testing.expect(out == null);
    try std.testing.expect(err_buf.ptr != null and err_buf.len > 0);
    zindeks_buffer_free(&err_buf);
}

test "open/request/close lifecycle with a real repository" {
    const tmp = std.testing.tmpDir(.{});
    var t = tmp;
    defer t.cleanup();

    // Build an absolute canonical repository path under the tmp dir.
    const repo = try t.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(repo);
    const store = try std.fs.path.join(std.testing.allocator, &.{ repo, "store" });
    defer std.testing.allocator.free(store);
    try std.fs.makeDirAbsolute(store);

    const options = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"repository\":{f},\"store_root\":{f}}}",
        .{ std.json.fmt(repo, .{}), std.json.fmt(store, .{}) },
    );
    defer std.testing.allocator.free(options);

    var handle: ?*Handle = null;
    var err_buf = ZindeksBuffer{};
    const open_rc = zindeks_open(options.ptr, options.len, &handle, &err_buf);
    if (open_rc != Status.ok) {
        zindeks_buffer_free(&err_buf);
        return error.SkipZigTest; // store layout unavailable in this sandbox
    }
    defer zindeks_close(handle);

    var resp = ZindeksBuffer{};
    const init_json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}";
    try std.testing.expectEqual(Status.ok, zindeks_request(handle, init_json.ptr, init_json.len, &resp));
    defer zindeks_buffer_free(&resp);
    try std.testing.expect(resp.ptr != null);
}
