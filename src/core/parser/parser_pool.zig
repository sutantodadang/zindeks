//! Tree-sitter parser pool — reuse TSParser instances across files.
//!
//! Creating a TSParser + grammar binding per file is expensive (~malloc/free of
//! the opaque TSParser struct plus the grammar state).  This pool maintains a
//! bounded free-list per LanguageId so parsers are re-used across calls.
//!
//! Thread safety: a mutex guards the free-lists so the pool can be shared by
//! multiple concurrent workers.
//!
//! Capacity: at most `max_per_lang` idle parsers are kept per language.  When
//! the free-list is full on release the excess parser is destroyed immediately.
//! When the free-list is empty on acquire a fresh parser is created.

const std = @import("std");
const ts = @import("tree_sitter.zig");

/// Number of distinct language slots — derived from the LanguageId enum.
const LANG_COUNT = @typeInfo(ts.LanguageId).@"enum".fields.len;

pub const ParserPool = struct {
    mutex: std.Thread.Mutex,
    free_lists: [LANG_COUNT]std.ArrayList(ts.Parser),
    allocator: std.mem.Allocator,
    max_per_lang: usize,

    pub fn init(allocator: std.mem.Allocator) ParserPool {
        var pool = ParserPool{
            .mutex = .{},
            .free_lists = undefined,
            .allocator = allocator,
            .max_per_lang = 8,
        };
        for (&pool.free_lists) |*list| {
            list.* = std.ArrayList(ts.Parser){};
        }
        return pool;
    }

    /// Drain and destroy all idle parsers, then release the pool itself.
    pub fn deinit(self: *ParserPool) void {
        for (&self.free_lists) |*list| {
            for (list.items) |*p| p.deinit();
            list.deinit(self.allocator);
        }
    }

    /// Acquire a parser configured for `lang`.
    /// If the free-list is non-empty, a cached parser is returned after reset.
    /// Otherwise a new parser is allocated and its language set.
    pub fn acquire(self: *ParserPool, lang: ts.LanguageId) !ts.Parser {
        const idx = @intFromEnum(lang);
        self.mutex.lock();
        const maybe = blk: {
            if (self.free_lists[idx].items.len > 0) {
                break :blk self.free_lists[idx].pop();
            }
            break :blk null;
        };
        self.mutex.unlock();

        if (maybe) |p| {
            // Reset the parser state so leftover tree data from the previous
            // parse does not interfere with the new source.
            var parser = p;
            parser.reset();
            return parser;
        }

        // No cached parser — create a fresh one.
        const language = ts.languageForId(lang) orelse return error.NoGrammarLinked;
        var parser = ts.Parser.init() catch return error.ParserInitFailed;
        parser.setLanguage(language) catch {
            parser.deinit();
            return error.IncompatibleLanguageVersion;
        };
        return parser;
    }

    /// Return a parser to the pool.
    /// If the free-list is already at capacity the parser is destroyed.
    pub fn release(self: *ParserPool, lang: ts.LanguageId, parser: ts.Parser) void {
        const idx = @intFromEnum(lang);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_lists[idx].items.len < self.max_per_lang) {
            self.free_lists[idx].append(self.allocator, parser) catch {
                // Append failed (OOM) — destroy the parser rather than leak it.
                var p = parser;
                p.deinit();
                return;
            };
        } else {
            var p = parser;
            p.deinit();
        }
    }
};
