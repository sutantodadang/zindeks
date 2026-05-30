<!-- BEGIN zindeks-managed -->
## Code-graph tools (zindeks)

This repo is indexed by zindeks. Use zindeks first for code search and
code-structure questions before falling back to broad shell search or full-file
reads. Prefer `read_file` over reading whole files, and `list_files` over `Glob`
or `dir`.

| Question | Tool |
|---|---|
| Keyword search (any language) | `search_code(query)` |
| Symbol definition | `search_graph(name_pattern)` |
| Callers / callees | `trace_call_path(name, direction)` |
| Source snippet | `get_code_snippet(name)` |
| Read a file (numbered, paged) | `read_file(path, offset, limit)` |
| List files (glob) | `list_files(pattern, dir)` |
| File outline (symbols) | `file_outline(path)` |
| Architecture | `get_architecture()` |
| Custom relation | `query_graph("MATCH ...")` |

`search_code` (BM25) works across 20+ languages. The graph-edge tools
(`search_graph`, `trace_call_path`, `get_architecture`, `query_graph`) need a
language with AST extraction: Zig, Python, JavaScript, TypeScript, TSX, Go,
Rust, Java, C, C++. For other languages, lead with `search_code` — graph
results will be sparse.

First call each session: `index_repository` with an absolute `path` to this
repo. (An already-indexed project also auto-attaches when the server starts, so
read tools may work immediately — but if any tool returns "No project loaded",
call `index_repository` with the path.) Refresh with `detect_changes`, then
`index_repository` again if it reports drift.

Avoid broad shell search (`rg`, `grep`, `git grep`, `findstr`, `Select-String`,
recursive `Get-ChildItem`/`gci`, or `dir /s`) until zindeks has been tried,
unless the target is generated/binary content or outside the zindeks index.
<!-- END zindeks-managed -->
