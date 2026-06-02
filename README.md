# Zindeks

A dependency-light **code knowledge graph engine** in Zig. Index a repo once, then
let your AI agent query it over a long-lived MCP server — fast hybrid search, call
graphs, architecture analysis, and one-call fused context. Single static binary
(~3.4 MB), zero runtime dependencies.

**Highlights:** 20+ languages (tree-sitter) · 23 MCP tools · BM25 + semantic + hybrid
search (RRF) · call-graph tracing · Leiden community detection · incremental indexing ·
6 cross-platform targets. AST symbol/edge extraction for 10 languages; BM25 keyword
search for all.

---

## Quickstart

```bash
# 1. Install the binary (see "Install" below), then:
zindeks index .            # index the current repo
zindeks install            # wire zindeks into your AI host(s) + offer to index
zindeks doctor             # verify
```

Then, in your agent, **start every task with `get_context`** — see
[Using zindeks from your AI agent](#using-zindeks-from-your-ai-agent).

---

## Install

Release binaries are published on each `v*` tag for Linux, macOS, and Windows
(`x86_64` + `aarch64`).

**Unix-like:**

```bash
curl -fsSL https://raw.githubusercontent.com/sutantodadang/zindeks/main/scripts/install.sh | sh
# specific version:
curl -fsSL https://raw.githubusercontent.com/sutantodadang/zindeks/main/scripts/install.sh | sh -s -- --version v0.1.0
```

**Windows PowerShell:**

```powershell
$repo = "sutantodadang/zindeks"
$script = Join-Path $env:TEMP "install-zindeks.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/$repo/main/scripts/install.ps1" -OutFile $script
& $script -Repo $repo                 # add -Version v0.1.0 for a specific release
```

**Update an existing install:**

```bash
zindeks update                  # latest
zindeks update --version v0.1.1
```

`update` installs into the current executable's directory by default. Flags:
`--dir <dir>`, `--repo <owner/repo>` (forks), `--no-path-update` (skip Windows PATH
edits), `--dry-run`.

**Build from source** (requires Zig 0.15.2; all deps vendored, no network needed):

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/zindeks index .
```

---

## Set up your AI agent

`zindeks install` does two things for each selected host:

1. **Registers the MCP server** in the host's config (`mcpServers` entry).
2. **Writes zindeks-first search guidance + enforcement hooks** into the current repo.

```bash
zindeks install                                   # interactive: pick host(s), wire MCP, offer to index
zindeks install --host claude-code,cursor,kiro --yes   # non-interactive
zindeks install --list-hosts                      # show hosts + detection status
zindeks doctor                                    # verify
```

Supported hosts: `claude-code`, `cursor`, `vscode`, `windsurf`, `antigravity`, `kiro`.

### Scope: where the MCP entry is registered

`--scope user` (default) writes to the host's global config; `--scope project` writes
to the repo's local config; `--scope both` does both. **Enforcement guardrails are
always written to the current repo regardless of scope** — so `install --yes` from a
repo enforces zindeks-first search there for every selected host.

| Host | MCP config (user / project) | Enforcement written to the repo |
|---|---|---|
| `claude-code` | `~/.claude/settings.json` / `<repo>/.claude/settings.json` + `CLAUDE.md` | `PreToolUse` hook (binary) in settings.json; `Grep`/`Glob` → zindeks, broad shell search → advisory |
| `cursor` | `~/.cursor/mcp.json` / `<repo>/.cursor/mcp.json` | `.cursor/rules/zindeks-first.mdc`, `.cursor/hooks.json`, `.cursor/hooks/enforce-zindeks-search.js` |
| `kiro` | `~/.kiro/settings/mcp.json` / `<repo>/.kiro/settings/mcp.json` | `preToolUse` hook in each `.kiro/agents/*.json` + `.kiro/hooks/enforce-zindeks-search.js` |
| `vscode` | user `mcp.json` / `<repo>/.vscode/mcp.json` | `.github/copilot-instructions.md` guidance |
| `windsurf` | `~/.codeium/windsurf/mcp_config.json` | `AGENTS.md` guidance |
| `antigravity` | `~/.antigravity/mcp.json` / `<repo>/.antigravity/mcp.json` | `AGENTS.md` guidance |

Every host also gets an `AGENTS.md` zindeks-first block. The shared
`enforce-zindeks-search.js` is plain Node.js (no jq/bash). It nudges agents toward
zindeks before broad shell search (`rg`, `grep`, `git grep`, `findstr`,
`Select-String`, recursive `Get-ChildItem`/`gci`, `dir /s`) unless the command already
invokes zindeks — Cursor prompts (`ask`), Claude gets a non-blocking advisory, and Kiro
blocks (exit 2) with guidance since it has no prompt. Kiro hooks are **per-agent**, so
re-run `install` after adding new agents.

See [INTEGRATIONS.md](INTEGRATIONS.md) for exact paths and JSON shapes.

### Always-on server (`--service`)

`--service` installs an OS supervisor that keeps `zindeks serve --http` running in the
background (auto-start at login, restart on crash) so multiple agents share one warm
index. It implies the HTTP transport (default port `7717`; override with `--http <port>`)
and registers that transport with the selected hosts.

```bash
zindeks install --http 7337 --service --yes   # install + HTTP transport + supervisor
zindeks install --uninstall-service           # stop and remove the supervisor
```

The supervisor is launchd (macOS), systemd-user (Linux), or a Scheduled Task (Windows).
It runs whenever the machine is awake; OS sleep suspends it and it auto-resumes on wake.

### Concurrent MCP over HTTP (multi-agent)

`zindeks serve` speaks MCP over stdio (one client per process) by default. For multiple
agents sharing one warm index with concurrent dispatch, run the HTTP daemon:

```bash
zindeks serve --http 7337                                # start the shared daemon
zindeks install --host claude-code --http 7337 --yes     # register HTTP transport
# or manually:
claude mcp add --transport http zindeks http://127.0.0.1:7337/mcp
```

Read-only tools run in parallel; mutating tools (index/update) are serialized. The
daemon must be running for the HTTP transport (stdio auto-spawns; HTTP does not).

---

## Using zindeks from your AI agent

**Start almost every task with `get_context`.** It is the most powerful entry point: one
call returns community-reranked code snippets + 1-hop call-graph neighbors + recalled
prior reasoning, token-budgeted — usually everything you need to start editing without
chaining `search` → `read_file` → `trace_call_path`.

```jsonc
// One fused call. Pass working_set (files you're editing) to bias ranking.
{"name":"get_context","arguments":{"query":"how is auth middleware wired?","working_set":["src/api/server.zig"]}}
```

Then drop to the narrower tools for surgical follow-ups:

| Need | Tool |
|---|---|
| **Understand code before editing (START HERE)** | `get_context(query, working_set?)` |
| Search (hybrid BM25+semantic, default) | `search(query)` (`mode="keyword"` / `"semantic"` to force one) |
| Symbol definition | `search_graph(name_pattern)` |
| Callers / callees | `trace_call_path(name, direction)` |
| Source snippet | `get_code_snippet(name)` |
| Read a file (numbered, paged) | `read_file(path, offset, limit)` |
| List files | `list_files(pattern, dir)` |
| File outline (symbols only) | `file_outline(path)` |
| Architecture / hotspots | `get_architecture()` |
| Custom relation | `query_graph("MATCH ...")` |

If a tool returns "No project loaded", call `index_repository` with the repo's absolute
path (or run `zindeks index .`).

---

## CLI

```bash
zindeks index [repo] [--store-root dir] [--index-dir dir]      # index (incremental)
zindeks search <query> [repo] [--store-root dir]               # BM25 keyword search
zindeks serve [--http <port>] [--store-root dir]               # MCP JSON-RPC server
zindeks install [--host <id,...>] [--scope user|project|both]  # wire into AI hosts
                [--http <port>] [--service] [--yes] [--dry-run] [--list-hosts]
zindeks install --uninstall-service
zindeks update [--version tag|latest] [--repo owner/repo] [--dir dir] [--no-path-update] [--dry-run]
zindeks doctor                                                 # verify host wiring
zindeks bench cold-index .                                     # indexing speed (min/mean/p99/peak_rss)
zindeks bench answer-quality                                   # precision/recall/F1 vs grep (ANSWER_QUALITY.md)
```

Default index store (override with `--store-root`, or `--index-dir` for a direct path):

| OS | Default root |
| --- | --- |
| Windows | `%LOCALAPPDATA%\zindeks` |
| Linux/BSD | `${XDG_CACHE_HOME:-~/.cache}/zindeks` |
| macOS | `~/Library/Caches/zindeks` |

---

## Supported languages

20+ languages via vendored tree-sitter grammars, auto-detected by extension:

> C, C++, C#, CSS, Dart, Elixir, Go, Haskell, Java, JavaScript, JSON, Lua, Python,
> Rust, Scala, Swift, TOML, TypeScript, TSX, YAML, Zig

**AST symbol + edge extraction** (functions, methods, types, and
`CALLS`/`CONTAINS`/`IMPORTS` edges — powering `search_graph`, `trace_call_path`,
`get_architecture`, `query_graph`) is implemented for 10 languages: **Zig, Python,
JavaScript, TypeScript, TSX, Go, Rust, Java, C, C++**. Zig uses a dedicated extractor;
the others use a config-driven tree-sitter extractor (`generic_extractor.zig`). All
other languages still get full **BM25 keyword search** but sparse graph edges.

**Call-edge coverage:** intra-file calls and unambiguous cross-file calls resolve. A
cross-file `CALLS` edge is created when the callee name is defined exactly once across
the repo (confidence 0.9); ambiguous names (e.g. `init`, `new`) are left unresolved to
preserve precision.

---

## How it works

### Indexing pipeline

`zindeks index` runs two phases:

1. **Binary indexer** — scans sources, tokenizes identifiers, builds the BM25 inverted
   index. Emits 5 immutable mmap files (meta, content, symbol, posting, graph).
2. **Knowledge graph builder** — re-scans, parses with tree-sitter, extracts symbols and
   typed edges into SQLite (`graph.db`).

Files larger than 256 MB are skipped. Re-indexing is incremental: `detect_changes`
compares file size/mtime against the `documents` table; only changed files are
transactionally re-inserted. A `PollWatcher` can trigger automatic re-index.

### Search engine

One `search` tool, three modes:

- **`keyword`** — full BM25+ with IDF normalization; can stream results
  (`notifications/zindeks/searchResult`) when `stream:true`.
- **`semantic`** — document-embedding cosine similarity for natural-language queries.
- **`hybrid`** (default) — BM25 + semantic fused via Reciprocal Rank Fusion (RRF);
  falls back to keyword when no embeddings exist.

BM25: `IDF = log(1 + (N − df + 0.5)/(df + 0.5))`,
`TF = tf·(k1+1)/(tf + k1·(1 − b + b·len/avglen))`, defaults `k1=1.5`, `b=0.75`,
CamelCase tokenization, query-aware snippets, deterministic score-then-path sort.

### Knowledge graph

- **Call-graph tracing** — BFS with cycle detection (inbound/outbound/both).
- **Architecture analysis** — fan-in/out, entry points, module coupling.
- **Community detection** — Leiden (modularity gain + refinement). Lazily detected on
  first use and cached, then used to **rerank `search` and `get_context`**: cohesion for
  narrow queries (find-def/usage/debug), diversity for broad ones (explore/explain/refactor).
- **Cypher** — `MATCH ... WHERE ... RETURN ...` translated to SQL.

Edge types: `CALLS`, `IMPORTS`, `DEFINES`, `IMPLEMENTS`, `INHERITS`, `CONTAINS`,
`REFERENCES`, `HTTP_CALLS`, `FILE_CHANGES_WITH`.

`graph.db` tables: `documents`, `symbols` (incl. `community_id`), `edges`, `adrs`,
`traces`. Schema auto-migrates on open.

---

## MCP server & tools

`zindeks serve` is a JSON-RPC 2.0 server with MCP-compliant framing (Content-Length
headers, initialize handshake, capability negotiation). 23 tools:

**Indexing & projects:** `index_repository`, `update_index`, `detect_changes`,
`list_projects`, `delete_project`, `get_graph_schema`, `health_check`

**Search & read:** `search`, `search_graph`, `get_code_snippet`, `query_graph`,
`read_file`, `list_files`, `file_outline`, **`get_context`** (start here),
`summarize_symbol`

**Graph analysis:** `trace_call_path`, `get_architecture`, `detect_communities`

**Editing, records & config:** `rename_symbol`, `manage_adr`, `ingest_traces`, `config`

Example calls:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{"query":"how is auth wired","working_set":["src/api/server.zig"]}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"database pool","limit":10}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_graph","arguments":{"name_pattern":"%Handler%","kind":"function"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"trace_call_path","arguments":{"name":"main","direction":"outbound","max_depth":5}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_graph","arguments":{"query":"MATCH (a)-[r:CALLS]->(b) RETURN a.name, b.name LIMIT 20"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"detect_communities","arguments":{"action":"list","limit":20}}}
```

### Architecture Decision Records

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"manage_adr","arguments":{"action":"create","title":"Use SQLite for graph storage","context":"Need fast local queries without an external DB","decision":"Embed SQLite via @cImport, auto-migrate schema"}}}
```

ADRs are queryable and version-tracked (`action: "list"` / `"get"`).

---

## Performance

- Binary indexer: mmap reads, fixed-size records, zero deserialization.
- SQLite: WAL mode, prepared statements, bounded result sets.
- BM25: posting-slice scans, score-then-snippet (only top-k snippets built).
- Scanner: single-pass walk, streaming content, 256 MB skip threshold.
- Cross-compiles to 6 targets from any host OS.

Benchmarks: `zindeks bench cold-index .` (see `BENCHMARKS.md`) and
`zindeks bench answer-quality` (see `ANSWER_QUALITY.md`).

## License

Zindeks is licensed under the [Apache License 2.0](LICENSE).
