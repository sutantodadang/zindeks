//! Benchmark harness for measuring performance.
//!
//! Provides timing, memory, and statistical utilities for scenarios.

const std = @import("std");
const builtin = @import("builtin");

pub const Benchmark = struct {
    name: []const u8,
    start_time: i64,

    pub fn start(name: []const u8) Benchmark {
        return .{
            .name = name,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn end(self: *Benchmark) u64 {
        const elapsed = std.time.milliTimestamp() - self.start_time;
        return @intCast(elapsed);
    }
};

pub const BenchmarkResult = struct {
    name: []const u8,
    elapsed_ms: u64,
    iterations: usize,
    memory_delta: i64,
};

/// Run a benchmark function `iterations` times and return aggregate results.
pub fn runBenchmark(comptime name: []const u8, comptime f: fn () void, iterations: usize) BenchmarkResult {
    var bench = Benchmark.start(name);
    for (0..iterations) |_| {
        f();
    }
    const elapsed = bench.end();

    return .{
        .name = name,
        .elapsed_ms = @divTrunc(elapsed, iterations),
        .iterations = iterations,
        .memory_delta = 0,
    };
}

// ── Statistical harness ───────────────────────────────────────────────────

pub const Stats = struct {
    name: []const u8,
    iters: usize,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p99_ns: u64,
    peak_rss_bytes: u64,
};

/// Query peak RSS of the current process. Best-effort; returns 0 on failure.
fn peakRss() u64 {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const vmc = windows.GetProcessMemoryInfo(windows.GetCurrentProcess()) catch return 0;
        return @intCast(vmc.PeakWorkingSetSize);
    } else {
        // POSIX: getrusage (returns rusage directly, no error)
        const usage = std.posix.getrusage(std.posix.rusage.SELF);
        const raw: i64 = usage.maxrss;
        if (raw <= 0) return 0;
        // Linux reports in KB, macOS in bytes
        if (comptime builtin.os.tag == .linux) {
            return @intCast(raw * 1024);
        }
        return @intCast(raw);
    }
}

/// Run `f` `iters` times, collect per-iteration ns timings, return Stats.
pub fn runScenario(
    allocator: std.mem.Allocator,
    name: []const u8,
    iters: usize,
    comptime f: fn (std.mem.Allocator) anyerror!void,
) !Stats {
    const samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);

    for (0..iters) |i| {
        const t0 = std.time.Instant.now() catch unreachable;
        try f(allocator);
        const t1 = std.time.Instant.now() catch unreachable;
        samples[i] = t1.since(t0);
    }

    std.sort.block(u64, samples, {}, std.sort.asc(u64));

    var sum: u64 = 0;
    var min_ns: u64 = samples[0];
    var max_ns: u64 = samples[samples.len - 1];
    for (samples) |s| {
        sum += s;
        if (s < min_ns) min_ns = s;
        if (s > max_ns) max_ns = s;
    }
    const mean_ns = if (iters > 0) sum / iters else 0;
    const p50_ns = samples[iters / 2];
    const p99_ns = samples[@min(iters - 1, iters * 99 / 100)];

    return .{
        .name = name,
        .iters = iters,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .p50_ns = p50_ns,
        .p99_ns = p99_ns,
        .peak_rss_bytes = peakRss(),
    };
}

pub fn printStats(stats: Stats, writer: anytype) !void {
    const rss_kb = stats.peak_rss_bytes / 1024;
    try writer.print(
        "[{s}] iters={d} min={d}ns mean={d}ns p50={d}ns p99={d}ns max={d}ns peak_rss={d}KB\n",
        .{ stats.name, stats.iters, stats.min_ns, stats.mean_ns, stats.p50_ns, stats.p99_ns, stats.max_ns, rss_kb },
    );
}

// ── Counting allocator ───────────────────────────────────────────────────────
//
// Thin allocator wrapper that tracks total bytes allocated, current live bytes,
// peak live bytes, and alloc/free call counts.  Wraps any parent allocator.
//
// Usage:
//   var ca = CountingAllocator.init(gpa);
//   const alloc = ca.allocator();
//   // ... use `alloc` everywhere ...
//   ca.report(writer);

pub const CountingAllocator = struct {
    parent: std.mem.Allocator,
    total_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live: u64 = 0,
    alloc_count: u64 = 0,
    free_count: u64 = 0,
    resize_count: u64 = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn bump(self: *CountingAllocator, n: usize) void {
        self.total_bytes += n;
        self.live_bytes += n;
        if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
        self.alloc_count += 1;
    }

    fn allocFn(ptr: *anyopaque, n: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.parent.rawAlloc(n, alignment, ret_addr);
        if (result != null) self.bump(n);
        return result;
    }

    fn resizeFn(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const ok = self.parent.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            self.resize_count += 1;
            if (new_len > buf.len) {
                const delta = new_len - buf.len;
                self.total_bytes += delta;
                self.live_bytes += delta;
                if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
            } else {
                self.live_bytes -= (buf.len - new_len);
            }
        }
        return ok;
    }

    fn remapFn(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.parent.rawRemap(buf, alignment, new_len, ret_addr);
        if (result != null) {
            self.resize_count += 1;
            if (new_len > buf.len) {
                const delta = new_len - buf.len;
                self.total_bytes += delta;
                self.live_bytes += delta;
                if (self.live_bytes > self.peak_live) self.peak_live = self.live_bytes;
            } else {
                self.live_bytes -= (buf.len - new_len);
            }
        }
        return result;
    }

    fn freeFn(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        self.parent.rawFree(buf, alignment, ret_addr);
        if (self.live_bytes >= buf.len) self.live_bytes -= buf.len else self.live_bytes = 0;
        self.free_count += 1;
    }

    pub fn report(self: *const CountingAllocator, name: []const u8, writer: anytype) !void {
        try writer.print(
            "[{s} allocs] total={d}KB peak_live={d}KB allocs={d} frees={d} resizes={d}\n",
            .{
                name,
                self.total_bytes / 1024,
                self.peak_live / 1024,
                self.alloc_count,
                self.free_count,
                self.resize_count,
            },
        );
    }
};
