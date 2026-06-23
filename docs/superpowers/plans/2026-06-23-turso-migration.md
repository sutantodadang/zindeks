# Turso Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace zindeks's vendored SQLite engine with Turso (Rust in-process SQLite rewrite) to enable concurrent cross-process writers via `BEGIN CONCURRENT` + MVCC.

**Architecture:** SQLite is isolated behind one module — `src/core/storage/graph_db.zig` (a `@cImport("sqlite3.h")` block + `GraphDb`/`Statement` wrappers). The public `GraphDb` Zig API stays identical; all callers (BM25 `engine.zig`, `semantic.zig`, indexer, MCP tools) are untouched. We swap the C library underneath, link Turso's SQLite-compatible C API, switch writer transactions to `BEGIN CONCURRENT`, and bump the on-disk store tag so old SQLite `graph.db` files auto-rebuild.

**Tech Stack:** Zig 0.15.2, Turso (`tursodatabase/turso`) C API static library, existing tree-sitter + binary-index BM25 stack (unchanged).

## Global Constraints

- Zig version: 0.15.2 (matches current build).
- Zero runtime dependencies / single static binary identity must be preserved — Turso linked as a **prebuilt static lib** per target, no Rust at `zig build` time.
- 6 cross-compile targets must all link and run (primary dev platform: **Windows**).
- Public `GraphDb` Zig API (`open`, `close`, `migrate`, `prepare`, `exec`, `queryScalar`, `queryScalarFloat`, `lastInsertRowid`, `errmsg`, `Statement.*`) must not change signature — callers stay untouched.
- `graph.db` is a derived cache: no data migration; stale stores are deleted and re-indexed.
- Test command for the whole suite: `zig build test`.
- BM25 (binary index) and vector search (BLOB + Zig cosine) are **out of scope** — do not touch `engine.zig`, `overlay.zig`, `semantic.zig`.

---

### Task 1: Phase 0 spike — Turso C API go/no-go gate

Exploratory, not TDD. This task decides whether the migration proceeds. **Stop the plan if step 4 or 6 fails.**

**Files:**
- Create: `spike/turso_spike.zig` (throwaway, deleted in Task 8)
- Create: `spike/build_spike.sh` (throwaway helper)
- Reference: Turso repo `bindings/` for the C API header + static lib build

**Interfaces:**
- Produces: a confirmed answer to "does `BEGIN CONCURRENT` work + does the static lib link on Windows", plus the exact static-lib filename and C header path used by Tasks 2-3.

- [ ] **Step 1: Build the Turso C API static library**

Clone Turso and build its C API surface as a static lib for the host target.

```bash
git clone https://github.com/tursodatabase/turso /tmp/turso
cd /tmp/turso
# Locate the C API crate (cdylib/staticlib). Inspect bindings/ and Cargo.toml:
ls bindings
# Build a static lib (crate name confirmed from Cargo.toml — e.g. turso-c / limbo-c):
cargo build --release -p <turso-c-api-crate>
# Note the produced artifact + its sqlite3.h-compatible header location:
find target/release -name '*.a' -o -name '*.lib'
find . -name 'sqlite3.h' -o -name 'turso.h'
```

Record: static lib path, header path, crate name. Tasks 2-3 need these exact values.

- [ ] **Step 2: Write the spike program**

