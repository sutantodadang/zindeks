# Zindeks — Host Integrations

This document describes the six AI host adapters supported by `zindeks install`.

## Supported hosts

| ID | Display name | User config path | Project config path | Project scope |
|---|---|---|---|---|
| `claude-code` | Claude Code | `~/.claude/settings.json` (Linux/macOS)<br>`%USERPROFILE%\.claude\settings.json` (Windows) | `<cwd>/.claude/settings.json` + `<cwd>/CLAUDE.md` block | Yes |
| `cursor` | Cursor | `~/.cursor/mcp.json` | `<cwd>/.cursor/mcp.json` | Yes |
| `vscode` | VS Code | `%APPDATA%\Code\User\mcp.json` (Windows)<br>`~/Library/Application Support/Code/User/mcp.json` (macOS)<br>`~/.config/Code/User/mcp.json` (Linux) | `<cwd>/.vscode/mcp.json` | Yes |
| `windsurf` | Windsurf | `~/.codeium/windsurf/mcp_config.json` | n/a | No |
| `antigravity` | Antigravity | `~/.antigravity/mcp.json`<br>(fallback: `~/.config/antigravity/mcp.json` on Linux/macOS) | `<cwd>/.antigravity/mcp.json` | Yes |
| `kiro` | Kiro | `~/.kiro/settings/mcp.json` | `<cwd>/.kiro/settings/mcp.json` | Yes |

## MCP entry shape

Every host receives the same entry:

```json
{
  "mcpServers": {
    "zindeks": {
      "command": "<absolute-path-to-zindeks-binary>",
      "args": ["serve"]
    }
  }
}
```

The binary path is resolved at install time via `std.fs.selfExePath` so the entry works even if zindeks is not on PATH. Path separators are normalized to forward slashes for cross-platform JSON compatibility.

## CLAUDE.md block (claude-code, project scope)

When `--scope project` or `--scope both` is used with the `claude-code` adapter, a routing-rules block is injected into `<cwd>/CLAUDE.md` between managed markers:

```
<!-- BEGIN zindeks-managed -->
...
<!-- END zindeks-managed -->
```

Re-running `install` replaces the block in-place (idempotent). Running `uninstall` removes only this block.

## Project search guardrails

Search-enforcement guardrails are **project-local files written to the current repo**,
and `install` writes them for the selected hosts **regardless of `--scope`** (the scope
flag only controls where the `mcpServers` entry is registered). So `install --yes` from
a repo enforces zindeks-first search there even at the default user scope.

Installs add zindeks-first search guidance without replacing unrelated user content:

- `AGENTS.md`: appends or replaces a managed zindeks-first block for generic agents.
- Cursor: writes `.cursor/rules/zindeks-first.mdc`, `.cursor/hooks.json`, and `.cursor/hooks/enforce-zindeks-search.js`.
- VS Code / GitHub Copilot: appends or replaces a managed block in `.github/copilot-instructions.md`.
- Claude Code: adds a project `.claude/settings.json` `PreToolUse` hook for Bash/Shell commands and reuses `.cursor/hooks/enforce-zindeks-search.js`.
- Kiro: writes `.kiro/hooks/enforce-zindeks-search.js` and injects a `preToolUse` hook (`matcher: "shell"`) into each workspace agent config (`.kiro/agents/*.json`). Kiro hooks are per-agent and exit-code based (exit 0 allows, exit 2 blocks and returns the guidance to the model), so broad shell search is blocked with a nudge rather than prompted. Re-run after adding new agents.

The shared hook script steers agents to zindeks for broad shell search commands (`rg`, `grep`, `git grep`, `findstr`, `Select-String`, recursive `Get-ChildItem`/`gci`, or `dir /s`) unless the command invokes zindeks: Cursor is prompted (`ask`), Claude gets a non-blocking advisory, and Kiro is blocked (exit 2) with guidance. It is plain Node.js and does not require jq or bash.

## Commands

```bash
# Install — interactive
zindeks install

# Install — non-interactive, specific host and scope
zindeks install --host claude-code --scope both --yes

# Install — multiple hosts
zindeks install --host claude-code,cursor,vscode --scope user --yes

# Install — dry-run (print what would be written)
zindeks install --host claude-code --scope both --dry-run

# List detected hosts
zindeks install --list-hosts

# Always-on background server (OS supervisor running `serve --http`); implies HTTP
zindeks install --http 7337 --service --yes
zindeks install --uninstall-service

# Verify installation
zindeks doctor

# Remove zindeks from all hosts (user scope)
zindeks uninstall --scope user

# Remove from specific host, both scopes
zindeks uninstall --host claude-code --scope both
```

## Notes

- **JSONC files**: If a host config file contains `//` or `/*` comments (VS Code-style JSONC), `install` skips that file and tells you to merge the entry manually. Use `--dry-run` to see the exact JSON snippet to add.
- **Idempotency**: Re-running `install` overwrites only the `zindeks` key inside `mcpServers`. All other keys are preserved.
- **Uninstall**: Only the `zindeks` key is removed. If `mcpServers` becomes empty it stays as `{}` — no other restructuring.
- **Atomic writes**: All file writes use a tmpfile + rename approach to prevent partial writes.
