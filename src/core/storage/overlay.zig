//! BM25 delta overlay.
//!
//! The base binary index is built once by a full re-index pass.  After that,
//! every incremental update would otherwise leave the BM25 side stale — the
//! graph DB knows the new shape of the world but `posting.idx` does not.  An
//! overlay closes that gap without a full rebuild:
//!
//!   * **Sub-index** under `<index_dir>/overlay/` — built with the regular
//!     `storage.Writer`, contains only the added-or-modified files since the
//!     base.  Engine merges its postings with the base's at query time.
//!
//!   * **Tombstones** at `<index_dir>/tombstones.idx` — a length-prefixed
//!     list of paths that must be suppressed from base results (because they
//!     were deleted or have a newer copy in the overlay).
//!
//! `Overlay.rebuild` reads the current graph-DB documents table, compares
//! against the base binary index, and re-emits both files.  The cost scales
//! with the size of the delta, not the size of the repo.
//!
//! Lifecycle: `incremental.applyChanges` updates SQLite, then triggers
//! `Overlay.rebuild`.  Engines opened against the same index_dir
//! automatically pick the overlay up via `Index.attachOverlay`.

const std = @import("std");
const storage = @import("index.zig");
const scanner = @import("../scanner/scanner.zig");
const graph_db = @import("graph_db.zig");

pub const OVERLAY_SUBDIR = "overlay";
pub const TOMBSTONES_NAME = "tombstones.idx";

/// File-format header for `tombstones.idx`.
///
/// `version` is bumped if the on-disk shape changes.  `path_count` is the
/// number of `[u32 len][bytes...]` records that follow.
pub const TombstonesHeader = packed struct {
    magic: u32,
    version: u32,
    path_count: u32,
    _reserved: u32 = 0,
};

pub const TOMBSTONES_MAGIC: u32 = 0x5a494454; // 'ZIDT'
pub const TOMBSTONES_VERSION: u32 = 1;

/// An overlay attached to a base `Index`.  Owns its sub-`Index` and the
/// resolved tombstone doc-id set.
pub const Overlay = struct {
    allocator: std.mem.Allocator,
    sub_index: storage.Index,
    /// Set of *base* doc IDs that the overlay supersedes.  Doc IDs are
    /// pre-resolved from path strings at `open()` time so search-time checks
    /// are O(1).
    tombstoned_base_ids: std.AutoHashMapUnmanaged(u32, void),

    /// Open the overlay sitting at `<index_path>/overlay/` plus
    /// `<index_path>/tombstones.idx`.  Returns null if neither artifact
    /// exists — the caller should treat that as "no overlay attached".
    pub fn open(
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        index_path: []const u8,
        base: *const storage.Index,
    ) !?Overlay {
        const overlay_dir = try std.fs.path.join(allocator, &.{ index_path, OVERLAY_SUBDIR });
        defer allocator.free(overlay_dir);

        const probe = try std.fs.path.join(allocator, &.{ overlay_dir, "meta.idx" });
        defer allocator.free(probe);
        const has_subindex = checkExists(dir, probe);

        if (!has_subindex) return null;

        var sub = try storage.Index.open(allocator, dir, overlay_dir);
        errdefer sub.close();

        var tombstones: std.AutoHashMapUnmanaged(u32, void) = .{};
        errdefer tombstones.deinit(allocator);

        try loadTombstones(allocator, dir, index_path, base, &tombstones);

        return Overlay{
            .allocator = allocator,
            .sub_index = sub,
            .tombstoned_base_ids = tombstones,
        };
    }

    pub fn close(self: *Overlay) void {
        self.tombstoned_base_ids.deinit(self.allocator);
        self.sub_index.close();
    }

    /// Number of docs the overlay contributes.  Doc IDs in the merged view
    /// are `local_id + base.docCount()`.
    pub fn docCount(self: *const Overlay) u32 {
        return self.sub_index.docCount();
    }

    pub fn isTombstoned(self: *const Overlay, base_doc_id: u32) bool {
        return self.tombstoned_base_ids.contains(base_doc_id);
    }
};

fn checkExists(dir: std.fs.Dir, rel: []const u8) bool {
    if (std.fs.path.isAbsolute(rel)) {
        std.fs.accessAbsolute(rel, .{}) catch return false;
    } else {
        dir.access(rel, .{}) catch return false;
    }
    return true;
}