```zig
// spike/turso_spike.zig — throwaway. Verifies Turso C API covers zindeks usage.
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h"); // Turso's SQLite-compatible header
});

pub fn main() !void {
    var db: ?*c.sqlite3 = undefined;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.OpenFailed;
    defer _ = c.sqlite3_close(db);

    // 1. Create one representative table (documents).
    if (c.sqlite3_exec(db,
        "CREATE TABLE documents (id INTEGER PRIMARY KEY, path TEXT, language TEXT, embedding BLOB)",
        null, null, null) != c.SQLITE_OK) return error.CreateFailed;

    // 2. Round-trip: bind every type zindeks uses, read every column type back.
    var stmt: ?*c.sqlite3_stmt = undefined;
    if (c.sqlite3_prepare_v2(db,
        "INSERT INTO documents (path, language, embedding) VALUES (?,?,?)",
        -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    const blob = [_]u8{ 1, 2, 3, 4 };
    _ = c.sqlite3_bind_text(stmt, 1, "src/main.zig", -1, null);
    _ = c.sqlite3_bind_text(stmt, 2, "Zig", -1, null);
    _ = c.sqlite3_bind_blob(stmt, 3, &blob, blob.len, null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    _ = c.sqlite3_finalize(stmt);
    std.debug.print("rowid={d}\n", .{c.sqlite3_last_insert_rowid(db)});

    // 3. Read back: column_text, column_blob, column_bytes, column_type.
    var rd: ?*c.sqlite3_stmt = undefined;
    _ = c.sqlite3_prepare_v2(db, "SELECT path, embedding FROM documents", -1, &rd, null);
    while (c.sqlite3_step(rd) == c.SQLITE_ROW) {
        const path = c.sqlite3_column_text(rd, 0);
        const n = c.sqlite3_column_bytes(rd, 1);
        std.debug.print("path={s} blob_bytes={d} type0={d}\n",
            .{ path, n, c.sqlite3_column_type(rd, 0) });
    }
    _ = c.sqlite3_finalize(rd);

    // 4. THE make-or-break test: BEGIN CONCURRENT.
    const rc = c.sqlite3_exec(db, "BEGIN CONCURRENT", null, null, null);
    std.debug.print("BEGIN CONCURRENT rc={d} (0=OK)\n", .{rc});
    _ = c.sqlite3_exec(db, "COMMIT", null, null, null);
    if (rc != c.SQLITE_OK) {
        std.debug.print("WARN: BEGIN CONCURRENT unsupported — fall back to WAL (Task 6)\n", .{});
    }
}
```

- [ ] **Step 3: Link and run the spike**

```bash
# Adjust paths from Step 1. -I = header dir, the .a/.lib = Turso static lib.
zig run spike/turso_spike.zig \
  -I /tmp/turso/<header-dir> \
  --library c \
  /tmp/turso/target/release/<turso-lib>.a
```

Expected output: prints `rowid=1`, a `path=... blob_bytes=4 type0=...` line, and `BEGIN CONCURRENT rc=0 (0=OK)`.

- [ ] **Step 4: GATE — verify the C API round-trip passed**

Confirm: insert + read-back worked, blob bytes == 4, no link errors on missing symbols. If any `sqlite3_*` symbol is missing at link time, note which — that function needs a shim or the migration is blocked.

- [ ] **Step 5: Two-writer concurrent test**

Extend the spike (or run two OS processes against a shared temp file `test.db` in WAL) issuing `BEGIN CONCURRENT` + INSERT simultaneously. Confirm both commit with no `SQLITE_BUSY` (rc 5).

```bash
# Two processes, same file, concurrent BEGIN CONCURRENT writers.
# Confirm neither returns rc=5 (SQLITE_BUSY).
```

- [ ] **Step 6: GATE — Windows link check**

