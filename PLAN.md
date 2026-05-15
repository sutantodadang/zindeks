# Zindeks Evolution Plan

## From Binary Indexer to Knowledge Graph MCP Server

**Version:** 0.1.1 → 1.0.0  
**Target Parity:** GitNexus (36K stars) + codebase-memory-mcp (sub-ms queries, 155 languages)  
**Estimated Timeline:** 16–20 weeks  
**MVP Available:** Week 6

---

## 1. Current State vs Target State

### What Zindeks Does Today (≈1,500 LOC)

| Capability | Current | Target |
|---|---|---|
| **Languages parsed** | 1 (Zig-only line parser) | 20+ (Tree-sitter AST) |
| **Index format** | 5 immutable binary files (mmap) | Hybrid: SQLite graph + binary postings |
| **Search** | BM25 without IDF | BM25 + semantic + RRF |
| **Graph queries** | None (graph.idx stores imports only) | Full knowledge graph with BFS/DFS |
| **MCP compliance** | Non-compliant JSON-RPC (4 methods) | Full MCP stdio server (14 tools) |
| **Incremental indexing** | Full re-index only | Diff-based with file watcher |
| **Snippet extraction** | First 240 chars | Query-aware windowing |
| **Community detection** | None | Louvain clustering |
| **Cypher queries** | None | Simplified Cypher subset |
| **Auto-sync** | None | Background file watcher |
| **Cross-service links** | None | HTTP route detection |
| **Architecture analysis** | None | Hotspots, packages, ADRs |
| **Runtime** | Single binary, zero deps | Single static binary, zero deps |

### Competitor Benchmarks

| Metric | codebase-memory-mcp | GitNexus | zindeks (current) |
|---|---|---|---|
| Index Linux kernel (28M LOC) | 3 min | Not published | Not tested |
| Query latency | <1 ms | <10 ms | <1 ms (binary search) |
| Languages | 155 | 8–11 | 1 |
| MCP tools | 14 | 7–16 | 0 (non-compliant) |
| Token savings vs grep | 99% | ~90% | ~80% |
| Binary size | ~50 MB | ~100 MB (Node.js) | ~1 MB |

---

## 2. Architecture Decisions

### 2.1 Storage: Hybrid SQLite + Binary Mmap

**Decision:** Migrate graph and metadata to SQLite. Keep binary mmap for postings and content.

| Component | Technology | Why |
|---|---|---|
| Graph (nodes, edges, symbols) | SQLite (embedded) | Complex joins, graph traversals, ACID incremental updates, Cypher-like queries. The current `graph.idx` is too limited. |
| Postings (inverted index) | Binary mmap (`posting.idx`) | Already fast, zero-copy, battle-tested. SQLite FTS would add overhead. |
| File content | Binary mmap (`content.idx`) | Excellent for snippet retrieval. No change needed. |
| Metadata | SQLite | Enables `JOIN` with graph, fast label lookups, degree queries. |

**Why not pure binary?** Knowledge graphs require mutability, edge traversal, and complex queries. Rebuilding 5 immutable files on every change is unsustainable for incremental indexing.

**Why not pure SQLite?** Your current posting index with binary search is faster and more memory-efficient than SQLite FTS for BM25 search.

### 2.2 Tree-sitter Integration

**Approach:** Vendor tree-sitter core C library + compile grammars as static C objects.

```zig
// build.zig
const ts = b.addStaticLibrary(.{ .name = "tree-sitter" });
ts.addCSourceFiles(.{ .files = &.{"vendor/tree-sitter/lib/src/lib.c"} });

const ts_zig = b.addStaticLibrary(.{ .name = "tree-sitter-zig" });
ts_zig.addCSourceFile(.{ .file = b.path("vendor/tree-sitter-zig/src/parser.c") });
```

**Zig bindings:** Use `zig translate-c` on `tree_sitter/api.h` (~200-line wrapper).

