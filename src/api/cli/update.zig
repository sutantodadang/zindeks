const std = @import("std");
const builtin = @import("builtin");

const default_repo = "sutantodadang/zindeks";

pub const Options = struct {
    repo: []const u8 = default_repo,
    version: []const u8 = "latest",
    install_dir: ?[]const u8 = null,
    no_path_update: bool = false,
    dry_run: bool = false,
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    const options = try parseArgs(args);
    const install_dir = try resolveInstallDir(allocator, options.install_dir);
    defer allocator.free(install_dir);

    if (options.dry_run) {
        try printDryRun(writer, options, install_dir);
        return;
    }

    switch (builtin.os.tag) {
        .windows => try runWindowsUpdater(allocator, options, install_dir, writer),
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => try runUnixUpdater(allocator, options, install_dir),
        else => return error.UnsupportedPlatform,
    }
}

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--repo")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.repo = args[index];
        } else if (std.mem.eql(u8, arg, "--version")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.version = args[index];
        } else if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.install_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--no-path-update")) {
            options.no_path_update = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            return error.InvalidArguments;
        }
    }
    if (options.repo.len == 0 or options.version.len == 0) return error.InvalidArguments;
    return options;
}

pub fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\usage:
        \\  zindeks update [--version tag|latest] [--repo owner/repo] [--dir install-dir] [--no-path-update] [--dry-run]
        \\
        \\examples:
        \\  zindeks update
        \\  zindeks update --version v0.1.1
        \\  zindeks update --dir ~/.local/bin --no-path-update
        \\
    );
}

fn resolveInstallDir(allocator: std.mem.Allocator, override_dir: ?[]const u8) ![]u8 {
    if (override_dir) |install_dir| return allocator.dupe(u8, install_dir);
    if (envOwned(allocator, "ZINDEKS_INSTALL_DIR")) |install_dir| return install_dir;
    return std.fs.selfExeDirPathAlloc(allocator);
}

fn printDryRun(writer: anytype, options: Options, install_dir: []const u8) !void {
    const platform = platformName() orelse "unsupported";
    const cpu = cpuName() orelse "unsupported";
    try writer.print(
        \\update plan:
        \\  repo: {s}
        \\  version: {s}
        \\  platform: {s}
        \\  arch: {s}
        \\  install_dir: {s}
        \\  no_path_update: {}
        \\
    , .{ options.repo, options.version, platform, cpu, install_dir, options.no_path_update });
}

fn runWindowsUpdater(allocator: std.mem.Allocator, options: Options, install_dir: []const u8, writer: anytype) !void {
    const script_path = try tempScriptPath(allocator, ".ps1");
    defer allocator.free(script_path);
    try writeTextFile(script_path, windowsScript());

    const parent_pid = try std.fmt.allocPrint(allocator, "{d}", .{std.os.windows.GetCurrentProcessId()});
    defer allocator.free(parent_pid);

    const powershell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        powershell,
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script_path,
        "-Repo",
        options.repo,
        "-Version",
        options.version,
        "-InstallDir",
        install_dir,
        "-ParentPid",
        parent_pid,
    });
    if (options.no_path_update) try argv.append(allocator, "-NoPathUpdate");

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.create_no_window = false;
    try child.spawn();

    try writer.print("Updater started for {s} {s}. zindeks will be replaced after this process exits.\n", .{ options.repo, options.version });
}

fn runUnixUpdater(allocator: std.mem.Allocator, options: Options, install_dir: []const u8) !void {
    const script_path = try tempScriptPath(allocator, ".sh");
    defer allocator.free(script_path);
    try writeTextFile(script_path, unixScript());

    var child = std.process.Child.init(&.{ "sh", script_path, options.repo, options.version, install_dir }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.UpdateFailed,
        else => return error.UpdateFailed,
    }
}

fn tempScriptPath(allocator: std.mem.Allocator, extension: []const u8) ![]u8 {
    const temp_root = try tempRoot(allocator);
    defer allocator.free(temp_root);
    const basename = try std.fmt.allocPrint(allocator, "zindeks-update-{d}-{x}{s}", .{ std.time.nanoTimestamp(), std.crypto.random.int(u32), extension });
    defer allocator.free(basename);
    return std.fs.path.join(allocator, &.{ temp_root, basename });
}

fn tempRoot(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (envOwned(allocator, "TEMP")) |value| return value;
        if (envOwned(allocator, "TMP")) |value| return value;
        if (envOwned(allocator, "LOCALAPPDATA")) |value| return value;
    } else {
        if (envOwned(allocator, "TMPDIR")) |value| return value;
        return allocator.dupe(u8, "/tmp");
    }
    return error.TempDirNotFound;
}