fn loadTombstones(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    index_path: []const u8,
    base: *const storage.Index,
    out: *std.AutoHashMapUnmanaged(u32, void),
) !void {
    const rel = try std.fs.path.join(allocator, &.{ index_path, TOMBSTONES_NAME });
    defer allocator.free(rel);

    var file = openMaybe(dir, rel) orelse return;
    defer file.close();

    const size = try file.getEndPos();
    if (size < @sizeOf(TombstonesHeader)) return;

    const bytes = try file.readToEndAlloc(allocator, 1 << 30);
    defer allocator.free(bytes);

    const header = std.mem.bytesAsValue(TombstonesHeader, bytes[0..@sizeOf(TombstonesHeader)]).*;
    if (header.magic != TOMBSTONES_MAGIC or header.version != TOMBSTONES_VERSION) return;

    // Build a transient path → base_doc_id map for resolution.
    var path_to_id = std.StringHashMap(u32).init(allocator);
    defer path_to_id.deinit();
    var i: u32 = 0;
    while (i < base.docCount()) : (i += 1) {
        try path_to_id.put(base.filePath(i), i);
    }

    var cursor: usize = @sizeOf(TombstonesHeader);
    var emitted: u32 = 0;
    while (emitted < header.path_count and cursor + 4 <= bytes.len) : (emitted += 1) {
        const path_len = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
        cursor += 4;
        if (cursor + path_len > bytes.len) break;
        const path = bytes[cursor .. cursor + path_len];
        cursor += path_len;
        if (path_to_id.get(path)) |id| {
            try out.put(allocator, id, {});
        }
    }
}

fn openMaybe(dir: std.fs.Dir, rel: []const u8) ?std.fs.File {
    if (std.fs.path.isAbsolute(rel)) {
        return std.fs.openFileAbsolute(rel, .{}) catch return null;
    }
    return dir.openFile(rel, .{}) catch return null;
}

// ██████████████████████████████████████████████████████████████████████████
// Rebuild
// ██████████████████████████████████████████████████████████████████████████

/// Recompute the overlay for `index_path` against the truth currently in
/// `gdb`.  Compares every path tracked by SQLite against the base binary
/// index; paths that are new (or whose `content_hash` differs) get re-read
/// from disk and folded into the overlay sub-index, while paths the base
/// knows about but SQLite no longer does get a tombstone.
///
/// On entry `index_path` must contain at least a base index (meta.idx etc.)
/// — that is the index built by `indexer.indexPath`.  If no base exists,
/// the function returns without writing anything (the caller should do a
/// full re-index instead).
pub fn rebuild(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    index_path: []const u8,
    project_path: []const u8,
    gdb: *graph_db.GraphDb,
) !RebuildStats {
    var stats = RebuildStats{};

    // Open the base index so we can diff against it.
    var base = storage.Index.open(allocator, dir, index_path) catch return stats;
    defer base.close();

    // ── Phase 1: gather the current SQLite truth ──────────────────────
    //
    // path → content_hash (u64).  We use Wyhash on file contents elsewhere,
    // so the SQLite blob stores 8 little-endian bytes that we read back as
    // a u64 to compare against base.docs[i].hash.
    var current = std.StringHashMap(u64).init(allocator);
    defer {
        var it = current.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        current.deinit();
    }
    {
        var stmt = try gdb.prepare("SELECT path, content_hash FROM documents");
        defer stmt.finalize();
        while (try stmt.step()) {
            const path = try stmt.columnText(0);
            const hash = readHashBlob(&stmt) catch 0;
            try current.put(try allocator.dupe(u8, path), hash);
        }
    }

    // ── Phase 2: classify base entries ────────────────────────────────
    //
    // - Path missing from `current` → tombstone (file was deleted).
    // - Path present but hash differs → tombstone the old copy and add
    //   the new copy to the overlay (modified).
    // - Path present and hash matches → keep base as-is.
    var tombstone_paths = std.ArrayList([]const u8).initCapacity(allocator, 16) catch @panic("OOM");
    defer tombstone_paths.deinit(allocator);

    var base_paths = std.StringHashMap(u64).init(allocator);
    defer base_paths.deinit();

    var i: u32 = 0;
    while (i < base.docCount()) : (i += 1) {
        const path = base.filePath(i);
        const base_hash = base.docs[i].hash;
        try base_paths.put(path, base_hash);
        if (current.get(path)) |cur_hash| {
            if (cur_hash != base_hash) {
                try tombstone_paths.append(allocator, path);
                stats.tombstoned += 1;
            }
        } else {
            try tombstone_paths.append(allocator, path);
            stats.tombstoned += 1;
        }
    }

    // ── Phase 3: enumerate overlay payload ────────────────────────────
    //
    // Every path in `current` that is either missing from the base or has
    // a different hash needs to live in the overlay.
    var overlay_paths = std.ArrayList([]const u8).initCapacity(allocator, 16) catch @panic("OOM");
    defer overlay_paths.deinit(allocator);

    var cur_it = current.iterator();
    while (cur_it.next()) |kv| {
        const path = kv.key_ptr.*;
        const cur_hash = kv.value_ptr.*;
        if (base_paths.get(path)) |base_hash| {
            if (cur_hash != base_hash) try overlay_paths.append(allocator, path);
        } else {
            try overlay_paths.append(allocator, path);
        }
    }

    // ── Phase 4: write overlay sub-index ──────────────────────────────
    const overlay_dir = try std.fs.path.join(allocator, &.{ index_path, OVERLAY_SUBDIR });
    defer allocator.free(overlay_dir);

    if (overlay_paths.items.len == 0) {
        // Nothing to overlay — wipe any stale sub-index but keep tombstones
        // if the caller is suppressing deletions.
        removeSubindex(dir, overlay_dir);
    } else {
        try writeSubindex(allocator, dir, overlay_dir, project_path, overlay_paths.items, &stats);
    }

    // ── Phase 5: persist tombstones ───────────────────────────────────
    try writeTombstones(allocator, dir, index_path, tombstone_paths.items);

    return stats;
}

