<!-- BEGIN zindeks-managed -->
## Code-graph tools (zindeks)

This repo is indexed by zindeks. For any code-structure question — symbol lookup,
"who calls X", "where is Y defined", architecture, impact analysis — call the
matching MCP tool below BEFORE falling back to grep or full-file reads.

| Question | Tool |
|---|---|
| Symbol definition | `search_graph(name_pattern)` |
| Callers / callees | `trace_call_path(name, direction)` |
| Source snippet | `get_code_snippet(name)` |
| Keyword search | `search_code(query)` |
| Architecture | `get_architecture()` |
| Custom relation | `query_graph("MATCH ...")` |

First call each session: `index_repository` (auto-detects this project from cwd).
Refresh with `detect_changes` then `index_repository` if drifted.
<!-- END zindeks-managed -->
