//! Compile-time embedded templates for the install subcommand.
//!
//! All template bytes are baked into the binary at compile time via
//! @embedFile — preserves the "single static binary" guarantee.

/// The CLAUDE.md routing-rules block, including the managed markers.
/// Injected (or replaced) at project scope for the claude-code adapter.
pub const claude_md_block: []const u8 = @embedFile("templates/claude_md_block.md");

/// Generic AGENTS.md routing-rules block, including managed markers.
pub const agent_guidance_block: []const u8 = @embedFile("templates/agent_guidance_block.md");

/// GitHub Copilot / VS Code-compatible routing-rules block.
pub const copilot_guidance_block: []const u8 = @embedFile("templates/copilot_guidance_block.md");

/// Cursor always-apply rule that steers agents to zindeks before shell search.
pub const cursor_rule_mdc: []const u8 = @embedFile("templates/cursor_zindeks_first.mdc");

/// Shared Cursor/Claude hook script for broad shell-search guardrails.
pub const enforce_zindeks_search_js: []const u8 = @embedFile("templates/enforce_zindeks_search.js");

/// Marker strings used to locate and replace the managed block.
pub const begin_marker = "<!-- BEGIN zindeks-managed -->";
pub const end_marker = "<!-- END zindeks-managed -->";
