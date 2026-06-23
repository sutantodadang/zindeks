# Design: Migrate zindeks graph store from SQLite to Turso

**Date:** 2026-06-23
**Status:** Approved for spec review
**Author:** brainstorming session

## Goal

Replace the vendored SQLite engine in zindeks with
[Turso](https://github.com/tursodatabase/turso) (the Rust in-process SQLite
rewrite, ex-"Limbo") to gain true concurrent writers via `BEGIN CONCURRENT` +
MVCC.

### Why

`graph.db` is written by multiple OS processes: `zindeks index` /
`update_index`, one or more `zindeks serve` agents (cache, communities,
embeddings, auto-refresh). SQLite enforces a **global single-writer lock**, so
these cross-process writers serialize and hit `SQLITE_BUSY` / stall. Turso's
MVCC + `BEGIN CONCURRENT` allows concurrent writers, which is the motivating
problem.

This is a **full replace**: remove `vendor/sqlite3/`, route `graph_db.zig`
through the Turso C API only. No SQLite fallback. Decision made deliberately,
accepting that every one of the 6 cross-compile targets must ship a working
Turso.

## Pre-flight findings (Turso compatibility, as of 2026-06-23)

Source: Turso `COMPAT.md` + `README.md`.

**Covered — zindeks's actual usage:**

- C API core: `sqlite3_open`, `sqlite3_close`, `sqlite3_prepare_v2`,
  `sqlite3_finalize`, `sqlite3_step`, `sqlite3_reset`, `sqlite3_exec` — all ✅.
- Bind/column core ops ✅ (VDBE `Column`, `Blob`, `Insert`, `Int64` etc. all
  Yes). The specific bind/column C functions are core and assumed present —
  confirmed in Phase 0 spike.
- SQL: every statement zindeks issues is ✅ — `CREATE TABLE`, `INSERT` /
  UPSERT / `RETURNING`, `SELECT` + all JOINs, `UPDATE`, `DELETE`,
  `BEGIN`/`COMMIT`/`ROLLBACK`, `SAVEPOINT`.
- `PRAGMA journal_mode=WAL` ✅, `PRAGMA busy_timeout` ✅, `PRAGMA cache_size` ✅.
- `carray()` ❌ — **unused** by zindeks, irrelevant.

**Non-blocker that looked like one:** zindeks does **not** use SQLite FTS5.
BM25 is hand-rolled in Zig (`src/core/search/engine.zig`) over a separate
binary index + delta overlay (`src/core/storage/overlay.zig`). The
`SQLITE_ENABLE_FTS5=1` build flag is **vestigial** — no `CREATE VIRTUAL TABLE
... fts5`, no `MATCH`-against-FTS anywhere in SQL. (All `MATCH` references are
zindeks's own Cypher executor or string ops.) So SQLite's role is a **plain
relational store** of 7 tables: `documents`, `symbols`, `edges`, `adrs`,
`traces`, `document_embeddings`, `reasoning`. Vector embeddings are stored as
BLOBs; cosine similarity is computed in Zig (`semantic.zig`) — engine-agnostic.

**Gaps to handle:**

- `PRAGMA mmap_size`, `PRAGMA temp_store=MEMORY` — likely unsupported / ignored
  (Turso has no temp databases). **Drop them**; harmless to performance, no
  correctness impact.
- `PRAGMA synchronous=NORMAL` — verify in Phase 0; keep if supported.
- **`BEGIN CONCURRENT` is NOT listed in COMPAT's Statements table** (only plain
  `BEGIN TRANSACTION`). The README advertises it, but it may require an
  experimental build flag or specific syntax/version. **This is the
  make-or-break feature** and the first thing the Phase 0 spike must prove.

**Maturity:** Turso self-describes as **not production-ready** (alpha, possible
data loss). Acceptable here because `graph.db` is a derived cache — see Risk
mitigation.

## Architecture / blast radius

SQLite is touched at exactly **one** module boundary:
`src/core/storage/graph_db.zig` — the `@cImport("sqlite3.h")` block plus the
`Statement` and `GraphDb` wrapper structs. Every other module (`engine.zig`
BM25, `semantic.zig` cosine, `overlay.zig`, the indexer, MCP tools) talks to
`GraphDb`'s **Zig API**, never to SQLite directly.

Consequences:

- Rewrite target = `graph_db.zig` cImport + wrappers, plus `cache.zig` (wraps
  `sqlite3_stmt`), and `batch.zig` / `pool.zig` (only via `GraphDb`).
- The **public `GraphDb` Zig API stays byte-for-byte identical** → zero changes
  to any caller. This isolation is the core of why a full replace is tractable.

## Build integration

- Delete `vendor/sqlite3/`. Remove `SQLITE_THREADSAFE`, `SQLITE_ENABLE_FTS5`,
  `SQLITE_OMIT_LOAD_EXTENSION` macros from `build.zig`.