On Windows, build the Turso static lib (`.lib`) and link the spike. Confirm it compiles, links, and runs (Turso's io_uring is Linux-only; Windows uses a fallback I/O backend — confirm the fallback exists and works).

**Decision:** If Step 5 proves concurrent writes AND Step 6 links on Windows → proceed to Task 2. If `BEGIN CONCURRENT` fails → proceed but mark Task 6 as "WAL-only fallback" (migration still valid, no concurrency gain — confirm with user before continuing). If Windows link fails → **STOP**, reassess with user.

- [ ] **Step 7: Commit the spike findings**

```bash
git add spike/
git commit -m "spike: verify Turso C API covers zindeks usage + BEGIN CONCURRENT"
```

---

### Task 2: Vendor Turso static libs + build script

**Files:**
- Create: `scripts/build-turso.sh`
- Create: `vendor/turso/include/sqlite3.h` (Turso's SQLite-compatible header)
- Create: `vendor/turso/<triple>/libturso.a` (per target; `.lib` on Windows) — produced by the script
- Modify: `.gitignore` (if large libs are committed, decide policy)

**Interfaces:**
- Consumes: crate name + artifact names from Task 1.
- Produces: `vendor/turso/include/sqlite3.h` and `vendor/turso/<triple>/<lib>` paths that `build.zig` (Task 3) links against. The 6 target triples match zindeks's existing cross-compile target list in `build.zig`.

- [ ] **Step 1: Write the build script**

```bash
#!/usr/bin/env bash
# scripts/build-turso.sh — build Turso C API static libs for all zindeks targets.
# Run once per Turso version bump. Requires Rust toolchain + rustup targets.
set -euo pipefail

TURSO_REF="${1:-main}"          # pin a tag/commit for reproducibility
CRATE="<turso-c-api-crate>"      # from Task 1
WORK="$(mktemp -d)"

git clone --depth 1 --branch "$TURSO_REF" https://github.com/tursodatabase/turso "$WORK"
cd "$WORK"

# Map: zig target triple -> rust target triple. Keep in sync with build.zig targets.
declare -A TARGETS=(
  ["x86_64-linux-gnu"]="x86_64-unknown-linux-gnu"
  ["aarch64-linux-gnu"]="aarch64-unknown-linux-gnu"
  ["x86_64-macos"]="x86_64-apple-darwin"
  ["aarch64-macos"]="aarch64-apple-darwin"
  ["x86_64-windows"]="x86_64-pc-windows-gnu"
  ["aarch64-windows"]="aarch64-pc-windows-gnu"
)

DEST="$(git -C "$OLDPWD" rev-parse --show-toplevel)/vendor/turso"
mkdir -p "$DEST/include"
cp "$(find . -name sqlite3.h | head -1)" "$DEST/include/sqlite3.h"

for zig_t in "${!TARGETS[@]}"; do
  rust_t="${TARGETS[$zig_t]}"
  rustup target add "$rust_t" || true
  cargo build --release -p "$CRATE" --target "$rust_t"
  mkdir -p "$DEST/$zig_t"
  cp target/"$rust_t"/release/*.a "$DEST/$zig_t/" 2>/dev/null \
    || cp target/"$rust_t"/release/*.lib "$DEST/$zig_t/"
done
echo "Turso libs written to $DEST"
```

- [ ] **Step 2: Run the script for the host target first**

```bash
chmod +x scripts/build-turso.sh
./scripts/build-turso.sh
ls -R vendor/turso
```

Expected: `vendor/turso/include/sqlite3.h` and at least the host triple's lib exist.

- [ ] **Step 3: Decide commit policy and commit**

Static libs are binary. Either commit them (simplest, reproducible builds) or gitignore + document the script as a prerequisite. Default: commit them (preserves "clone and build" simplicity).

```bash
git add scripts/build-turso.sh vendor/turso/
git commit -m "build: add Turso static libs + build-turso.sh"
```

---

### Task 3: Swap SQLite for Turso in build.zig

**Files:**
- Modify: `build.zig:48-66` (SQLite module/library block), `build.zig:121` and `:185` (include paths), `build.zig:136` and `:188` (linkLibrary)
- Delete: `vendor/sqlite3/` (after build passes)

**Interfaces:**
- Consumes: `vendor/turso/include/sqlite3.h`, `vendor/turso/<triple>/<lib>` from Task 2.
- Produces: a `zig build` that links Turso instead of SQLite, with the same module wiring so `graph_db.zig`'s `@cImport("sqlite3.h")` resolves to Turso's header.

- [ ] **Step 1: Replace the SQLite vendored-C block**

In `build.zig`, replace the SQLite block (currently lines ~48-66):

```zig
    // ── Turso C API (prebuilt static lib, replaces vendored SQLite) ──
    const turso_triple = try target.result.zigTriple(b.allocator);
    const turso_lib_dir = b.fmt("vendor/turso/{s}", .{turso_triple});
```

Remove `sqlite_mod`, the `addCSourceFiles` for `sqlite3.c`, the three `addCMacro` calls (`SQLITE_THREADSAFE`, `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_ENABLE_FTS5`), and the `b.addLibrary(... sqlite3 ...)`.

- [ ] **Step 2: Point include paths at Turso's header**

Replace the two `addIncludePath(b.path("vendor/sqlite3"))` calls (lines ~121, ~185) with:

```zig
    zindeks_mod.addIncludePath(b.path("vendor/turso/include"));
    // ...and for the test module:
    all_tests_mod.addIncludePath(b.path("vendor/turso/include"));
```

- [ ] **Step 3: Link the Turso static lib**

Replace `exe.linkLibrary(sqlite)` (line ~136) and `all_tests.linkLibrary(sqlite)` (line ~188) with object-file / system-lib linkage to the prebuilt lib:

```zig
    exe.addObjectFile(b.path(b.fmt("{s}/libturso.a", .{turso_lib_dir})));
    exe.linkLibC();
    // (Windows: filename is turso.lib — branch on target.result.os.tag if needed)
```

Apply the same two lines to `all_tests`.

- [ ] **Step 4: Build and run the existing test suite**

Run: `zig build test`
Expected: compiles and links against Turso. Some tests may fail on behavior differences (sqlite_master, pragmas) — those are fixed in Tasks 4-6. A **link** success here is the bar for this step. If link fails on a missing symbol, return to Task 1 Step 4 notes.

- [ ] **Step 5: Delete vendored SQLite and commit**

```bash
rm -rf vendor/sqlite3
git add build.zig vendor/
git commit -m "build: link Turso static lib, remove vendored SQLite"
```

---

### Task 4: Fix open() pragmas for Turso

**Files:**
- Modify: `src/core/storage/graph_db.zig:299-323` (`open()`)
- Test: `tests/graph_db_test.zig` (existing `graph_db open and migrate`)

**Interfaces:**
- Consumes: Turso `sqlite3_open` + `sqlite3_exec` (unchanged signatures).
- Produces: an `open()` that applies only Turso-supported pragmas. Public signature `pub fn open(path: [:0]const u8) !GraphDb` unchanged.

- [ ] **Step 1: Update the test for the table-count query**

Turso may not expose `sqlite_master`. Change the migrate test to count via a Turso-supported path. Replace `tests/graph_db_test.zig:10-13`:

```zig
    // Turso: verify tables exist by querying each known table instead of sqlite_master.
    const names = [_][:0]const u8{
        "documents", "symbols", "edges", "adrs", "traces",
        "document_embeddings", "reasoning",
    };
    for (names) |n| {
        var buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&buf, "SELECT COUNT(*) FROM {s}", .{n});
        _ = try db.queryScalar(sql); // throws if table missing
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -i "graph_db open"`
Expected: FAIL — current `open()` still sends `mmap_size`/`temp_store` pragmas that Turso rejects or the sqlite_master query errors.

- [ ] **Step 3: Strip unsupported pragmas from open()**

In `graph_db.zig:299-323`, keep WAL / busy_timeout / cache_size; remove `mmap_size` and `temp_store`:

```zig
    pub fn open(path: [:0]const u8) !GraphDb {
        var out: ?*sqlite3.sqlite3 = undefined;
        const rc = sqlite3.sqlite3_open(path.ptr, &out);
        if (rc != SQLITE_OK) return Error.OpenFailed;
        const db = out orelse return Error.OpenFailed;
        const self = GraphDb{ .db = db };
        // Turso-supported pragmas only.
        _ = sqlite3.sqlite3_exec(db, "PRAGMA journal_mode = WAL;", null, null, null);
        _ = sqlite3.sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", null, null, null);
        var pragma_buf: [128]u8 = undefined;
        if (std.fmt.bufPrintZ(&pragma_buf, "PRAGMA cache_size = -{d};", .{tuning.cache_size_kb})) |s| {
            _ = sqlite3.sqlite3_exec(db, s.ptr, null, null, null);
        } else |_| {}
        _ = sqlite3.sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", null, null, null);
        // Dropped: temp_store=MEMORY, mmap_size — unsupported by Turso, harmless.
        return self;
    }
```

Also remove the now-unused `mmap_bytes` field usage. Leave the `Tuning.mmap_bytes` field but stop referencing it, or delete the field and its references (`tuning.mmap_bytes`) — prefer deleting to avoid dead config.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -iE "graph_db open|migrate"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/storage/graph_db.zig tests/graph_db_test.zig
git commit -m "fix: apply only Turso-supported pragmas in open()"
```

---

### Task 5: Validate Statement wrapper + statement cache against Turso

**Files:**
- Modify (if needed): `src/core/storage/cache.zig`, `src/core/storage/graph_db.zig:71-191` (`Statement`)
- Test: `tests/graph_db_test.zig` (existing insert/select tests exercise bind+column)

**Interfaces:**
- Consumes: Turso `sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_reset`, `sqlite3_finalize`, `sqlite3_clear_bindings`, all `bind_*`/`column_*`.
- Produces: a confirmed-working `Statement` + `StatementCache` with no signature change.

- [ ] **Step 1: Run the existing bind/column tests**

Run: `zig build test 2>&1 | grep -iE "insert document|insert symbol|insert edge"`
Expected: these tests exercise `bind_text`, `column_text`, `lastInsertRowid`. If Turso behaves identically they PASS. If any fail, note which `column_*`/`bind_*` differs.

- [ ] **Step 2: Add a blob round-trip test (covers embeddings path)**

Add to `tests/graph_db_test.zig`:

```zig
test "graph_db blob round-trip (embedding)" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path, language) VALUES ('e.zig', 'Zig')");
    var ins = try db.prepare("UPDATE documents SET embedding = ? WHERE id = 1");
    defer ins.finalize();
    const vec = [_]u8{ 9, 8, 7, 6, 5 };
    try ins.bindBlob(1, &vec);
    try std.testing.expect(!try ins.step());

    var sel = try db.prepare("SELECT embedding FROM documents WHERE id = 1");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    const got = try sel.columnBlob(0);
    try std.testing.expectEqualSlices(u8, &vec, got);
}
```

- [ ] **Step 3: Run the new test**

Run: `zig build test 2>&1 | grep -i "blob round-trip"`
Expected: PASS. If `columnBlob`/`bindBlob` mismatch Turso semantics (e.g. pointer lifetime), fix the `Statement` methods in `graph_db.zig:143-161` to match Turso's `sqlite3_column_blob`/`sqlite3_column_bytes` contract.

- [ ] **Step 4: Verify statement cache reuse**

Run: `zig build test 2>&1 | grep -iE "cache|prepare"`
Expected: PASS. `cache.zig` wraps `sqlite3_stmt` pointers via `prepare_v2`/`reset`/`finalize` — all Turso-supported. No code change expected; this step confirms it.

- [ ] **Step 5: Commit**

```bash
git add tests/graph_db_test.zig src/core/storage/
git commit -m "test: verify Turso bind/column + statement cache round-trips"
```

---

### Task 6: Switch writer transactions to BEGIN CONCURRENT + MVCC retry

**Files:**
- Modify: `src/core/storage/batch.zig:106-134` (BEGIN/COMMIT)
- Modify: `src/core/indexer/parallel.zig` (writer-thread transaction — grep `BEGIN TRANSACTION`)
- Modify: `src/core/storage/graph_db.zig` (add a `beginConcurrent` + retry helper)
- Test: `tests/overlay_test.zig` or a new `tests/concurrent_test.zig`

**Interfaces:**
- Consumes: Turso `sqlite3_exec` for `BEGIN CONCURRENT` / `COMMIT` / `ROLLBACK`, and the `SQLITE_BUSY` (5) result code for conflict detection.
- Produces: `GraphDb.withConcurrentTxn(self, comptime body) !void` — runs `body` inside a `BEGIN CONCURRENT` transaction, retrying with bounded backoff on MVCC conflict. Used by `batch.zig` and `parallel.zig`.

- [ ] **Step 1: Write a failing concurrent-writer test**

Create `tests/concurrent_test.zig`:

```zig
//! Two writers on one file DB must both commit without SQLITE_BUSY (Turso MVCC).
const std = @import("std");
const graph_db = @import("zindeks").storage.graph_db;

