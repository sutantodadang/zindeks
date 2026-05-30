<!-- BEGIN zindeks-managed -->
## Zindeks-First Code Search

Use zindeks first for code search and code-structure questions in this repo.

- Keyword search: `zindeks search "<query>"` or MCP `search_code(query)`.
- Symbols: MCP `search_graph(name_pattern)`.
- Callers/callees: MCP `trace_call_path(name, direction)`.
- Architecture and hotspots: MCP `get_architecture()`.

Only fall back to broad shell search (`rg`, `grep`, `git grep`, `findstr`,
`Select-String`, recursive `Get-ChildItem`/`gci`, or `dir /s`) after trying
zindeks, or when searching generated/binary files that zindeks does not index.
If zindeks reports "No project loaded", call `index_repository` with this repo's
absolute path or run `zindeks index .` from the repo root.
<!-- END zindeks-managed -->
