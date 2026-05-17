//! Benchmark harness for measuring performance.
//!
//! Provides simple timing and measurement utilities.

const std = @import("std");

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