pub const RebuildStats = struct {
    overlay_docs: u32 = 0,
    tombstoned: u32 = 0,
    skipped_io: u32 = 0,
};

fn readHashBlob(stmt: *graph_db.Statement) !u64 {
    const bytes = stmt.columnBlob(1) catch return 0;
    if (bytes.len < 8) return 0;
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn removeSubindex(dir: std.fs.Dir, overlay_dir: []const u8) void {
    if (std.fs.path.isAbsolute(overlay_dir)) {
        std.fs.deleteTreeAbsolute(overlay_dir) catch {};
    } else {
        dir.deleteTree(overlay_dir) catch {};
    }
}

fn writeSubindex(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    overlay_dir: []const u8,
    project_path: []const u8,
    paths: []const []const u8,
    stats: *RebuildStats,
) !void {
    // Make sure the overlay directory exists and is empty so finish() does
    // not collide with previous artifacts.
    removeSubindex(dir, overlay_dir);
    if (std.fs.path.isAbsolute(overlay_dir)) {
        try std.fs.makeDirAbsolute(overlay_dir);
    } else {
        try dir.makePath(overlay_dir);
    }

    var writer = try storage.Writer.init(allocator, dir, overlay_dir);
    defer writer.deinit();

    for (paths) |rel_path| {
        const full = try std.fs.path.join(allocator, &.{ project_path, rel_path });
        defer allocator.free(full);

        // Use the chunked-aware ingestion path so an oversize file does not
        // OOM the overlay rebuild.  We stat first to choose between buffered
        // and streamed; mirrors `scanner.scanDirChunked`'s logic.
        const stat = std.fs.cwd().statFile(full) catch {
            stats.skipped_io += 1;
            continue;
        };
        if (stat.size > scanner.max_file_size) {
            stats.skipped_io += 1;
            continue;
        }
        if (stat.size <= scanner.stream_threshold) {
            const content = std.fs.cwd().readFileAlloc(allocator, full, scanner.max_file_size) catch {
                stats.skipped_io += 1;
                continue;
            };
            defer allocator.free(content);
            const hash = std.hash.Wyhash.hash(0, content);
            _ = try writer.addFile(rel_path, hash, @intCast(stat.mtime), content);
        } else {
            var file = std.fs.cwd().openFile(full, .{}) catch {
                stats.skipped_io += 1;
                continue;
            };
            defer file.close();
            var handle = try writer.beginStreamFile(rel_path, @intCast(stat.mtime));
            var buf: [scanner.CHUNK_SIZE]u8 = undefined;
            while (true) {
                const n = file.read(&buf) catch break;
                if (n == 0) break;
                try writer.appendStreamChunk(&handle, buf[0..n]);
            }
            try writer.endStreamFile(&handle);
        }
        stats.overlay_docs += 1;
    }

    try writer.finish();
}

fn writeTombstones(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    index_path: []const u8,
    paths: []const []const u8,
) !void {
    const rel = try std.fs.path.join(allocator, &.{ index_path, TOMBSTONES_NAME });
    defer allocator.free(rel);

    if (paths.len == 0) {
        // No tombstones is the steady state; remove any stale file so the
        // reader doesn't pick up suppressions from a prior generation.
        if (std.fs.path.isAbsolute(rel)) {
            std.fs.deleteFileAbsolute(rel) catch {};
        } else {
            dir.deleteFile(rel) catch {};
        }
        return;
    }

    var file = if (std.fs.path.isAbsolute(rel))
        try std.fs.createFileAbsolute(rel, .{ .truncate = true })
    else
        try dir.createFile(rel, .{ .truncate = true });
    defer file.close();

    const header = TombstonesHeader{
        .magic = TOMBSTONES_MAGIC,
        .version = TOMBSTONES_VERSION,
        .path_count = @intCast(paths.len),
    };
    try file.writeAll(std.mem.asBytes(&header));

    for (paths) |p| {
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(p.len), .little);
        try file.writeAll(&len_bytes);
        try file.writeAll(p);
    }
}
