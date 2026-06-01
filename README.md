# Zindeks

Dependency-light code knowledge graph engine in Zig. One-time index, many low-latency readers. AI agents share a long-lived `zindeks serve` process over stdin/stdout JSON-RPC (MCP-compliant). Single static binary: ~3.4 MB, zero runtime dependencies.

**Current status:** 20+ languages (tree-sitter), 23 MCP tools, SQLite graph database, BM25 + semantic + hybrid search (RRF), document embeddings, call graph tracing, Leiden community detection, incremental indexing, cross-platform (6 targets). AST-level symbol/edge extraction for 10 languages; BM25 across all.

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

### AI agent setup (one command)

After installing the binary:

```bash
zindeks install            # interactive: picks your AI host(s), wires MCP, offers to index
zindeks install --host claude-code --scope both --yes   # non-interactive
zindeks doctor             # verify
```

See [INTEGRATIONS.md](INTEGRATIONS.md) for per-host adapter details and exact paths written.

### Concurrent MCP over HTTP (multi-agent)

By default `zindeks serve` speaks MCP over stdio (one client per process).
For multiple agents sharing one warm index with concurrent tool dispatch, run
the HTTP daemon and point clients at it:

    zindeks serve --http 7337                 # start the shared daemon
    zindeks install --host claude-code --http 7337 --yes   # register HTTP transport
    # or manually:
    claude mcp add --transport http zindeks http://127.0.0.1:7337/mcp

Read-only tools run in parallel; mutating tools (index/update) are serialized.
The daemon must be running for the HTTP transport to work (unlike stdio, which
the client auto-spawns).

## Quick start

```bash
zindeks index .                     # Index current repo (shows progress)
zindeks search "database pool" .    # BM25 keyword search
zindeks serve                       # Start MCP-compliant JSON-RPC server
zindeks bench cold-index .          # Benchmark indexing speed (3 iters, prints min/mean/p99/peak_rss)
zindeks bench answer-quality        # Retrieval quality: precision/recall/F1 vs grep baseline (see ANSWER_QUALITY.md)
```

## Supported languages

20+ languages via vendored tree-sitter grammars:

C, C++, C#, CSS, Dart, Elixir, Go, Haskell, Java, JavaScript, JSON, Lua, Python, Rust, Scala, Swift, TOML, TypeScript, TSX, YAML, Zig

Automatic language detection by file extension.

**AST symbol + edge extraction** (functions, methods, types, and `CALLS`/`CONTAINS`/`IMPORTS` edges — powering `search_graph`, `trace_call_path`, `get_architecture`, `query_graph`) is implemented for 10 languages: Zig, Python, JavaScript, TypeScript, TSX, Go, Rust, Java, C, C++. Zig uses a dedicated extractor; the other nine use a config-driven tree-sitter extractor (`generic_extractor.zig`).

**Call edge coverage**: intra-file calls and unambiguous cross-file calls are resolved. A cross-file `CALLS` edge is created when the callee name is defined exactly once across the indexed repo (confidence 0.9). Calls to names with multiple definitions (e.g. `init`, `new`) are deliberately left unresolved to preserve precision. Import-scope disambiguation (tracking `const alias = @import(...)`) is future work.

The remaining languages are still fully indexed for **BM25 keyword search** (`search` with mode="keyword") and stored in the SQLite graph, but graph-edge results for them are sparse.

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

Single `search` tool with a `mode` parameter:

- **`search` (mode="keyword")** — Full BM25+ with IDF normalization. Streams results as `notifications/zindeks/searchResult` notifications when `stream:true`.
- **`search` (mode="semantic")** — Document-embedding cosine similarity (natural-language queries).
- **`search` (mode="hybrid", default)** — BM25 + semantic fused via Reciprocal Rank Fusion (RRF), with per-source scores. Falls back to keyword when no embeddings are available.

BM25 internals:

- **IDF:** `log(1 + (N - df + 0.5) / (df + 0.5))`
- **TF:** `tf * (k1 + 1) / (tf + k1 * (1 - b + b * doc_len / avg_doc_len))`
- **Defaults:** k1 = 1.5, b = 0.75
- **Query-aware snippets** with newline-aligned context expansion
- **CamelCase splitting** for tokenization
- Deterministic sort by score then path

