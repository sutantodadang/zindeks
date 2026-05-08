# Zindeks

Dependency-light code knowledge graph engine in Zig. One-time index, many low-latency readers. AI agents share a long-lived `zindeks serve` process over stdin/stdout JSON-RPC (MCP-compliant). Single static binary: ~3.4 MB, zero runtime dependencies.

**Current status:** 20+ languages (tree-sitter), 14 MCP tools, SQLite graph database, BM25 search, call graph tracing, Leiden community detection, incremental indexing, cross-platform (6 targets).

## Install from GitHub releases

Release binaries are published when a `v*` tag is pushed. Assets built for:

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

To install a specific release:

```bash
curl -fsSL https://raw.githubusercontent.com/sutantodadang/zindeks/main/scripts/install.sh | sh -s -- --version v0.1.0
```

```powershell
& $script -Repo $repo -Version v0.1.0
```

Update the current install:

```bash
zindeks update
zindeks update --version v0.1.1
```

`zindeks update` installs into the current executable directory by default. Use `--dir <install-dir>` for custom location, `--repo <owner/repo>` for forks, `--no-path-update` to skip Windows PATH edits, `--dry-run` to preview without downloading.

### AI agent install instruction

When an AI agent needs Zindeks, use the GitHub repository `sutantodadang/zindeks`, then run the matching install command above for the host OS. Prefer the latest release. Verify with `zindeks --help`.

## Quick start

```bash
zindeks index .                     # Index current repo (shows progress)
zindeks search "database pool" .    # BM25 keyword search
zindeks serve                       # Start MCP-compliant JSON-RPC server
```

## Supported languages

20+ languages via vendored tree-sitter grammars:

C, C++, C#, CSS, Dart, Elixir, Go, Haskell, Java, JavaScript, JSON, Lua, Python, Rust, Scala, Swift, TOML, TypeScript, TSX, YAML, Zig

Automatic language detection by file extension. Symbol extraction currently implemented for Zig; other languages use the binary indexer for BM25 search and the SQLite graph for symbol storage.

## Indexing pipeline

`zindeks index` runs a two-phase pipeline:

1. **Binary indexer** — scans source files, tokenizes identifiers, builds BM25 inverted index. Outputs 5 immutable binary files (meta, content, symbol, posting, graph) with mmap-based read access.

2. **Knowledge graph builder** — re-scans files, parses with tree-sitter AST, extracts symbols (functions, structs, enums, variables, imports), and writes structured records to SQLite. Populates the graph database with typed nodes and edges.

Progress is printed to stderr during indexing (`Indexing '...'... 100 source files scanned...`). Files larger than 256 MB are skipped with a warning.

## Storage

### Index store

Default indexes are written under the user's cache directory:

| OS | Default root |
| --- | --- |
| Windows | `%LOCALAPPDATA%\zindeks` |
| Linux/BSD | `${XDG_CACHE_HOME:-~/.cache}/zindeks` |
| macOS | `~/Library/Caches/zindeks` |

```
zindeks/
  projects/
    <project-name>-<root-hash>/
      project.json
      current
      lock
      segments/
        <segment-id>/
          meta.idx    content.idx    symbol.idx    posting.idx    graph.idx
          graph.db    (SQLite)
```

Use `--store-root <dir>` to choose another global store, or `--index-dir <dir>` for direct legacy-style index.

### Binary files (mmap)

Five immutable files for the BM25 search engine:

| File | Contents |
| --- | --- |
| `meta.idx` | Document metadata, global string table |
| `content.idx` | Chunked source bytes |
| `symbol.idx` | Sorted symbol records + hash index |
| `posting.idx` | Sorted term records + posting lists |
| `graph.idx` | Import/dependency records |

All files use fixed-size records with offset tables. Read path is mmap-first — no deserialization.

### Graph database (SQLite)

Single `graph.db` file with 5 tables:

| Table | Purpose |
| --- | --- |
| `documents` | File paths, languages, content hashes, mtimes |
| `symbols` | Extracted symbols (name, kind, location, community) |
| `edges` | Typed relationships (CALLS, IMPORTS, DEFINES, etc.) |
| `adrs` | Architecture Decision Records |
| `traces` | Ingested runtime traces |

9 indexes for fast querying. Schema auto-migrates on open.

## Search engine

Full BM25+ with IDF normalization:

- **IDF:** `log(1 + (N - df + 0.5) / (df + 0.5))`
- **TF:** `tf * (k1 + 1) / (tf + k1 * (1 - b + b * doc_len / avg_doc_len))`
- **Defaults:** k1 = 1.5, b = 0.75
- **Query-aware snippets** with newline-aligned context expansion
- **CamelCase splitting** for tokenization
- Deterministic sort by score then path

## Knowledge graph

### Graph operations

- **Call graph tracing** — BFS traversal with cycle detection, inbound/outbound/both directions
- **Architecture analysis** — fan-in/fan-out, entry points, module-level statistics
- **Community detection** — Leiden algorithm (modularity gain + refinement), auto-partitions symbols
- **Cypher queries** — lexer/parser/executor, `MATCH ... WHERE ... RETURN ...` translated to SQL

### Edge types

`CALLS`, `IMPORTS`, `DEFINES`, `IMPLEMENTS`, `INHERITS`, `CONTAINS`, `REFERENCES`, `HTTP_CALLS`, `FILE_CHANGES_WITH`

## MCP server

`zindeks serve` starts a JSON-RPC 2.0 server over stdin/stdout with MCP-compliant protocol framing (Content-Length headers, initialize handshake, capability negotiation).

### 14 tools

| Tool | Description |
| --- | --- |
| `index_repository` | Index a repo: binary + tree-sitter pipeline |
| `list_projects` | List indexed projects in store |
| `search_code` | BM25 keyword search with scored snippets |
| `get_graph_schema` | Table counts and schema overview |
| `search_graph` | Symbol search with kind/degree filters |
| `get_code_snippet` | Source snippet by symbol name |
| `query_graph` | Read-only SQL or Cypher against graph DB |
| `detect_changes` | Find added/modified/deleted files vs index |
| `index_status` | File-level staleness report |
| `delete_project` | Remove project from store |
| `trace_call_path` | BFS trace from a symbol (inbound/outbound/both) |
| `get_architecture` | Fan-in/out, entry points, module stats |
| `manage_adr` | Create/read/list Architecture Decision Records |
| `detect_communities` | Run Leiden community detection |
| `rename_symbol` | In-place symbol rename across files (dry-run default) |
| `ingest_traces` | Ingest runtime trace data (JSON) |

Example tool calls:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_code","arguments":{"query":"database pool","limit":10}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_graph","arguments":{"pattern":"%Handler%","kind":"function"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"trace_call_path","arguments":{"name":"main","direction":"outbound","max_depth":5}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_architecture","arguments":{}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_graph","arguments":{"query":"MATCH (a)-[r:CALLS]->(b) RETURN a.name, b.name LIMIT 20"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"detect_communities","arguments":{}}}
```

## Incremental indexing

- `detect_changes` compares file metadata (size, mtime) against the SQLite documents table — returns added/modified/deleted sets without re-reading files
- `index_status` shows per-file staleness
- File watcher (`PollWatcher`) uses background thread polling for automatic re-index triggers
- Changed files are transactionally deleted and re-inserted; unchanged files kept untouched

## CLI

```bash
zindeks index [repo] [--store-root dir] [--index-dir dir]
zindeks search <query> [repo] [--store-root dir] [--index-dir dir]
zindeks serve [--store-root dir] [--index-dir dir]
zindeks update [--version tag|latest] [--repo owner/repo] [--dir dir] [--no-path-update] [--dry-run]
```

## Build from source

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/zindeks index .
```

Requires Zig 0.15.2. All dependencies vendored — no network access needed to build.

## Performance

- Binary indexer: mmap-based reads, fixed-size records, zero deserialization
- SQLite: WAL mode, prepared statements, bounded result sets
- BM25: posting slice scans, score-then-snippet (only top-k snippets built)
- Scanner: single-pass file walk, streaming content, 256 MB file skip threshold
- Cross-compiles to 6 targets from any host OS

## Architecture Decision Records

Store project decisions in the graph database:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"manage_adr","arguments":{"action":"create","title":"Use SQLite for graph storage","context":"Need fast local queries without external DB","decision":"Embed SQLite via @cImport, auto-migrate schema"}}}
```

ADRs are queryable and version-tracked. Use `manage_adr` with `action: "list"` or `action: "get"` to retrieve them.

## License

Zindeks is licensed under the [Apache License 2.0](LICENSE).