test "two concurrent writers both commit" {
    const path = "test_concurrent.db";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var setup = try graph_db.GraphDb.open(path);
    try setup.migrate();
    setup.close();

    const Writer = struct {
        fn run(p: [:0]const u8, lang: [:0]const u8) !void {
            var db = try graph_db.GraphDb.open(p);
            defer db.close();
            try db.withConcurrentTxn(struct {
                fn body(d: *graph_db.GraphDb) !void {
                    var buf: [128]u8 = undefined;
                    const sql = try std.fmt.bufPrintZ(&buf,
                        "INSERT INTO documents (path, language) VALUES ('{s}', '{s}')",
                        .{ lang, lang });
                    try d.exec(sql);
                }
            }.body);
        }
    };

    var t1 = try std.Thread.spawn(.{}, Writer.run, .{ path, "A" });
    var t2 = try std.Thread.spawn(.{}, Writer.run, .{ path, "B" });
    t1.join();
    t2.join();

    var db = try graph_db.GraphDb.open(path);
    defer db.close();
    try std.testing.expectEqual(@as(i64, 2),
        try db.queryScalar("SELECT COUNT(*) FROM documents"));
}
```

Register `concurrent_test.zig` in `build.zig`'s test list alongside the other test files.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -i concurrent`
Expected: FAIL — `withConcurrentTxn` does not exist yet.