Embeddings are generated at index time and stored alongside the graph; `health_check` reports the embedding count.

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

### 23 tools

**Indexing & projects**

| Tool | Description |
| --- | --- |
| `index_repository` | Index a repo: binary + tree-sitter pipeline (incremental by default, `force` for full rebuild) |
| `update_index` | Apply added/modified/deleted files to graph DB + rebuild BM25 overlay (fast on small deltas) |
| `detect_changes` | Find added/modified/deleted files vs index without re-indexing |
| `list_projects` | List indexed projects in store |
| `delete_project` | Remove project from store |
| `get_graph_schema` | Node/edge types with current counts |
| `health_check` | Document/symbol/edge/embedding/community counts, last-indexed time, uptime |

**Search**

| Tool | Description |
| --- | --- |
| `search` | Unified search: mode="keyword" (BM25, optional streaming), "semantic" (embeddings), "hybrid" (default, RRF fusion) |
| `search_graph` | Symbol search by name pattern, kind, or degree |
| `get_code_snippet` | Source snippet by symbol name |
| `query_graph` | Read-only SQL or Cypher (`MATCH ... RETURN`) against graph DB |

**Read & navigation**

| Tool | Description |
| --- | --- |
| `read_file` | Read a file by path, numbered + paged (offset/limit) |
| `list_files` | List indexed files by glob/dir (replaces Glob) |
| `file_outline` | Symbol names/kinds/line-ranges for one file, no full content |
| `get_context` | Assemble token-budgeted AI context from search + call graph + architecture |
| `summarize_symbol` | Signature, purpose, key ops, deps, complexity for a symbol |

**Graph analysis**

| Tool | Description |
| --- | --- |
| `trace_call_path` | BFS trace from a symbol (inbound/outbound/both), cycle-safe |
| `get_architecture` | Fan-in/out, entry points, hotspots, module coupling |
| `detect_communities` | Community operations: action="run" (Leiden detection), "list" (all communities), "get" (symbol's community) |

**Editing, records & config**

| Tool | Description |
| --- | --- |
| `rename_symbol` | In-place symbol rename across files (dry-run default) |
| `manage_adr` | Create/read/list Architecture Decision Records |
| `ingest_traces` | Ingest runtime trace data (JSON) |
| `config` | Get or set configuration — no params returns current config; any param updates + persists |

Example tool calls:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"database pool","limit":10}}}
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"database pool","mode":"keyword","limit":10}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_graph","arguments":{"pattern":"%Handler%","kind":"function"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"trace_call_path","arguments":{"name":"main","direction":"outbound","max_depth":5}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_architecture","arguments":{}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_graph","arguments":{"query":"MATCH (a)-[r:CALLS]->(b) RETURN a.name, b.name LIMIT 20"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"detect_communities","arguments":{}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"detect_communities","arguments":{"action":"list","limit":20}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"detect_communities","arguments":{"action":"get","symbol_name":"handleSearch"}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"config","arguments":{}}}
```

## Incremental indexing

- `detect_changes` compares file metadata (size, mtime) against the SQLite documents table — returns added/modified/deleted sets without re-reading files
- `health_check` reports document/symbol/edge/embedding/community counts and last-indexed timestamp
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

Speed benchmarks: `zindeks bench cold-index .` — see `BENCHMARKS.md`.
Answer-quality benchmarks (precision/recall/F1 vs grep): `zindeks bench answer-quality` — see `ANSWER_QUALITY.md`.

## Architecture Decision Records

Store project decisions in the graph database:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"manage_adr","arguments":{"action":"create","title":"Use SQLite for graph storage","context":"Need fast local queries without external DB","decision":"Embed SQLite via @cImport, auto-migrate schema"}}}
```

ADRs are queryable and version-tracked. Use `manage_adr` with `action: "list"` or `action: "get"` to retrieve them.

## License

Zindeks is licensed under the [Apache License 2.0](LICENSE).
