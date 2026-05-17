//! Structured CLI error messages with colored output and suggestions.
//!
//! Each error carries a category, message, suggestion text, and optional
//! context.  formatError writes a human-readable diagnostic to any writer.

const std = @import("std");
const terminal = @import("terminal.zig");

/// Error category for classification and default suggestions.
pub const ErrorCategory = enum {
    InvalidArguments,
    NotFound,
    PermissionDenied,
    NetworkError,
    IoError,
    ProjectLocked,
    InternalError,
};

/// Structured error with category, message, suggestion, and context.
pub const CliError = struct {
    category: ErrorCategory,
    message: []const u8,
    suggestion: ?[]const u8 = null,
    context: ?[]const u8 = null,

    /// Format this error to a writer with color.
    pub fn format(self: CliError, writer: anytype) !void {
        var sw = terminal.StyledWriter(@TypeOf(writer)).init(writer);

        // Error header
        try sw.print(
            "{s}{s}error{s}: {s}{s}\n",
            .{ sw.bold(), sw.red(), sw.reset(), sw.bold(), self.message },
        );

        // Suggestion line (with default fallback)
        const suggestion_text = self.suggestion orelse defaultSuggestion(self.category);
        if (suggestion_text.len > 0) {
            try sw.print(
                "  {s}hint{s}: {s}\n",
                .{ sw.dim(), sw.reset(), suggestion_text },
            );
        }

        // Context line
        if (self.context) |ctx| {
            try sw.print(
                "  {s}context{s}: {s}\n",
                .{ sw.dim(), sw.reset(), ctx },
            );
        }
    }
};

/// Return a default suggestion for each error category.
fn defaultSuggestion(cat: ErrorCategory) []const u8 {
    return switch (cat) {
        .InvalidArguments => "Use 'zindeks help' to see usage",
        .NotFound => "Run 'zindeks index' first to create an index",
        .PermissionDenied => "Check file permissions or try a different path",
        .NetworkError => "Check your internet connection and try again",
        .IoError => "Verify the path exists and is accessible",
        .ProjectLocked => "Another zindeks process may be indexing. Try again later.",
        .InternalError => "This is a bug. Please report it with the context above.",
    };
}

/// Create an InvalidArguments error.
pub fn invalidArgs(msg: []const u8) CliError {
    return .{ .category = .InvalidArguments, .message = msg };
}

/// Create a NotFound error.
pub fn notFound(msg: []const u8) CliError {
    return .{
        .category = .NotFound,
        .message = msg,
    };
}

/// Create a PermissionDenied error.
pub fn permissionDenied(msg: []const u8) CliError {
    return .{ .category = .PermissionDenied, .message = msg };
}

/// Create a NetworkError.
pub fn networkError(msg: []const u8) CliError {
    return .{ .category = .NetworkError, .message = msg };
}

/// Create an IoError.
pub fn ioError(msg: []const u8, file_path: ?[]const u8) CliError {
    return .{
        .category = .IoError,
        .message = msg,
        .context = file_path,
    };
}

/// Create an InternalError.
pub fn internalError(msg: []const u8) CliError {
    return .{ .category = .InternalError, .message = msg };
}
