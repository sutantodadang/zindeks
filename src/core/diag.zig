//! Crash diagnostics: a thread-local breadcrumb naming the work in flight when
//! a panic fires.
//!
//! Zig has no recoverable panics — an `unreachable`, out-of-bounds access,
//! null-unwrap, or integer overflow inside a worker thread (e.g. a tree-sitter
//! AST walk on a pathological source file) aborts the *whole* process. For the
//! long-lived `zindeks serve` MCP server that shows up to the client as the
//! connection "dropping". We cannot catch the panic and keep serving, but we
//! can make the abort self-identifying: each worker records the tool + file it
//! is touching, and `panicHandler` prints that breadcrumb before the default
//! handler dumps the message, stack trace, and aborts. The MCP log then names
//! the exact tool/file that killed the server instead of an anonymous trace.
const std = @import("std");

/// What this thread is doing right now. Holds borrowed slices (not copies) — the
/// caller must keep them valid for the duration of the work. Tool-name literals
/// and caller-owned file paths satisfy that. Read only from `panicHandler`.
pub const Breadcrumb = struct {
    tool: []const u8 = "",
    file: []const u8 = "",
};

threadlocal var current: Breadcrumb = .{};

pub fn setTool(tool: []const u8) void {
    current.tool = tool;
}

pub fn setFile(file: []const u8) void {
    current.file = file;
}

pub fn clear() void {
    current = .{};
}

/// Root panic handler — wired via `pub const panic` in main.zig. Logs the
/// in-flight breadcrumb for the panicking thread, then delegates to the default
/// handler for the message, stack trace, and abort.
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (current.tool.len != 0 or current.file.len != 0) {
        std.debug.print(
            "zindeks: panic in-flight tool='{s}' file='{s}'\n",
            .{ current.tool, current.file },
        );
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}