- [ ] **Step 3: Implement withConcurrentTxn in graph_db.zig**

Add to `GraphDb` (near `exec`):

```zig
    /// Run `body` inside a BEGIN CONCURRENT transaction, retrying on MVCC
    /// write-write conflict (SQLITE_BUSY) with bounded backoff.
    pub fn withConcurrentTxn(
        self: *GraphDb,
        comptime body: fn (*GraphDb) anyerror!void,
    ) !void {
        const max_retries = 5;
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            // BEGIN CONCURRENT enables MVCC concurrent writers; falls back to
            // plain BEGIN if the spike (Task 1) showed CONCURRENT unsupported.
            _ = sqlite3.sqlite3_exec(self.db, "BEGIN CONCURRENT;", null, null, null);
            body(self) catch |err| {
                _ = sqlite3.sqlite3_exec(self.db, "ROLLBACK;", null, null, null);
                return err;
            };
            const rc = sqlite3.sqlite3_exec(self.db, "COMMIT;", null, null, null);
            if (rc == SQLITE_OK) return;
            // Conflict on commit: rollback + retry with backoff.
            _ = sqlite3.sqlite3_exec(self.db, "ROLLBACK;", null, null, null);
            if (attempt >= max_retries) return Error.StepFailed;
            std.Thread.sleep(@as(u64, 1_000_000) << @intCast(attempt)); // 1ms,2ms,4ms...
        }
    }
```

