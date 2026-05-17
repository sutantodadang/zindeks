//! Terminal output helpers: ANSI colors, progress bars, spinners.
//!
//! Auto-detects TTY — disables colors and progress when piping (unless overridden).

const std = @import("std");
const builtin = @import("builtin");

const FileWriter = @TypeOf(std.fs.File.stderr().deprecatedWriter());

// ── ANSI escape codes ────────────────────────────────────────────────

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
};

/// Check if stderr is a TTY. On Windows, use kernel32 GetConsoleMode.
pub fn isTty() bool {
    if (builtin.os.tag == .windows) {
        return isTtyWindows();
    }
    return std.posix.isatty(std.posix.STDERR_FILENO);
}

fn isTtyWindows() bool {
    const windows = std.os.windows;
    const stderr_handle = windows.GetStdHandle(windows.STD_ERROR_HANDLE) catch return false;
    var mode: windows.DWORD = 0;
    return windows.kernel32.GetConsoleMode(stderr_handle, &mode) != 0;
}

// ── StyledWriter ─────────────────────────────────────────────────────

/// Writer wrapper that adds color methods. Passes through to underlying
/// writer when colors are disabled (non-TTY, piping, or CI).
pub fn StyledWriter(comptime WriterType: type) type {
    return struct {
        writer: WriterType,
        colors_enabled: bool,

        const Self = @This();

        pub fn init(w: WriterType) Self {
            return .{ .writer = w, .colors_enabled = isTty() };
        }

        pub fn setColors(self: *Self, enabled: bool) void {
            self.colors_enabled = enabled;
        }

        pub fn red(self: Self) []const u8 { return if (self.colors_enabled) ansi.red else ""; }
        pub fn green(self: Self) []const u8 { return if (self.colors_enabled) ansi.green else ""; }
        pub fn yellow(self: Self) []const u8 { return if (self.colors_enabled) ansi.yellow else ""; }
        pub fn blue(self: Self) []const u8 { return if (self.colors_enabled) ansi.blue else ""; }
        pub fn cyan(self: Self) []const u8 { return if (self.colors_enabled) ansi.cyan else ""; }
        pub fn magenta(self: Self) []const u8 { return if (self.colors_enabled) ansi.magenta else ""; }
        pub fn bold(self: Self) []const u8 { return if (self.colors_enabled) ansi.bold else ""; }
        pub fn dim(self: Self) []const u8 { return if (self.colors_enabled) ansi.dim else ""; }
        pub fn reset(self: Self) []const u8 { return if (self.colors_enabled) ansi.reset else ""; }

        /// Print formatted with style prefix/suffix.
        pub fn printStyled(self: Self, comptime fmt: []const u8, args: anytype, comptime style: []const u8) !void {
            if (self.colors_enabled) try self.writer.writeAll(style);
            try self.writer.print(fmt, args);
            if (self.colors_enabled) try self.writer.writeAll(ansi.reset);
        }

        /// Write raw bytes (for Writer interface).
        pub fn writeAll(self: Self, bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }

        /// Print formatted (for Writer interface).
        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self.writer.print(fmt, args);
        }

        /// Write a single byte.
        pub fn writeByte(self: Self, byte: u8) !void {
            try self.writer.writeByte(byte);
        }
    };
}

// ── ProgressBar ──────────────────────────────────────────────────────

pub const ProgressBar = struct {
    out_buf: [4096]u8 = undefined,
    writer: StyledWriter(FileWriter),
    total: usize,
    current: usize,
    bar_width: usize,
    label_buf: [256]u8,
    last_redraw_ms: i64,
    const Self = @This();

    pub fn init(total_count: usize) Self {
        return Self{
            .writer = StyledWriter(FileWriter).init(std.fs.File.stderr().deprecatedWriter()),
            .total = total_count,
            .current = 0,
            .bar_width = 30,
            .label_buf = undefined,
            .last_redraw_ms = 0,
        };
    }

    /// Update progress with current count and optional label.
    pub fn update(self: *Self, current: usize, label: ?[]const u8) void {
        if (!self.writer.colors_enabled) return;

        self.current = @min(current, self.total);

        const now = std.time.milliTimestamp();
        if (now - self.last_redraw_ms < 50 and current < self.total) return;
        self.last_redraw_ms = now;

        const pct: f64 = if (self.total > 0)
            @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total))
        else
            1.0;

        const filled = @as(usize, @intFromFloat(pct * @as(f64, @floatFromInt(self.bar_width))));
        const bar = self.label_buf[0..self.bar_width];
        @memset(bar, ' ');
        for (0..filled) |i| bar[i] = '=';
        if (filled > 0 and filled < self.bar_width) bar[filled] = '>';

        // Clear line and print
        const text = std.fmt.bufPrintZ(
            &self.label_buf[self.bar_width..],
            "\r{s}[{s}{s}{s}] {d:>3.0}% ({d}/{d}){s}{s}",
            .{
                self.writer.bold(),
                self.writer.green(),
                bar,
                self.writer.reset(),
                pct * 100.0,
                self.current,
                self.total,
                if (label) |l| "  " ++ l else "",
                "\x1b[K",
            },
        ) catch return;

        self.writer.writeAll(text) catch {};
    }

    /// Mark progress complete and print final line.
    pub fn finish(self: *Self) void {
        if (!self.writer.colors_enabled) return;
        self.update(self.total, null);
        self.writer.writeAll("\n") catch {};
    }
};

// ── Spinner ──────────────────────────────────────────────────────────

pub const Spinner = struct {
    out_buf: [4096]u8 = undefined,
    writer: StyledWriter(FileWriter),
    frames: []const []const u8,
    current_frame: usize,
    message: []const u8 = "",
    running: bool = false,
    last_redraw_ms: i64 = 0,

    const Self = @This();

    pub fn init(message: []const u8) Self {
        var self = Self{
            .writer = undefined,
            .frames = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
            .current_frame = 0,
            .message = message,
        };
        self.writer = StyledWriter(FileWriter).init(
            std.fs.File.stderr().deprecatedWriter(),
        );
        return self;
    }

    pub fn start(self: *Self) void {
        if (!self.writer.colors_enabled) {
            self.writer.print("{s}...\n", .{self.message}) catch {};
            return;
        }
        self.running = true;
        self.tick();
    }

    pub fn tick(self: *Self) void {
        if (!self.running) return;

        const now = std.time.milliTimestamp();
        if (now - self.last_redraw_ms < 80) return;
        self.last_redraw_ms = now;

        const frame = self.frames[self.current_frame];
        self.current_frame = (self.current_frame + 1) % self.frames.len;

        self.writer.writeAll("\r\x1b[K") catch {};
        self.writer.print("{s}{s} {s}{s}", .{
            self.writer.cyan(),
            frame,
            self.message,
            self.writer.reset(),
        }) catch {};
    }

    pub fn done(self: *Self, success: bool) void {
        if (!self.writer.colors_enabled) return;
        const symbol = if (success) "✓" else "✗";
        const color = if (success) self.writer.green() else self.writer.red();
        self.writer.writeAll("\r\x1b[K") catch {};
        self.writer.print("{s}{s} {s}{s}\n", .{ color, symbol, self.message, self.writer.reset() }) catch {};
        self.running = false;
    }
};
