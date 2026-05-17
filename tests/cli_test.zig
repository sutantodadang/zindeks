//! Tests for CLI terminal output and error formatting.

const std = @import("std");
const zindeks = @import("zindeks");

test "StyledWriter with colors disabled" {
    // Use a fixed buffer allocator to capture output
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var sw = zindeks.api.cli.terminal.StyledWriter(@TypeOf(fbs.writer())).init(fbs.writer());
    sw.setColors(false);

    // Color methods should return empty strings
    try std.testing.expectEqualStrings("", sw.red());
    try std.testing.expectEqualStrings("", sw.green());
    try std.testing.expectEqualStrings("", sw.yellow());
    try std.testing.expectEqualStrings("", sw.blue());
    try std.testing.expectEqualStrings("", sw.cyan());
    try std.testing.expectEqualStrings("", sw.bold());
    try std.testing.expectEqualStrings("", sw.reset());

    // print should work without colors
    try sw.print("hello {s}", .{"world"});
    try std.testing.expectEqualStrings("hello world", fbs.getWritten());
}

test "StyledWriter with colors enabled" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var sw = zindeks.api.cli.terminal.StyledWriter(@TypeOf(fbs.writer())).init(fbs.writer());
    sw.setColors(true);

    // Color methods should return ANSI codes
    try std.testing.expectEqualStrings("\x1b[31m", sw.red());
    try std.testing.expectEqualStrings("\x1b[32m", sw.green());
    try std.testing.expectEqualStrings("\x1b[0m", sw.reset());
}

test "StyledWriter printStyled" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var sw = zindeks.api.cli.terminal.StyledWriter(@TypeOf(fbs.writer())).init(fbs.writer());
    sw.setColors(true);

    try sw.printStyled("Warning", .{}, "\x1b[33m");
    try std.testing.expectEqualStrings("\x1b[33mWarning\x1b[0m", fbs.getWritten());
}

test "StyledWriter printStyled with colors disabled" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var sw = zindeks.api.cli.terminal.StyledWriter(@TypeOf(fbs.writer())).init(fbs.writer());
    sw.setColors(false);

    try sw.printStyled("Warning", .{}, "\x1b[33m");
    try std.testing.expectEqualStrings("Warning", fbs.getWritten());
}

test "ProgressBar formatting with colors disabled" {
    // We need to use a real ProgressBar, but it writes to stderr.
    // Instead test that the component can be created and basic fields work.
    var bar = zindeks.api.cli.terminal.ProgressBar.init(100);
    bar.writer.setColors(false);

    try std.testing.expectEqual(@as(usize, 100), bar.total);
    try std.testing.expectEqual(@as(usize, 0), bar.current);
}

test "error formatting with suggestions" {
    const testing = std.testing;

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const err = zindeks.api.cli.errors.invalidArgs("Missing required argument");
    try err.format(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Missing required argument") != null);
    try testing.expect(std.mem.indexOf(u8, output, "error") != null);
}

test "notFound error formatting" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const err = zindeks.api.cli.errors.notFound("Repository not indexed");
    try err.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Repository not indexed") != null);
}

test "permissionDenied error formatting" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const err = zindeks.api.cli.errors.permissionDenied("Cannot write to /root");
    try err.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Cannot write to /root") != null);
}

test "ioError with context" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const err = zindeks.api.cli.errors.ioError("Failed to read file", "/tmp/missing.txt");
    try err.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Failed to read file") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/tmp/missing.txt") != null);
}

test "internalError formatting" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const err = zindeks.api.cli.errors.internalError("Unexpected null pointer");
    try err.format(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Unexpected null pointer") != null);
}
