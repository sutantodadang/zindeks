//! Compile-time embedded templates for the install subcommand.
//!
//! All template bytes are baked into the binary at compile time via
//! @embedFile — preserves the "single static binary" guarantee.

/// The CLAUDE.md routing-rules block, including the managed markers.
/// Injected (or replaced) at project scope for the claude-code adapter.
pub const claude_md_block: []const u8 = @embedFile("templates/claude_md_block.md");

/// Marker strings used to locate and replace the managed block.
pub const begin_marker = "<!-- BEGIN zindeks-managed -->";
pub const end_marker = "<!-- END zindeks-managed -->";
