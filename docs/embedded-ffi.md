# Embedded shared library (C ABI 1)

`zindeks` can be loaded **in-process** by a host application (the Kode editor)
instead of spawning the CLI or an MCP server. The host links/loads the shared
library and drives the same JSON-RPC engine over a small checked C ABI — no
child process, no TCP port, no stdio.

Indexing, graph, search, migration and locking behaviour are unchanged: the
ABI is a thin boundary in front of `Server.executeMessageToBuffer`.

## Files

| Path | Purpose |
| --- | --- |
| `include/zindeks.h` | Public C header (ABI 1). |
| `src/ffi.zig` | The five `zindeks_*` entry points. |
| `build/lib/zindeks.map` | ELF symbol allowlist (version script). |
| `tests/ffi_consumer.c` | C smoke test (`zig build ffi-test`). |
| `tests/ffi_exports_check.zig` | Export allowlist check (`zig build ffi-exports`). |

## Build targets

```sh
zig build library                     # shared library, native target
zig build ffi-test                    # compile + run tests/ffi_consumer.c
zig build ffi-exports                 # assert only zindeks_* is exported
zig build test                        # full suite, incl. embedded_ffi_test.zig
zig build library -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
```

Assets are built for four targets: `x86_64-windows` (`zindeks.dll`),
`x86_64-linux` / `aarch64-linux` (`libzindeks.so`) and `aarch64-macos`
(`libzindeks.dylib`). Each release ships the library, `include/zindeks.h`,
`vendor/sqlite3/SOURCE.md` (SQLite notice) and a metadata file recording the
ABI version, full source revision, and per-file SHA-256 and size.

## ABI

```c
uint32_t zindeks_abi_version(void);                      /* == 1 */
int32_t  zindeks_open(const unsigned char *options, size_t len,
                      ZindeksHandle **out, ZindeksBuffer *error);
int32_t  zindeks_request(ZindeksHandle *handle,
                         const unsigned char *json, size_t len,
                         ZindeksBuffer *response);
void     zindeks_buffer_free(ZindeksBuffer *buffer);
void     zindeks_close(ZindeksHandle *handle);
```

Status codes: `0` success, `1` invalid input, `2` init/internal error,
`3` allocation failure, `4` busy.

### Options

`zindeks_open` takes UTF-8 JSON (copied, not retained):

```json
{
  "repository": "<absolute canonical repository path>",
  "store_root": "<absolute index store path>",
  "watch": true,
  "watch_interval_ms": 2000,
  "pool_conns": 4,
  "worker_threads": 4
}
```

`repository` is required. One handle binds one repository. No process CWD or
environment is consulted or mutated: watcher settings come from the options
only. A repository without a warm index still yields a handle; an explicit
`index_repository` call performs the first index.

### Requests

`zindeks_request` accepts one raw JSON-RPC message (≤ 1 MiB) and returns the raw
JSON-RPC response (≤ 16 MiB). Notifications succeed with an empty response. A
JSON-RPC / tool-level error is inside the response (`error` or
`result.isError`); it is not an ABI error. Invalid UTF-8/JSON, null pointers,
zero lengths and oversize requests are rejected as invalid input before
dispatch.

### Buffer ownership

Every `ZindeksBuffer` is library-owned; release it with
`zindeks_buffer_free`. The function accepts a cleared buffer, and
`zindeks_close` accepts `NULL`. Never free a pointer the library did not
return.

### Thread safety

A handle may be used from several threads; requests are serialized internally.
Do not close a handle while a request is in flight on it.

## SQLite runtime floor

The graph DB is opened in WAL mode and shared across processes. The ABI refuses
to open when the linked SQLite is older than **3.51.3**
(`sqlite3_libversion_number() < 3051003`), reporting the actual version in the
`zindeks_open` error. `health_check` adds `sqlite_version` (string) and
`sqlite_version_number` (integer) to successful payloads for host diagnostics.

## Symbol isolation

A host that also embeds another SQLite (e.g. rusqlite) must not see symbol
interposition. The shared library:

- compiles SQLite with `SQLITE_API=visibility("hidden")`;
- compiles tree-sitter with `TREE_SITTER_HIDE_SYMBOLS`;
- compiles every grammar with `-fvisibility=hidden` + `TREE_SITTER_HIDE_SYMBOLS`;
- links with the ELF version script `build/lib/zindeks.map` (`local: *`);
- marks the five entry points with `export_symbol_names`.

`zig build ffi-exports` verifies the allowlist on every platform by loading the
built library and probing required and forbidden symbols.