**Grammar strategy:** MVP with 10 languages (Zig, JS/TS, Python, Go, Rust, C, C++, Java, C#, Ruby). Expand to 20+ by v1.0. Each grammar is 100–500 KB compiled.

### 2.3 MCP Protocol Compliance

Current server speaks JSON-RPC 2.0 but is **not MCP**. Required changes:

- `initialize` handshake with protocol version negotiation
- `tools/list` + `tools/call` (not custom methods like `search`)
- `resources/list` + `resources/read` (repo stats, schema, clusters)
- `ping` heartbeat
- Content-Length framing for stdio transport (required by Claude Code, OpenCode)
- Proper JSON-RPC batch request handling

---

## 3. Expanded Module Structure

```
src/
├── main.zig
├── root.zig
├── core/
│   ├── storage/
│   │   ├── binary/
│   │   │   ├── index.zig          # Existing (minimal changes)
│   │   │   ├── writer.zig         # Extract from current index.zig
│   │   │   └── mapped_file.zig    # Extract from current index.zig
│   │   ├── graph_db.zig           # SQLite wrapper, schema, migrations
│   │   └── schema.zig             # Node/edge type definitions
│   ├── scanner/
│   │   ├── scanner.zig            # Enhanced walker
│   │   └── gitignore.zig          # .gitignore / .cbmignore parser
│   ├── indexer/
│   │   ├── indexer.zig            # Orchestrator
│   │   ├── pipeline.zig           # Multi-pass DAG
│   │   ├── incremental.zig        # Diff + update logic
│   │   └── phases/
│   │       ├── structure.zig      # File → Document nodes
│   │       ├── definitions.zig    # Symbol extraction
│   │       ├── imports.zig        # Import resolution
│   │       └── calls.zig          # Call graph edges
│   ├── parser/
│   │   ├── tree_sitter.zig        # C bindings, grammar registry
│   │   ├── registry.zig           # Language → grammar mapping
│   │   └── extractors/            # Per-language AST walkers
│   │       ├── zig.zig
│   │       ├── javascript.zig     # Covers .js, .ts, .tsx, .jsx
│   │       ├── python.zig
│   │       ├── go.zig
│   │       ├── rust.zig
│   │       ├── c_cpp.zig
│   │       └── ...
│   ├── search/
│   │   ├── engine.zig             # Unified search API
│   │   ├── bm25.zig               # IDF-aware BM25 + length norm
│   │   ├── semantic.zig           # Embedding search (Phase 5)
│   │   └── snippet.zig            # Query-aware windowing
│   └── graph/
│       ├── query.zig              # BFS/DFS traversal APIs
│       ├── louvain.zig            # Community detection
│       └── cypher/                # (Phase 4)
│           ├── lexer.zig
│           ├── parser.zig
│           └── executor.zig
├── api/
│   ├── mcp/
│   │   ├── protocol.zig           # Stdio transport, framing, initialize
│   │   ├── server.zig             # Request dispatch
│   │   ├── tools.zig              # 14 tool definitions + handlers
│   │   └── resources.zig          # MCP resources (repos, schema, etc.)
│   └── cli/
│       ├── cli.zig
│       └── update.zig
├── project/
│   ├── store.zig                  # Enhanced project store
│   ├── watcher.zig                # File system watcher
│   └── registry.zig               # Global repo registry (GitNexus-style)
└── tests/
    ├── storage_test.zig
    ├── mcp_protocol_test.zig
    ├── pipeline_test.zig
    ├── graph_test.zig
    └── fixtures/                  # Sample repos for testing
```

---

## 4. Phase Breakdown

### Phase 0: Foundation (Week 1)
**Goal:** Development infrastructure ready.

- [ ] Add SQLite C amalgamation to `vendor/` and link in `build.zig`
- [ ] Add tree-sitter core C library to `vendor/`
- [ ] Set up `zig translate-c` pipeline for tree-sitter API
- [ ] Create graph DB schema with migration system
- [ ] Write `.gitignore` parser (recursive, nested support)
- [ ] **Tests:** SQLite connection, schema creation, gitignore parsing

**Atomic commits:**
1. `build: add vendored sqlite3 and tree-sitter-core`
2. `feat: add gitignore parser with nested support`
3. `feat: add graph_db schema and migrations`

---

### Phase 1: MCP Compliance + Graph Store (Weeks 2–3)
**Goal:** Fully MCP-compliant server with 4 core tools.

- [ ] Implement MCP protocol: `initialize`, `ping`, `tools/list`, `tools/call`
- [ ] Add Content-Length stdio framing
- [ ] Create graph schema: `Document`, `Symbol`, `Module` nodes; `CONTAINS`, `IMPORTS` edges
- [ ] Migrate symbol storage from binary to SQLite
- [ ] Implement tools:
  - `index_repository` — full re-index
  - `list_projects` — from project store
  - `search_code` — text search (reuse BM25 on binary postings)
  - `get_graph_schema` — node/edge counts and types
- [ ] **Tests:** MCP handshake roundtrip, tool schema validation, search_code end-to-end

**Atomic commits:**
4. `feat: implement MCP stdio protocol with initialize handshake`
5. `feat: add graph_db nodes and edges with SQLite`
6. `feat: add index_repository and list_projects MCP tools`

---

### Phase 2: Tree-sitter + Multi-Pass Pipeline (Weeks 4–6)
**Goal:** Real AST parsing for 6 languages, knowledge graph population.

- [ ] Add 6 tree-sitter grammars (Zig, JS/TS, Python, Go, Rust, C/C++)
- [ ] Build AST extractor framework: `extractSymbols`, `extractImports`, `extractCalls`
- [ ] Implement multi-pass pipeline:
  1. **Structure:** Create Document nodes
  2. **Definitions:** Extract functions, classes, variables → Symbol nodes
  3. **Imports:** Resolve cross-file imports → IMPORTS edges
  4. **Calls:** Match call expressions to definitions → CALLS edges
- [ ] Populate SQLite graph from pipeline
- [ ] Implement tools:
  - `search_graph` — label/name/degree filters
  - `get_code_snippet` — by qualified name
  - `query_graph` — simplified graph query API
- [ ] **Tests:** Per-language fixture tests, pipeline integration tests, graph query tests

**Atomic commits:**
7. `feat: add tree-sitter bindings and 6 grammar libraries`
8. `feat: add AST extractors for zig, javascript, python`
9. `feat: implement multi-pass indexing pipeline`
10. `feat: add search_graph and get_code_snippet tools`

**MVP CUTOFF:** At end of Phase 2 (Week 6), zindeks is MCP-compliant, parses 6 languages, has a knowledge graph, and exposes 7 tools. Enough to replace the current version and demonstrate value.

---

### Phase 3: Incremental Indexing + File Watcher (Weeks 7–9)
**Goal:** Sub-second updates on file changes.

- [ ] File watcher: `inotify` (Linux), `FSEvents` (macOS), `ReadDirectoryChangesW` (Windows)
- [ ] Incremental diff: compare file hashes, identify changed/added/deleted files
- [ ] Graph mutations: delete nodes/edges for removed files, update for changed files
- [ ] Implement tools:
  - `detect_changes` — git diff → affected symbols
  - `index_status` — staleness check
  - `delete_project` — cleanup
- [ ] **Tests:** Incremental update correctness, watcher event handling, graph consistency

**Atomic commits:**
11. `feat: add cross-platform file watcher`
12. `feat: implement incremental indexing with graph mutations`
13. `feat: add detect_changes and index_status tools`

---

### Phase 4: Call Graph + Architecture Analysis (Weeks 10–12)
**Goal:** Deep code intelligence.

- [ ] Cross-file call resolution (language-specific import resolution)
- [ ] Implement `trace_call_path` — BFS traversal up/downstream
- [ ] Hotspot detection (high-degree nodes)
- [ ] Language statistics, package detection
- [ ] Implement tools:
  - `trace_call_path`
  - `get_architecture` — languages, packages, hotspots, clusters
- [ ] **Tests:** Call graph accuracy on fixtures, BFS traversal tests

**Atomic commits:**
14. `feat: add cross-file call resolution`
15. `feat: implement trace_call_path with BFS`
16. `feat: add get_architecture tool`

---

### Phase 5: Community Detection + Cypher Queries (Weeks 13–15)
**Goal:** Advanced graph analytics.

- [ ] Implement Leiden community detection
- [ ] Cluster assignment stored as Symbol property
- [ ] Cypher-like query language: `MATCH (s:Symbol)-[:CALLS]->(t:Symbol) WHERE ... RETURN ...`
- [ ] Query planner: use indexes for label/name lookups, BFS for traversals
- [ ] Implement tools:
  - Enhanced `query_graph` with Cypher support
- [ ] **Tests:** Louvain on known graphs, Cypher parser roundtrips, query correctness

**Atomic commits:**
17. `feat: implement Leiden community detection`
18. `feat: add Cypher lexer and parser`
19. `feat: add Cypher query executor`

---

### Phase 6: Advanced BM25 + Remaining Tools (Weeks 16–17)
**Goal:** Search parity and tool completeness.

- [ ] IDF-aware BM25 with document length normalization
- [ ] Query-aware snippet extraction (find first query term, expand context)
- [ ] ADR storage and management (`manage_adr`)
- [ ] HTTP route detection (framework patterns: Express, FastAPI, etc.)
- [ ] Runtime trace ingestion (`ingest_traces`)
- [ ] **Tests:** BM25 ranking benchmarks, ADR CRUD tests

**Atomic commits:**
20. `feat: implement proper BM25 with IDF and length normalization`
21. `feat: add manage_adr and ingest_traces tools`

---

### Phase 7: Scale + Polish (Weeks 18–20)
**Goal:** Production readiness.

- [ ] Expand to 20+ languages (add grammars; extractors are mostly reusable)
- [ ] Performance benchmarks (target: Linux kernel in <5 min, queries <10 ms)
- [ ] Semantic search stub (optional: ONNX runtime integration for embeddings)
- [ ] Binary size optimization (strip unused grammars, LTO)
- [ ] Cross-compile CI matrix validation
- [ ] **Tests:** End-to-end benchmarks, memory usage tests

**Atomic commits:**
22. `feat: add 15 additional tree-sitter grammars`
23. `perf: optimize index size and query latency`
24. `docs: add architecture and usage documentation`

---

## 5. Task Dependency Graph

```
Phase 0 (Foundation)
    ├── SQLite C amalgamation ──┐
    ├── Tree-sitter core C ─────┤
    └── Graph schema ───────────┘
                │
                ▼
Phase 1 (MCP Compliance) ◄──────────────┐
    ├── MCP protocol implementation      │
    ├── Content-Length framing           │
    ├── Graph schema (nodes/edges)       │
    └── 4 core tools                     │
                │                        │
                ▼                        │
Phase 2 (Tree-sitter Pipeline)           │
    ├── 6 grammars                       │
    ├── AST extractors                   │
    ├── Multi-pass pipeline              │
    └── 3 more tools                     │
                │                        │
                ├──► Phase 3 (Incremental) ◄──┐
                │    ├── File watcher          │
                │    ├── Incremental diff      │
                │    └── 3 tools               │
                │                              │
                ├──► Phase 4 (Call Graph)
                │    ├── Cross-file resolution
                │    ├── trace_call_path
                │    └── get_architecture
                │
                └──► Phase 5 (Louvain + Cypher)
                     ├── Community detection
                     ├── Cypher parser
                     └── Query executor
                          │
                          ▼
                    Phase 6 (Advanced Search)
                         ├── IDF BM25
                         ├── Query-aware snippets
                         └── Remaining tools
                              │
                              ▼
                        Phase 7 (Scale + Polish)
                             ├── 20+ languages
                             ├── Benchmarks
                             └── Semantic search (optional)
```

---

## 6. Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| **Tree-sitter C compilation in Zig** | **High** | Start with 3 languages. Use `zig translate-c` incrementally. If blocked, fallback to external `tree-sitter` CLI invocation. |
| **Cypher query engine complexity** | **High** | Implement a **simplified subset** first: `MATCH (n:Label)-[:EDGE]->(m) WHERE n.name = 'x' RETURN m`. Full Cypher is a multi-month project. |
| **Incremental graph consistency** | **High** | Use SQLite transactions. Delete all nodes/edges for a file, then re-insert. Simple but correct. Optimize later. |
| **Cross-platform file watcher** | **Medium** | Use polling fallback for unsupported platforms. Not ideal but functional. |
| **Binary size bloat (60+ grammars)** | **Medium** | Make grammars compile-time optional via build options. Ship "standard" (~15 languages) and "full" (~60) binaries. |
| **Import resolution accuracy** | **Medium** | Language-specific heuristics. Accept ~80% accuracy initially. Improve with LSP-style resolution later. |
| **Call graph false positives** | **Medium** | Name-based resolution is inherently fuzzy. Add confidence scores to CALLS edges (like GitNexus). |
| **MCP client compatibility** | **Low** | Test against Claude Code, Cursor, OpenCode. Content-Length framing is the most common gotcha. |

---

## 7. Immediate Next Steps

1. **Vendor SQLite amalgamation** (`sqlite3.c`, `sqlite3.h`) into `vendor/sqlite3/`
2. **Vendor tree-sitter core** into `vendor/tree-sitter/`
3. **Add SQLite to `build.zig`** as a static library, link to exe
4. **Write first test:** `graph_db` connection and schema creation
5. **Prototype tree-sitter bindings:** Parse one `.zig` file via C API from Zig
6. **Create feature branch:** `mcp-evolution`

---

## 8. TDD Discipline

Every phase bullet marked with `[ ]` must have a corresponding test **before** implementation:

- Write integration test in `tests/` that asserts the desired behavior
- Run test — it should fail
- Implement until test passes
- Commit

Example for Phase 0:
```zig
// tests/graph_db_test.zig
test "graph_db creates schema with Document and Symbol nodes" {
    const db = try GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();
    
    const count = try db.queryScalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table'");
    try std.testing.expect(count > 0);
}
```

---

## 9. MCP Tools Target Matrix

| Tool | Phase | Description |
|---|---|---|
| `index_repository` | 1 | Build/update graph |
| `list_projects` | 1 | List indexed repos |
| `search_code` | 1 | Grep-like text search |
| `get_graph_schema` | 1 | Schema introspection |
| `search_graph` | 2 | Symbol search by label/name/degree |
| `get_code_snippet` | 2 | Source retrieval by qualified name |
| `query_graph` | 2 / 5 | Graph queries (simplified → Cypher) |
| `detect_changes` | 3 | Git diff → affected symbols |
| `index_status` | 3 | Staleness check |
| `delete_project` | 3 | Remove index |
| `trace_call_path` | 4 | BFS call chain traversal |
| `get_architecture` | 4 | Codebase overview |
| `manage_adr` | 6 | Architecture Decision Records |
| `ingest_traces` | 6 | Runtime trace validation |

---

*Plan generated 2026-05-07. Review and adjust scope before starting Phase 0.*
