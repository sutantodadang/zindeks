<!-- BEGIN zindeks-managed -->
## Zindeks-First Code Search

For this repository, use zindeks before broad shell search.

- Start with `zindeks search "<query>"` or the zindeks MCP `search_code` tool.
- Use zindeks graph tools for symbols, callers, callees, dependencies, and
  architecture before reading many files manually.
- Read files with `read_file(path, offset, limit)` and list them with
  `list_files(pattern, dir)` (zindeks MCP) instead of Glob/dir and whole-file reads.
- Avoid `rg`, `grep`, `git grep`, `findstr`, `Select-String`, recursive
  `Get-ChildItem`/`gci`, and `dir /s` until zindeks has been tried.

If the index is missing or stale, run `zindeks index .` from the repo root.
<!-- END zindeks-managed -->
