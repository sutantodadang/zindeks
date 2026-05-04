# Zindeks

Zindeks is a dependency-light local code indexing engine written in Zig. It is designed for one-time indexing and many low-latency readers: AI agents can share a long-lived `zindeks serve` process over stdin/stdout JSON-RPC without reloading the index for each request.

By default, Zindeks keeps indexes outside the project tree in a per-user project store. This avoids writing `.zindeks` folders into every repository while still allowing each project to have an isolated immutable index segment.

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

After Zindeks is installed, update the current install from GitHub releases with:

```bash
zindeks update
zindeks update --version v0.1.1
```

```powershell
zindeks update
zindeks update --version v0.1.1
```

`zindeks update` installs into the current executable directory by default. Use `--dir <install-dir>` to choose another location, `--repo <owner/repo>` for forks, `--no-path-update` to skip Windows user PATH edits, and `--dry-run` to print the update plan without downloading anything.

### AI agent install instruction

When an AI agent needs Zindeks, use the GitHub repository `sutantodadang/zindeks`, then run the matching command above for the host OS. Prefer the latest release unless the task specifies a version. After installation, verify with:

```bash
zindeks --help
```

## Storage format

## Project index store

Default indexes are written under the user's cache directory:

| OS | Default root |
| --- | --- |
| Windows | `%LOCALAPPDATA%\\zindeks` |
| Linux/BSD | `${XDG_CACHE_HOME:-~/.cache}/zindeks` |
| macOS | `~/Library/Caches/zindeks` |

The store layout is:

```text
zindeks/
	projects/
		<project-name>-<root-hash>/
			project.json
			current
			lock
			segments/
				<segment-id>/
					meta.idx
					content.idx
					symbol.idx
					posting.idx
					graph.idx
```

Project IDs are derived from the canonical absolute project root plus a stable hash, so repositories with the same folder name do not collide. `zindeks index` writes a fresh immutable segment, then updates `current` after the write succeeds. A lock file prevents concurrent writers from corrupting the same project index. Readers keep opening the segment named by `current`.

Use `--store-root <dir>` to choose another global store, or `--index-dir <dir>` to write/read a direct legacy-style index directory.

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

1. **Scanner** recursively walks source-like files and skips heavy/generated directories (`.git`, `.zig-cache`, `zig-out`, `node_modules`, `target`, `.zindeks`). Files are streamed to the indexer one at a time instead of accumulating the whole scan in memory.
2. **Parser** extracts lightweight symbols from Zig-like syntax (`fn`, `const`, `var`, `@import`).
3. **Writer** streams document content directly to `content.idx`, interns strings, tokenizes identifiers, records symbols/imports, sorts tables, and writes an immutable segment.

During tokenization, repeated terms are aggregated per document before being appended to the global posting candidates. This keeps indexing memory closer to unique terms per active file plus global metadata, rather than every token occurrence in every file.

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
zig build run -- search "database connection" ./repo
zig build run -- serve ./repo

# Optional direct index directory, useful for tests or portable artifacts.
zig build run -- index ./repo --index-dir .zindeks
zig build run -- search "database connection" --index-dir .zindeks

# Optional custom global store root.
zig build run -- index ./repo --store-root /tmp/zindeks-store
zig build run -- search "database connection" ./repo --store-root /tmp/zindeks-store

# Update the installed binary from GitHub releases.
zindeks update
zindeks update --version v0.1.1
zindeks update --dry-run
```

## Performance strategy

- Fixed-size records and offset tables avoid per-record heap allocations.
- Query engine keeps index files open for daemon lifetime.
- Search hot path scans contiguous posting slices, ranks document IDs first, and only builds snippets for the final top-k results.
- Tokenization uses stack buffers and ASCII byte-level normalization.
- Scanner and writer process files one at a time; source bytes are streamed directly into `content.idx` instead of being retained for the full indexing run.
- Writer aggregates repeated tokens per document before adding posting candidates, reducing peak memory on repetitive source files.
- Prefetch-friendly layout keeps postings and records sequential; future mmap backend can add platform prefetch hints around posting slices.
- The global project store writes fresh immutable segments and flips the `current` pointer after success, preparing the format for incremental multi-segment indexing and compaction.

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
Measure-Command { zig build run -Doptimize=ReleaseFast -- index . --store-root .zig-cache/zindeks-bench }
Measure-Command { zig build run -Doptimize=ReleaseFast -- search "auth middleware" --store-root .zig-cache/zindeks-bench }
```

## License

Zindeks is licensed under the [Apache License 2.0](LICENSE).