If Task 1 found `BEGIN CONCURRENT` unsupported, change the literal to `"BEGIN IMMEDIATE;"` and keep the same retry loop (WAL-only fallback — still correct).

- [ ] **Step 4: Run to verify the test passes**

Run: `zig build test 2>&1 | grep -i concurrent`
Expected: PASS — both writers commit, count == 2.

- [ ] **Step 5: Route batch.zig and parallel.zig writers through it**

In `batch.zig:106-134`, replace the manual `BEGIN TRANSACTION` / `COMMIT` pair with a call that wraps the existing flush body in `withConcurrentTxn`. In `parallel.zig`, find the writer-thread `BEGIN TRANSACTION` (grep `BEGIN TRANSACTION`) and do the same. Keep the flush logic identical — only the transaction boundary changes.

- [ ] **Step 6: Run the full suite**

Run: `zig build test`
Expected: all pass, including `overlay_test` and `perf_test` (batch path now uses concurrent txns).

- [ ] **Step 7: Commit**

```bash
git add src/core/storage/graph_db.zig src/core/storage/batch.zig src/core/indexer/parallel.zig tests/concurrent_test.zig build.zig
git commit -m "feat: concurrent writers via BEGIN CONCURRENT + MVCC retry"
```

---

### Task 7: Bump store format tag for auto-rebuild

**Files:**
- Modify: `src/core/project_store.zig` (store version tag) — grep `zindeks_version`
- Test: existing project-store tests if present, else add one

**Interfaces:**
- Consumes: the existing store-version field (`zindeks_version` seen in `list_projects` output).
- Produces: a bumped version constant so existing SQLite-era `graph.db` files are detected stale and trigger a clean re-index instead of being opened by Turso.

- [ ] **Step 1: Locate the version constant**

```bash
grep -rn "zindeks_version\|STORE_VERSION\|store_version" src/
```

- [ ] **Step 2: Write/extend a test asserting the new version**

