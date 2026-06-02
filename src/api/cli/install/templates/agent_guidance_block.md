<!-- BEGIN zindeks-managed -->
## Zindeks-First Code Search

Use zindeks first for code search and code-structure questions in this repo.

- **START HERE — `get_context(query, working_set?)`**: the most powerful entry
  point. One call returns ranked snippets + call-graph neighbors + recalled prior
  reasoning, reranked by code community (cohesion for narrow queries, diversity
  for broad ones) and token-budgeted. Default to it for almost every task; pass
  `working_set` (files you're editing) to bias ranking. Use the narrower tools
  below only for surgical follow-ups.
- Search (hybrid BM25+semantic, default): `zindeks search "<query>"` or MCP `search(query)`.
  - Keyword only: `search(query, mode="keyword")`. Semantic only: `search(query, mode="semantic")`.
- Symbols: MCP `search_graph(name_pattern)`.
- Callers/callees: MCP `trace_call_path(name, direction)`.
- Architecture and hotspots: MCP `get_architecture()`.
- Read a file: MCP `read_file(path, offset, limit)` (numbered, paged — prefer over reading whole files).
- List files: MCP `list_files(pattern, dir)` (use instead of Glob/dir over the indexed repo).
- File outline: MCP `file_outline(path)` (symbols + line ranges, no full content).

Only fall back to broad shell search (`rg`, `grep`, `git grep`, `findstr`,
`Select-String`, recursive `Get-ChildItem`/`gci`, or `dir /s`) after trying
zindeks, or when searching generated/binary files that zindeks does not index.
If zindeks reports "No project loaded", call `index_repository` with this repo's
absolute path or run `zindeks index .` from the repo root.
<!-- END zindeks-managed -->