- Add the Turso C-API static library. Two link strategies:
  - **(a) cargo build inside `build.zig`** — invoke
    `cargo build -p <turso-c-api> --release --target <triple>` per target,
    link the resulting `.a` / `.lib`. Requires a Rust toolchain + per-target
    std at build time.
  - **(b) vendor prebuilt static libs** under `vendor/turso/<triple>/`, link
    directly. No Rust at `zig build` time; refresh via a one-time script on
    Turso version bumps.
- **Chosen: (b).** Preserves zindeks's single-command, Rust-free cross-compile
  across all 6 targets. Cost: a `scripts/build-turso.sh` that produces the 6
  static libs once per Turso bump.

## Connection open + pragmas

Rewrite `GraphDb.open()`:

- `sqlite3_open` — unchanged.
- Keep: `PRAGMA journal_mode=WAL`, `PRAGMA busy_timeout=5000`,
  `PRAGMA cache_size`.
- Drop: `PRAGMA mmap_size`, `PRAGMA temp_store` (unsupported, harmless).
- Verify and keep if supported: `PRAGMA synchronous=NORMAL`.
- Add the concurrent-write path (see Concurrency).

## Concurrency (the actual goal)

Cross-process writers currently serialize on SQLite's single-writer lock.
Target: `BEGIN CONCURRENT` + MVCC so `index`, multiple `serve`, and
auto-refresh write without `SQLITE_BUSY`.

- The parallel indexer already funnels all in-process writes through one
  dedicated writer thread in a single transaction — unchanged.
- `batch.zig` + the writer-thread transactions switch `BEGIN` →
  `BEGIN CONCURRENT`.
- Add an **MVCC conflict-retry wrapper**: MVCC can abort a transaction on a
  write-write conflict (unlike SQLite's lock-wait), so writers retry the
  transaction with bounded backoff on conflict.
- **Fallback gate:** if Phase 0 shows `BEGIN CONCURRENT` needs an experimental
  flag or isn't ready, fall back to plain WAL transactions. Still correct, just
  serialized — no worse than today's behavior.

## Risk mitigation

- `graph.db` is a **derived cache**, fully rebuildable by re-indexing from
  source. Turso's alpha "possible data loss" is therefore tolerable: corruption
  → delete + re-index (already a supported recovery path).
- Bump the on-disk store format tag so existing SQLite `graph.db` files are
  detected as stale and auto-rebuilt under Turso (no migration of old data — it
  is regenerated).
- Do the migration on a branch. `health_check` already reports
  document/symbol/edge/embedding/community counts for A/B validation against the
  current SQLite build.

## Phase 0 spike (go/no-go gate — do FIRST)

A throwaway Zig file linking the Turso C API, before committing to the rewrite:

1. Open `:memory:` (or temp file) and create the 7 tables.
2. Prepare / bind / step a round-trip — verify every bind and column function
   zindeks uses (`bind_text`, `bind_blob`, `bind_int64`, `bind_double`,
   `bind_null`, `column_text`, `column_blob`, `column_int64`, `column_double`,
   `column_type`, `column_bytes`, `column_count`, `column_name`,
   `last_insert_rowid`, `errmsg`, `clear_bindings`).
3. `BEGIN CONCURRENT` from two threads/processes → confirm concurrent writes
   with no `SQLITE_BUSY`. **This is the make-or-break test.**
4. Confirm the Turso static lib links and runs on **Windows** (primary dev
   platform; Turso's async io_uring is Linux-only, other platforms use a
   fallback backend).

**Gate:** if step 3 or 4 fails → stop and reassess (drop to WAL-only, or abort
migration). The spike decides go/no-go before any production code changes.

## Out of scope

- Migrating BM25 to Turso's Tantivy FTS — not needed; BM25 is Zig-native.
- Migrating vector search to Turso's native vector indexing — embeddings stay
  BLOBs + Zig cosine for now (possible future optimization, not this work).
- Any change to the `GraphDb` public Zig API or its callers.

## Exact C API surface used by zindeks

For the spike's verification checklist (24 functions, all standard SQLite C
API):

```
sqlite3_open            sqlite3_close           sqlite3_exec
sqlite3_prepare_v2      sqlite3_step            sqlite3_reset
sqlite3_finalize        sqlite3_clear_bindings  sqlite3_last_insert_rowid
sqlite3_errmsg          sqlite3_destructor_type
sqlite3_bind_text       sqlite3_bind_blob       sqlite3_bind_int64
sqlite3_bind_double     sqlite3_bind_null
sqlite3_column_text     sqlite3_column_blob     sqlite3_column_int64
sqlite3_column_double   sqlite3_column_type     sqlite3_column_bytes
sqlite3_column_count    sqlite3_column_name
```