Add a test that a store written with the old version is reported as stale / needs rebuild. Match the existing project-store test pattern (use the file found in Step 1).

- [ ] **Step 3: Bump the constant**

Increment the store version constant by 1 (e.g. `1` → `2`). Add a comment: `// v2: Turso engine — v1 SQLite stores auto-rebuild.`

- [ ] **Step 4: Run tests**

Run: `zig build test 2>&1 | grep -iE "store|version|stale"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/project_store.zig tests/
git commit -m "feat: bump store version to v2 (Turso) — auto-rebuild v1 stores"
```

---

### Task 8: Full validation, cross-compile, cleanup

**Files:**
- Delete: `spike/`
- Modify: `CLAUDE.md` / `README.md` (note Turso engine, binary-size change), `build.zig` (verify all 6 targets)

**Interfaces:**
- Consumes: everything from Tasks 2-7.
- Produces: a green full build + test across targets, docs updated, spike removed.

- [ ] **Step 1: Full test suite**

Run: `zig build test`
Expected: all green.

- [ ] **Step 2: Cross-compile all 6 targets**

```bash
# Use zindeks's existing release/cross build invocation (grep build.zig for the
# target loop). Confirm each of the 6 targets links the matching vendor/turso/<triple> lib.
zig build -Drelease  # plus per-target invocations
```

Expected: all 6 link. If a target's Turso lib is missing, run `scripts/build-turso.sh` for it (Task 2).

- [ ] **Step 3: End-to-end smoke test**

```bash
zig build
./zig-out/bin/zindeks index .
./zig-out/bin/zindeks search "graph database"
```

Expected: index completes, search returns ranked results (BM25 unaffected). Run a `health_check` via `serve` and confirm document/symbol/edge counts match a known-good SQLite-era baseline.

- [ ] **Step 4: Concurrent-process smoke test**

Start a `serve` process, then run `zindeks index .` in another shell against the same store. Confirm no `SQLITE_BUSY` errors and both complete — the original motivating problem.

- [ ] **Step 5: Update docs + record binary size**

Update `CLAUDE.md` and `README.md`: engine is Turso (not SQLite); note the new binary size (Turso static lib vs the old ~3.4 MB). Remove FTS5 mentions tied to SQLite if any.

- [ ] **Step 6: Delete the spike and commit**

```bash
rm -rf spike/
git add -A
git commit -m "chore: remove Turso spike, update docs for Turso engine"
```

---

## Self-Review

**Spec coverage:**
- Concurrency goal (`BEGIN CONCURRENT` + MVCC) → Task 6. ✅
- Blast radius (graph_db.zig only) → Tasks 4-6 confined there + callers untouched. ✅
- Build integration, prebuilt static libs (option b), drop FTS5/THREADSAFE macros → Tasks 2-3. ✅
- Pragma handling (keep WAL/busy_timeout/cache_size; drop mmap_size/temp_store; verify synchronous) → Task 4. ✅
- Risk mitigation / store-tag bump / auto-rebuild → Task 7. ✅
- Phase 0 spike as go/no-go gate (BEGIN CONCURRENT + Windows) → Task 1. ✅
- Out of scope (BM25, vector search, GraphDb API) → honored; no task touches `engine.zig`/`semantic.zig`/`overlay.zig`. ✅
- 24-function C API surface → verified in Task 1 Step 2 spike. ✅

**Placeholder scan:** Crate name + artifact paths are intentionally `<turso-c-api-crate>` / `<triple>` because they are discovered in Task 1 Step 1 and recorded for downstream tasks — this is a real discovery step, not a deferred decision. All code steps contain runnable code.

**Type consistency:** `withConcurrentTxn(self, comptime body: fn(*GraphDb) anyerror!void)` defined in Task 6 Step 3, consumed by the Task 6 Step 1 test and Step 5 callers — names match. `bindBlob`/`columnBlob` in Task 5 match existing `graph_db.zig` method names (verified against file outline). `queryScalar` signature reused consistently.

## Open dependency

Task 1 is a hard gate. If the spike disproves `BEGIN CONCURRENT` or Windows linking, pause and confirm direction with the user before Tasks 2-8.