fn writeTextFile(path: []const u8, contents: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn envOwned(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

fn platformName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => null,
    };
}

fn cpuName() ?[]const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => null,
    };
}

fn windowsScript() []const u8 {
    return 
    \\[CmdletBinding()]
    \\param(
    \\    [Parameter(Mandatory=$true)][string]$Repo,
    \\    [Parameter(Mandatory=$true)][string]$Version,
    \\    [Parameter(Mandatory=$true)][string]$InstallDir,
    \\    [Parameter(Mandatory=$true)][int]$ParentPid,
    \\    [switch]$NoPathUpdate
    \\)
    \\$ErrorActionPreference = "Stop"
    \\try {
    \\    if ($ParentPid -gt 0) {
    \\        Wait-Process -Id $ParentPid -ErrorAction SilentlyContinue
    \\    }
    \\    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    \\        "AMD64" { "x86_64" }
    \\        "ARM64" { "aarch64" }
    \\        default { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
    \\    }
    \\    $asset = "zindeks-windows-$arch.zip"
    \\    if ($Version -eq "latest") {
    \\        $url = "https://github.com/$Repo/releases/latest/download/$asset"
    \\    } else {
    \\        $url = "https://github.com/$Repo/releases/download/$Version/$asset"
    \\    }
    \\    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("zindeks-update-" + [System.Guid]::NewGuid().ToString("N"))
    \\    New-Item -ItemType Directory -Path $tmp | Out-Null
    \\    try {
    \\        $archive = Join-Path $tmp $asset
    \\        Invoke-WebRequest -Uri $url -OutFile $archive
    \\        Expand-Archive -Path $archive -DestinationPath $tmp -Force
    \\        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    \\        $source = Join-Path $tmp "zindeks-windows-$arch\zindeks.exe"
    \\        $target = Join-Path $InstallDir "zindeks.exe"
    \\        Copy-Item -Path $source -Destination $target -Force
    \\        Unblock-File -Path $target -ErrorAction SilentlyContinue
    \\        if (-not $NoPathUpdate) {
    \\            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    \\            $parts = @($userPath -split ";" | Where-Object { $_ })
    \\            if ($parts -notcontains $InstallDir) {
    \\                [Environment]::SetEnvironmentVariable("Path", (($parts + $InstallDir) -join ";"), "User")
    \\            }
    \\        }
    \\        Write-Host "Updated zindeks to $target"
    \\    } finally {
    \\        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    \\    }
    \\} finally {
    \\    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    \\}
    \\
    ;
}

fn unixScript() []const u8 {
    return 
    \\#!/usr/bin/env sh
    \\set -eu
    \\repo="$1"
    \\version="$2"
    \\install_dir="$3"
    \\cleanup_self() { rm -f "$0" 2>/dev/null || true; }
    \\trap cleanup_self EXIT HUP INT TERM
    \\case "$(uname -s)" in
    \\  Linux) platform="linux" ;;
    \\  Darwin) platform="macos" ;;
    \\  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
    \\esac
    \\case "$(uname -m)" in
    \\  x86_64|amd64) cpu="x86_64" ;;
    \\  arm64|aarch64) cpu="aarch64" ;;
    \\  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    \\esac
    \\asset="zindeks-${platform}-${cpu}.tar.gz"
    \\if [ "$version" = "latest" ]; then
    \\  url="https://github.com/${repo}/releases/latest/download/${asset}"
    \\else
    \\  url="https://github.com/${repo}/releases/download/${version}/${asset}"
    \\fi
    \\tmp="${TMPDIR:-/tmp}/zindeks-update.$$"
    \\mkdir -p "$tmp"
    \\trap 'rm -rf "$tmp"; cleanup_self' EXIT HUP INT TERM
    \\archive="$tmp/$asset"
    \\if command -v curl >/dev/null 2>&1; then
    \\  curl -fsSL "$url" -o "$archive"
    \\elif command -v wget >/dev/null 2>&1; then
    \\  wget -q "$url" -O "$archive"
    \\else
    \\  echo "curl or wget is required" >&2
    \\  exit 1
    \\fi
    \\tar -xzf "$archive" -C "$tmp"
    \\mkdir -p "$install_dir"
    \\cp "$tmp/zindeks-${platform}-${cpu}/zindeks" "$install_dir/zindeks"
    \\chmod 0755 "$install_dir/zindeks"
    \\echo "Updated zindeks to $install_dir/zindeks"
    \\
    ;
}
