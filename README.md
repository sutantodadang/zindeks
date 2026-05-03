# Zindeks

Zindeks is a dependency-light local code indexing engine written in Zig. It is designed for one-time indexing and many low-latency readers: AI agents can share a long-lived `zindeks serve` process over stdin/stdout JSON-RPC without reloading the index for each request.

## Install from GitHub releases

Release binaries are published when a `v*` tag is pushed. Assets are built for:

- Linux: `x86_64`, `aarch64`
- macOS: `x86_64`, `aarch64`
- Windows: `x86_64`, `aarch64`

Unix-like systems:

```bash
curl -fsSL https://raw.githubusercontent.com/sutantodadang/zindeks/main/scripts/install.sh | sh
```

Windows PowerShell:

```powershell
$repo = "sutantodadang/zindeks"
$script = Join-Path $env:TEMP "install-zindeks.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/$repo/main/scripts/install.ps1" -OutFile $script
& $script -Repo $repo
```

To install a specific release, pass the tag:

```bash
curl -fsSL https://raw.githubusercontent.com/sutantodadang/zindeks/main/scripts/install.sh | sh -s -- --version v0.1.0
```

```powershell
& $script -Repo $repo -Version v0.1.0
```

### AI agent install instruction

When an AI agent needs Zindeks, use the GitHub repository `sutantodadang/zindeks`, then run the matching command above for the host OS. Prefer the latest release unless the task specifies a version. After installation, verify with:

```bash
zindeks --help
```

## Storage format

An index directory is an immutable segment made of five files:

| File | Purpose | Hot-path layout |
| --- | --- | --- |
| `meta.idx` | document metadata and global string table | `Header`, contiguous `DocRecord[]`, `u32 string_offsets[]`, NUL-terminated string bytes |
| `content.idx` | chunked source bytes | `Header`, concatenated content bytes; offsets live in `DocRecord` |
| `symbol.idx` | symbol table and hash index | `Header`, sorted `SymbolRecord[]`, sorted `SymbolHashRecord[]` |
| `posting.idx` | inverted index | `Header`, sorted `TermRecord[]`, contiguous `PostingRecord[]` |
| `graph.idx` | dependency/import graph | `Header`, sorted `ImportRecord[]` |

Every file starts with a fixed-size `Header` containing magic, version, record count, and section offsets. Variable-length data is reached by offsets only. Hot-path records use integer IDs (`doc_id`, `string_id`) instead of strings. Strings are deduplicated in `meta.idx`.

The read path is mmap-first: records are flat, contiguous arrays with no pointer fields and no deserialization step. `MappedFile` uses POSIX `mmap` on Unix-like systems and `NtCreateSection`/`NtMapViewOfSection` on Windows, with an allocated fallback only if a platform mapping call reports unsupported mapping.

## Indexing pipeline

`zindeks index ./repo` runs:

1. **Scanner** recursively walks source-like files and skips heavy/generated directories (`.git`, `.zig-cache`, `zig-out`, `node_modules`, `target`, `.zindeks`).
2. **Parser** extracts lightweight symbols from Zig-like syntax (`fn`, `const`, `var`, `@import`).
3. **Writer** appends document content, interns strings, tokenizes identifiers, records symbols/imports, sorts tables, and writes an immutable segment.

The intended production evolution is LSM-style multi-segment indexing: write a fresh append-only segment for changed files, keep old segments readable, then periodically compact into a larger immutable segment.

## Query engine

Keyword search uses an inverted index with normalized ASCII tokens, camelCase splitting, and a simplified BM25-style `1 + log(tf)` score. Symbol lookup uses a sorted 64-bit hash table over symbol names with collision verification. Context retrieval returns deterministic file snippets plus symbol definitions.

Query priority is contiguous reads over random access: term table binary search, posting slice scan, score aggregation, deterministic sort by score then path.

## MCP-like JSON-RPC server

Run:

```bash
zindeks serve
```

Each request is one JSON-RPC 2.0 object per line on stdin. Responses are always JSON and deterministic.

Tools:

```json
{"jsonrpc":"2.0","id":1,"method":"search","params":{"query":"auth middleware","limit":10}}
{"jsonrpc":"2.0","id":2,"method":"get_file","params":{"path":"src/main.zig"}}
{"jsonrpc":"2.0","id":3,"method":"get_symbols","params":{"path":"src/main.zig"}}
{"jsonrpc":"2.0","id":4,"method":"get_context","params":{"query":"database connection","limit":5}}
```

## CLI

```bash
zig build
zig build run -- index ./repo
zig build run -- search "database connection"
zig build run -- search "database connection" .zindeks
zig build run -- serve
```

## Performance strategy

- Fixed-size records and offset tables avoid per-record heap allocations.
- Query engine keeps index files open for daemon lifetime.
- Search hot path scans contiguous posting slices and returns content slices.
- Tokenization uses stack buffers and ASCII byte-level normalization.
- Writer batches allocations with append-only arrays; production compaction can use arenas per segment.
- Prefetch-friendly layout keeps postings and records sequential; future mmap backend can add platform prefetch hints around posting slices.

Benchmark targets:

| Benchmark | Target |
| --- | --- |
| Cold query against existing index | `< 100ms` process start + open + query on typical local repos |
| Warm daemon query | single-digit ms for common terms |
| Index throughput | track files/sec and extrapolate per 100k files |
| Memory | index read path proportional to mapped pages touched, not total index size once mmap backend is enabled |

Suggested commands:

```bash
zig build -Doptimize=ReleaseFast
Measure-Command { zig build run -Doptimize=ReleaseFast -- index . .zindeks }
Measure-Command { zig build run -Doptimize=ReleaseFast -- search "auth middleware" }
```
