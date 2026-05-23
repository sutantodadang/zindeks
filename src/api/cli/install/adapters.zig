//! Host adapter registry for zindeks install.
//!
//! Each adapter knows:
//!   - How to detect whether the host is installed (probe known config paths).
//!   - Which config file to write for user/project scope.
//!   - Whether project scope is supported.
//!
//! Five adapters in v1: claude-code, cursor, vscode, windsurf, antigravity.

const std = @import("std");
const builtin = @import("builtin");

pub const Scope = enum { user, project, both };

pub const AdapterId = enum {
    claude_code,
    cursor,
    vscode,
    windsurf,
    antigravity,

    pub fn fromStr(s: []const u8) ?AdapterId {
        if (std.mem.eql(u8, s, "claude-code")) return .claude_code;
        if (std.mem.eql(u8, s, "cursor")) return .cursor;
        if (std.mem.eql(u8, s, "vscode")) return .vscode;
        if (std.mem.eql(u8, s, "windsurf")) return .windsurf;
        if (std.mem.eql(u8, s, "antigravity")) return .antigravity;
        return null;
    }

    pub fn toStr(self: AdapterId) []const u8 {
        return switch (self) {
            .claude_code => "claude-code",
            .cursor => "cursor",
            .vscode => "vscode",
            .windsurf => "windsurf",
            .antigravity => "antigravity",
        };
    }

    pub fn displayName(self: AdapterId) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .cursor => "Cursor",
            .vscode => "VS Code",
            .windsurf => "Windsurf",
            .antigravity => "Antigravity",
        };
    }
};

pub const Paths = struct {
    /// Path to the JSON config file for this scope.  Caller must free.
    config: ?[]u8,
    /// For claude-code project scope: path to CLAUDE.md.  Caller must free.
    claude_md: ?[]u8,

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        if (self.config) |p| allocator.free(p);
        if (self.claude_md) |p| allocator.free(p);
        self.* = undefined;
    }
};

/// Return paths for the given adapter + scope.
/// `cwd` is used for project-scope paths.  Caller owns the result.
pub fn getPaths(
    allocator: std.mem.Allocator,
    id: AdapterId,
    scope: Scope,
    cwd: []const u8,
) !Paths {
    return switch (id) {
        .claude_code => claudeCodePaths(allocator, scope, cwd),
        .cursor => cursorPaths(allocator, scope, cwd),
        .vscode => vscodePaths(allocator, scope, cwd),
        .windsurf => windsurfPaths(allocator, scope, cwd),
        .antigravity => antigravityPaths(allocator, scope, cwd),
    };
}

/// Returns true if there is any sign the host is installed on this machine
/// (its user config dir / config file exists).
pub fn isDetected(allocator: std.mem.Allocator, id: AdapterId) bool {
    const probe = detectProbe(allocator, id) catch return false;
    defer allocator.free(probe);
    std.fs.accessAbsolute(probe, .{}) catch return false;
    return true;
}

/// Returns true if the adapter supports project scope.
pub fn supportsProjectScope(id: AdapterId) bool {
    return switch (id) {
        .windsurf => false,
        else => true,
    };
}

// ── per-adapter path functions ────────────────────────────────────────

fn claudeCodePaths(
    allocator: std.mem.Allocator,
    scope: Scope,
    cwd: []const u8,
) !Paths {
    var result = Paths{ .config = null, .claude_md = null };

    switch (scope) {
        .user => {
            const home = try homeDir(allocator);
            defer allocator.free(home);
            result.config = try std.fs.path.join(allocator, &.{ home, ".claude", "settings.json" });
        },
        .project => {
            result.config = try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
            result.claude_md = try std.fs.path.join(allocator, &.{ cwd, "CLAUDE.md" });
        },
        .both => {
            // "both" is handled by the caller invoking getPaths twice (.user then .project).
            // Return user paths when called with .both.
            const home = try homeDir(allocator);
            defer allocator.free(home);
            result.config = try std.fs.path.join(allocator, &.{ home, ".claude", "settings.json" });
        },
    }

    return result;
}

/// For "both" scope, callers should call getPaths twice: once with .user,
/// once with .project.  This helper builds the project paths only.
pub fn getProjectPaths(
    allocator: std.mem.Allocator,
    id: AdapterId,
    cwd: []const u8,
) !Paths {
    return switch (id) {
        .claude_code => claudeCodePaths(allocator, .project, cwd),
        .cursor => cursorPaths(allocator, .project, cwd),
        .vscode => vscodePaths(allocator, .project, cwd),
        .windsurf => Paths{ .config = null, .claude_md = null }, // no project scope
        .antigravity => antigravityPaths(allocator, .project, cwd),
    };
}

fn cursorPaths(
    allocator: std.mem.Allocator,
    scope: Scope,
    cwd: []const u8,
) !Paths {
    var result = Paths{ .config = null, .claude_md = null };
    switch (scope) {
        .user, .both => {
            const home = try homeDir(allocator);
            defer allocator.free(home);
            result.config = try std.fs.path.join(allocator, &.{ home, ".cursor", "mcp.json" });
        },
        .project => {
            result.config = try std.fs.path.join(allocator, &.{ cwd, ".cursor", "mcp.json" });
        },
    }
    return result;
}

fn vscodePaths(
    allocator: std.mem.Allocator,
    scope: Scope,
    cwd: []const u8,
) !Paths {
    var result = Paths{ .config = null, .claude_md = null };
    switch (scope) {
        .user, .both => {
            result.config = try vscodeUserConfigPath(allocator);
        },
        .project => {
            result.config = try std.fs.path.join(allocator, &.{ cwd, ".vscode", "mcp.json" });
        },
    }
    return result;
}

fn windsurfPaths(
    allocator: std.mem.Allocator,
    scope: Scope,
    cwd: []const u8,
) !Paths {
    _ = scope;
    _ = cwd;
    var result = Paths{ .config = null, .claude_md = null };
    const home = try homeDir(allocator);
    defer allocator.free(home);
    result.config = try std.fs.path.join(allocator, &.{ home, ".codeium", "windsurf", "mcp_config.json" });
    return result;
}

fn antigravityPaths(
    allocator: std.mem.Allocator,
    scope: Scope,
    cwd: []const u8,
) !Paths {
    var result = Paths{ .config = null, .claude_md = null };
    switch (scope) {
        .user, .both => {
            const home = try homeDir(allocator);
            defer allocator.free(home);
            // Probe primary path first; fall back to XDG on non-Windows.
            const primary = try std.fs.path.join(allocator, &.{ home, ".antigravity", "mcp.json" });
            if (std.fs.accessAbsolute(primary, .{})) {
                // Primary path accessible — use it.
                result.config = primary;
            } else |_| {
                allocator.free(primary);
                if (builtin.os.tag != .windows) {
                    // XDG fallback.
                    result.config = try std.fs.path.join(allocator, &.{ home, ".config", "antigravity", "mcp.json" });
                } else {
                    // On Windows, reconstruct (primary was freed).
                    result.config = try std.fs.path.join(allocator, &.{ home, ".antigravity", "mcp.json" });
                }
            }
        },
        .project => {
            result.config = try std.fs.path.join(allocator, &.{ cwd, ".antigravity", "mcp.json" });
        },
    }
    return result;
}

// ── Platform helpers ──────────────────────────────────────────────────

/// Return a probe path used to detect whether a host is installed.
/// The path points to the host's user-level config directory or file.
fn detectProbe(allocator: std.mem.Allocator, id: AdapterId) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);

    return switch (id) {
        .claude_code => std.fs.path.join(allocator, &.{ home, ".claude" }),
        .cursor => std.fs.path.join(allocator, &.{ home, ".cursor" }),
        .vscode => vscodeUserDir(allocator),
        .windsurf => std.fs.path.join(allocator, &.{ home, ".codeium", "windsurf" }),
        .antigravity => blk: {
            const primary = try std.fs.path.join(allocator, &.{ home, ".antigravity" });
            break :blk primary;
        },
    };
}

pub fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
            std.process.getEnvVarOwned(allocator, "HOMEDRIVE") catch
            error.HomeNotFound;
    }
    return std.process.getEnvVarOwned(allocator, "HOME") catch error.HomeNotFound;
}

fn vscodeUserDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try std.process.getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "Code", "User" });
    }
    if (builtin.os.tag == .macos) {
        const home = try homeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "Code", "User" });
    }
    // Linux / XDG
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "Code", "User" });
    } else |_| {}
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "Code", "User" });
}

fn vscodeUserConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try vscodeUserDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "mcp.json" });
}

/// Normalize path separators for JSON output: always forward slashes.
pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, path);
    for (result) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return result;
}

/// Get absolute path to the currently-running zindeks binary.
pub fn selfExePath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.selfExePath(&buf);
    return normalizePath(allocator, path);
}

// ── All adapter IDs in display order ─────────────────────────────────

pub const all_adapters = [_]AdapterId{
    .claude_code,
    .cursor,
    .vscode,
    .windsurf,
    .antigravity,
};
