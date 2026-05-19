const std = @import("std");
const builtin = @import("builtin");
const tokenizer_mod = @import("../search/tokenizer.zig");

pub const MAGIC_META: u32 = 0x5a49444d;
pub const MAGIC_CONTENT: u32 = 0x5a494443;
pub const MAGIC_SYMBOL: u32 = 0x5a494453;
pub const MAGIC_POSTING: u32 = 0x5a494450;
pub const MAGIC_GRAPH: u32 = 0x5a494447;
pub const VERSION: u32 = 1;

pub const FileKind = enum { meta, content, symbol, posting, graph };

pub const SymbolKind = enum(u8) {
    function = 1,
    struct_type = 2,
    const_value = 3,
    variable = 4,
    module = 5,
    unknown = 255,
};

pub const Header = packed struct {
    magic: u32,
    version: u32,
    header_len: u32,
    record_count: u32,
    section1_off: u64,
    section1_len: u64,
    section2_off: u64,
    section2_len: u64,
    string_table_off: u64,
    string_table_len: u64,
};

pub const DocRecord = packed struct {
    path_sid: u32,
    content_off: u64,
    content_len: u32,
    hash: u64,
    mtime: i64,
    symbol_off: u32,
    symbol_len: u32,
    import_off: u32,
    import_len: u32,
    token_count: u32,
};

pub const SymbolRecord = packed struct {
    doc_id: u32,
    name_sid: u32,
    kind: u8,
    line: u32,
    byte_off: u32,
};

pub const SymbolHashRecord = packed struct {
    hash: u64,
    symbol_index: u32,
};

pub const TermRecord = packed struct {
    term_sid: u32,
    postings_off: u32,
    postings_len: u32,
};

pub const PostingRecord = packed struct {
    doc_id: u32,
    tf: u16,
    first_pos: u32,
};

pub const ImportRecord = packed struct {
    doc_id: u32,
    target_sid: u32,
};

/// Combined term lookup result — postings slice plus document frequency.
pub const TermLookup = struct {
    df: u32,
    postings: []const PostingRecord,
};

const MutableDoc = struct {
    rec: DocRecord,
};

const TokenEntry = struct {
    term_sid: u32,
    doc_id: u32,
    tf: u16,
    first_pos: u32,
};

const TokenAccum = struct {
    tf: u16,
    first_pos: u32,
};

pub const Writer = struct {
    /// Owns all of the Writer's transient allocations (string table, doc /
    /// symbol / token arraylists, hashmap backing storage).  Held by pointer
    /// so the `Allocator` interface (which captures a `*ArenaAllocator`) stays
    /// valid when the Writer is returned by value from `init`.
    ///
    /// The arena is bulk-freed in `deinit`, eliminating per-list teardown and
    /// removing a latent stale-pointer hazard: `string_ids` stores keys that
    /// slice into `strings.items`, and arena `realloc` keeps prior buffers
    /// alive so old keys remain valid even after `strings` grows.
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    index_path: []const u8,
    strings: std.ArrayList(u8),
    string_offsets: std.ArrayList(u32),
    string_ids: std.HashMapUnmanaged([]const u8, u32, InternContext, std.hash_map.default_max_load_percentage),
    docs: std.ArrayList(MutableDoc),
    content_file: std.fs.File,
    content_len: u64,
    symbols: std.ArrayList(SymbolRecord),
    imports: std.ArrayList(ImportRecord),
    tokens: std.ArrayList(TokenEntry),

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, index_path: []const u8) !Writer {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_ptr.deinit();
        const arena_alloc = arena_ptr.allocator();

        var content_file = try createIndexFile(arena_alloc, dir, index_path, "content.idx");
        errdefer content_file.close();
        const empty_header = Header{
            .magic = MAGIC_CONTENT,
            .version = VERSION,
            .header_len = @sizeOf(Header),
            .record_count = 0,
            .section1_off = @sizeOf(Header),
            .section1_len = 0,
            .section2_off = @sizeOf(Header),
            .section2_len = 0,
            .string_table_off = @sizeOf(Header),
            .string_table_len = 0,
        };
        try content_file.writeAll(std.mem.asBytes(&empty_header));

        return .{
            .parent_allocator = allocator,
            .arena = arena_ptr,
            .allocator = arena_alloc,
            .dir = dir,
            .index_path = try arena_alloc.dupe(u8, index_path),
            .strings = .{},
            .string_offsets = .{},
            .string_ids = .{},
            .docs = .{},
            .content_file = content_file,
            .content_len = 0,
            .symbols = .{},
            .imports = .{},
            .tokens = .{},
        };
    }

    pub fn deinit(self: *Writer) void {
        self.content_file.close();
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
    }

    /// State for an in-progress streaming file ingest.  Owned by the caller;
    /// passed back into `appendStreamChunk` / `endStreamFile`.
    pub const StreamHandle = struct {
        doc_id: u32,
        hasher: std.hash.Wyhash,
        per_doc_arena: std.heap.ArenaAllocator,
        per_doc: std.AutoHashMap(u32, TokenAccum),
        /// Carry-over for an identifier that started near the end of the
        /// previous chunk and may continue into the next one.  Capped at
        /// 256 bytes — same as `normalizeInto`'s working buffer.
        pending: [256]u8,
        pending_len: usize,
        bytes_written: u64,
        /// Token-position counter (increments per identifier seen).
        pos: u32,
    };

    /// Begin a streaming file ingest.  Reserves a doc record now; the hash
    /// and content_len are filled in by `endStreamFile` once all chunks
    /// have been consumed.
    pub fn beginStreamFile(self: *Writer, path: []const u8, mtime: i64) !StreamHandle {
        const doc_id: u32 = @intCast(self.docs.items.len);
        const path_sid = try self.intern(path);
        const content_off = self.content_len;
        try self.docs.append(self.allocator, .{ .rec = .{
            .path_sid = path_sid,
            .content_off = content_off,
            .content_len = 0,
            .hash = 0,
            .mtime = mtime,
            .symbol_off = 0,
            .symbol_len = 0,
            .import_off = 0,
            .import_len = 0,
            .token_count = 0,
        } });
        var per_doc_arena = std.heap.ArenaAllocator.init(self.parent_allocator);
        errdefer per_doc_arena.deinit();
        const per_doc = std.AutoHashMap(u32, TokenAccum).init(per_doc_arena.allocator());
        return .{
            .doc_id = doc_id,
            .hasher = std.hash.Wyhash.init(0),
            .per_doc_arena = per_doc_arena,
            .per_doc = per_doc,
            .pending = undefined,
            .pending_len = 0,
            .bytes_written = 0,
            .pos = 0,
        };
    }

    /// Append a content chunk to a streaming file.  Updates the running
    /// hash, appends to `content.idx`, and tokenizes the chunk with
    /// carry-over handling so identifiers that straddle chunk boundaries
    /// are still indexed as a single token.
    pub fn appendStreamChunk(self: *Writer, handle: *StreamHandle, chunk: []const u8) !void {
        handle.hasher.update(chunk);
        try self.content_file.writeAll(chunk);
        self.content_len += chunk.len;
        handle.bytes_written += chunk.len;

        var i: usize = 0;
        while (i < chunk.len) {
            const c = chunk[i];
            const is_ident_char = isIdent(c);

            // Extend a carried-over identifier from the previous chunk.
            if (handle.pending_len > 0) {
                if (is_ident_char) {
                    if (handle.pending_len < handle.pending.len) {
                        handle.pending[handle.pending_len] = c;
                        handle.pending_len += 1;
                    }
                    i += 1;
                    continue;
                }
                try self.indexIdentifierIntoMap(handle.doc_id, &handle.per_doc, handle.pending[0..handle.pending_len], handle.pos);
                handle.pos += 1;
                handle.pending_len = 0;
                // Fall through; the non-ident byte is skipped below.
            }

            if (!is_ident_char) {
                i += 1;
                continue;
            }

            const start = i;
            while (i < chunk.len and isIdent(chunk[i])) i += 1;
            const ident = chunk[start..i];
            if (i == chunk.len) {
                const copy_len = @min(ident.len, handle.pending.len);
                @memcpy(handle.pending[0..copy_len], ident[0..copy_len]);
                handle.pending_len = copy_len;
                return;
            }
            try self.indexIdentifierIntoMap(handle.doc_id, &handle.per_doc, ident, handle.pos);
            handle.pos += 1;
        }
    }

    /// Finish a streaming file ingest.  Flushes any pending identifier,
    /// drains the per-doc token accumulator into the shared `tokens` list,
    /// and patches the doc record with the final hash + content_len.
    pub fn endStreamFile(self: *Writer, handle: *StreamHandle) !void {
        if (handle.pending_len > 0) {
            try self.indexIdentifierIntoMap(handle.doc_id, &handle.per_doc, handle.pending[0..handle.pending_len], handle.pos);
            handle.pending_len = 0;
        }

        var it = handle.per_doc.iterator();
        while (it.next()) |entry| {
            try self.tokens.append(self.allocator, .{
                .term_sid = entry.key_ptr.*,
                .doc_id = handle.doc_id,
                .tf = entry.value_ptr.tf,
                .first_pos = entry.value_ptr.first_pos,
            });
        }

        const doc = &self.docs.items[handle.doc_id].rec;
        doc.content_len = @intCast(handle.bytes_written);
        doc.hash = handle.hasher.final();

        handle.per_doc.deinit();
        handle.per_doc_arena.deinit();
    }

    pub fn addFile(self: *Writer, path: []const u8, hash: u64, mtime: i64, content: []const u8) !u32 {
        const doc_id: u32 = @intCast(self.docs.items.len);
        const path_sid = try self.intern(path);
        const content_off = self.content_len;
        try self.content_file.writeAll(content);
        self.content_len += content.len;
        try self.docs.append(self.allocator, .{ .rec = .{
            .path_sid = path_sid,
            .content_off = content_off,
            .content_len = @intCast(content.len),
            .hash = hash,
            .mtime = mtime,
            .symbol_off = 0,
            .symbol_len = 0,
            .import_off = 0,
            .import_len = 0,
            .token_count = 0,
        } });
        try self.indexContentTokens(doc_id, content);
        return doc_id;
    }

    pub fn addSymbol(self: *Writer, doc_id: u32, name: []const u8, kind: SymbolKind, line: u32, byte_off: u32) !void {
        const rec = SymbolRecord{
            .doc_id = doc_id,
            .name_sid = try self.intern(name),
            .kind = @intFromEnum(kind),
            .line = line,
            .byte_off = byte_off,
        };
        try self.symbols.append(self.allocator, rec);
        try self.indexIdentifier(doc_id, name, 0);
    }

    pub fn addImport(self: *Writer, doc_id: u32, target: []const u8) !void {
        try self.imports.append(self.allocator, .{
            .doc_id = doc_id,
            .target_sid = try self.intern(target),
        });
    }

    pub fn finish(self: *Writer) !void {
        self.attachRanges();
        std.mem.sort(SymbolRecord, self.symbols.items, {}, lessSymbol);
        std.mem.sort(ImportRecord, self.imports.items, {}, lessImport);
        self.attachRanges();
        std.mem.sort(TokenEntry, self.tokens.items, self, lessTokenByText);

        try self.finalizeContent();
        try self.writeMeta();
        try self.writeSymbols();
        try self.writePostings();
        try self.writeGraph();
    }

    fn attachRanges(self: *Writer) void {
        for (self.docs.items) |*doc| {
            doc.rec.symbol_off = 0;
            doc.rec.symbol_len = 0;
            doc.rec.import_off = 0;
            doc.rec.import_len = 0;
        }
        for (self.symbols.items, 0..) |sym, i| {
            var doc = &self.docs.items[sym.doc_id].rec;
            if (doc.symbol_len == 0) doc.symbol_off = @intCast(i);
            doc.symbol_len += 1;
        }
        for (self.imports.items, 0..) |imp, i| {
            var doc = &self.docs.items[imp.doc_id].rec;
            if (doc.import_len == 0) doc.import_off = @intCast(i);
            doc.import_len += 1;
        }
    }

    fn intern(self: *Writer, value: []const u8) !u32 {
        if (self.string_ids.get(value)) |sid| return sid;
        const sid: u32 = @intCast(self.string_offsets.items.len);
        const off = self.strings.items.len;
        try self.string_offsets.append(self.allocator, @intCast(off));
        try self.strings.appendSlice(self.allocator, value);
        try self.strings.append(self.allocator, 0);
        const key = self.strings.items[off .. off + value.len];
        try self.string_ids.put(self.allocator, key, sid);
        return sid;
    }

const InternContext = struct {
    pub fn hash(_: @This(), value: []const u8) u64 {
        return std.hash.Wyhash.hash(0, value);
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

    fn indexContentTokens(self: *Writer, doc_id: u32, content: []const u8) !void {
        var per_doc = std.AutoHashMap(u32, TokenAccum).init(self.allocator);
        defer per_doc.deinit();

        var i: usize = 0;
        var pos: u32 = 0;
        while (i < content.len) {
            if (!isIdent(content[i])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < content.len and isIdent(content[i])) i += 1;
            try self.indexIdentifierIntoMap(doc_id, &per_doc, content[start..i], pos);
            pos += 1;
        }

        var it = per_doc.iterator();
        while (it.next()) |entry| {
            try self.tokens.append(self.allocator, .{
                .term_sid = entry.key_ptr.*,
                .doc_id = doc_id,
                .tf = entry.value_ptr.tf,
                .first_pos = entry.value_ptr.first_pos,
            });
        }
    }

    fn indexIdentifier(self: *Writer, doc_id: u32, ident: []const u8, pos: u32) !void {
        var normalized_buf: [256]u8 = undefined;
        const normalized = normalizeInto(&normalized_buf, ident);
        if (normalized.len > 0) try self.addToken(doc_id, normalized, pos);

        // Use tokenizer module for camelCase + snake_case splitting
        var splits: [tokenizer_mod.MAX_SPLITS][]const u8 = undefined;
        const n = tokenizer_mod.splitIdentifier(ident, &splits);
        for (splits[0..n]) |sub| {
            var sub_buf: [256]u8 = undefined;
            const sub_norm = normalizeInto(&sub_buf, sub);
            if (sub_norm.len > 0 and !std.mem.eql(u8, sub_norm, normalized)) {
                try self.addToken(doc_id, sub_norm, pos);
            }
        }
    }

    fn indexIdentifierIntoMap(self: *Writer, doc_id: u32, tokens_for_doc: *std.AutoHashMap(u32, TokenAccum), ident: []const u8, pos: u32) !void {
        var normalized_buf: [256]u8 = undefined;
        const normalized = normalizeInto(&normalized_buf, ident);
        if (normalized.len > 0) try self.addTokenToMap(doc_id, tokens_for_doc, normalized, pos);

        // Use tokenizer module for camelCase + snake_case splitting
        var splits: [tokenizer_mod.MAX_SPLITS][]const u8 = undefined;
        const n = tokenizer_mod.splitIdentifier(ident, &splits);
        for (splits[0..n]) |sub| {
            var sub_buf: [256]u8 = undefined;
            const sub_norm = normalizeInto(&sub_buf, sub);
            if (sub_norm.len > 0 and !std.mem.eql(u8, sub_norm, normalized)) {
                try self.addTokenToMap(doc_id, tokens_for_doc, sub_norm, pos);
            }
        }
    }

    fn addToken(self: *Writer, doc_id: u32, term: []const u8, pos: u32) !void {
        if (term.len == 0) return;
        const sid = try self.intern(term);
        try self.tokens.append(self.allocator, .{ .term_sid = sid, .doc_id = doc_id, .tf = 1, .first_pos = pos });
        self.docs.items[doc_id].rec.token_count += 1;
    }

    fn addTokenToMap(self: *Writer, doc_id: u32, tokens_for_doc: *std.AutoHashMap(u32, TokenAccum), term: []const u8, pos: u32) !void {
        if (term.len == 0) return;
        const sid = try self.intern(term);
        const entry = try tokens_for_doc.getOrPut(sid);
        if (entry.found_existing) {
            if (entry.value_ptr.tf < std.math.maxInt(u16)) entry.value_ptr.tf += 1;
            entry.value_ptr.first_pos = @min(entry.value_ptr.first_pos, pos);
        } else {
            entry.value_ptr.* = .{ .tf = 1, .first_pos = pos };
        }
        self.docs.items[doc_id].rec.token_count += 1;
    }

    fn writeMeta(self: *Writer) !void {
        const docs_bytes = std.mem.sliceAsBytes(self.docRecords());
        const offsets_bytes = std.mem.sliceAsBytes(self.string_offsets.items);
        try self.writeFile("meta.idx", MAGIC_META, @intCast(self.docs.items.len), docs_bytes, offsets_bytes, self.strings.items);
    }

    fn finalizeContent(self: *Writer) !void {
        const h = Header{
            .magic = MAGIC_CONTENT,
            .version = VERSION,
            .header_len = @sizeOf(Header),
            .record_count = @intCast(self.docs.items.len),
            .section1_off = @sizeOf(Header),
            .section1_len = self.content_len,
            .section2_off = @sizeOf(Header) + self.content_len,
            .section2_len = 0,
            .string_table_off = @sizeOf(Header) + self.content_len,
            .string_table_len = 0,
        };
        try self.content_file.seekTo(0);
        try self.content_file.writeAll(std.mem.asBytes(&h));
    }

    fn writeSymbols(self: *Writer) !void {
        var hashes: std.ArrayList(SymbolHashRecord) = .{};
        defer hashes.deinit(self.allocator);
        for (self.symbols.items, 0..) |sym, i| {
            try hashes.append(self.allocator, .{ .hash = stableHash(self.stringFromSid(sym.name_sid)), .symbol_index = @intCast(i) });
        }
        std.mem.sort(SymbolHashRecord, hashes.items, {}, lessSymbolHash);
        try self.writeFile(
            "symbol.idx",
            MAGIC_SYMBOL,
            @intCast(self.symbols.items.len),
            std.mem.sliceAsBytes(self.symbols.items),
            std.mem.sliceAsBytes(hashes.items),
            &.{},
        );
    }

    fn writePostings(self: *Writer) !void {
        var terms: std.ArrayList(TermRecord) = .{};
        defer terms.deinit(self.allocator);
        var postings: std.ArrayList(PostingRecord) = .{};
        defer postings.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.tokens.items.len) {
            const sid = self.tokens.items[i].term_sid;
            const postings_start: u32 = @intCast(postings.items.len);
            while (i < self.tokens.items.len and self.tokens.items[i].term_sid == sid) {
                const doc = self.tokens.items[i].doc_id;
                var tf: u16 = 0;
                var first = self.tokens.items[i].first_pos;
                while (i < self.tokens.items.len and self.tokens.items[i].term_sid == sid and self.tokens.items[i].doc_id == doc) : (i += 1) {
                    if (tf < std.math.maxInt(u16)) tf += 1;
                    first = @min(first, self.tokens.items[i].first_pos);
                }
                try postings.append(self.allocator, .{ .doc_id = doc, .tf = tf, .first_pos = first });
            }
            try terms.append(self.allocator, .{
                .term_sid = sid,
                .postings_off = postings_start,
                .postings_len = @intCast(postings.items.len - postings_start),
            });
        }
        try self.writeFile(
            "posting.idx",
            MAGIC_POSTING,
            @intCast(terms.items.len),
            std.mem.sliceAsBytes(terms.items),
            std.mem.sliceAsBytes(postings.items),
            &.{},
        );
    }

    fn writeGraph(self: *Writer) !void {
        try self.writeFile(
            "graph.idx",
            MAGIC_GRAPH,
            @intCast(self.imports.items.len),
            std.mem.sliceAsBytes(self.imports.items),
            &.{},
            &.{},
        );
    }

    fn writeFile(self: *Writer, name: []const u8, magic: u32, count: u32, first_section: []const u8, second_section: []const u8, strings: []const u8) !void {
        var file = try createIndexFile(self.allocator, self.dir, self.index_path, name);
        defer file.close();

        const h = Header{
            .magic = magic,
            .version = VERSION,
            .header_len = @sizeOf(Header),
            .record_count = count,
            .section1_off = @sizeOf(Header),
            .section1_len = first_section.len,
            .section2_off = @sizeOf(Header) + first_section.len,
            .section2_len = second_section.len,
            .string_table_off = @sizeOf(Header) + first_section.len + second_section.len,
            .string_table_len = strings.len,
        };
        try file.writeAll(std.mem.asBytes(&h));
        try file.writeAll(first_section);
        try file.writeAll(second_section);
        try file.writeAll(strings);
    }

    fn docRecords(self: *Writer) []DocRecord {
        return @ptrCast(self.docs.items);
    }

    fn stringFromSid(self: *Writer, sid: u32) []const u8 {
        const off = self.string_offsets.items[sid];
        return std.mem.sliceTo(self.strings.items[off..], 0);
    }
};

fn createIndexFile(allocator: std.mem.Allocator, dir: std.fs.Dir, index_path: []const u8, name: []const u8) !std.fs.File {
    const rel = try std.fs.path.join(allocator, &.{ index_path, name });
    defer allocator.free(rel);
    if (std.fs.path.isAbsolute(rel)) return std.fs.createFileAbsolute(rel, .{ .truncate = true });
    return dir.createFile(rel, .{ .truncate = true });
}

pub const Index = struct {
    allocator: std.mem.Allocator,
    meta: MappedFile,
    content: MappedFile,
    symbol: MappedFile,
    posting: MappedFile,
    graph: MappedFile,
    meta_header: Header,
    content_header: Header,
    symbol_header: Header,
    posting_header: Header,
    graph_header: Header,
    docs: []const DocRecord,
    string_offsets: []const u32,
    strings: []const u8,
    contents: []const u8,
    symbols: []const SymbolRecord,
    symbol_hashes: []const SymbolHashRecord,
    terms: []const TermRecord,
    postings: []const PostingRecord,
    imports: []const ImportRecord,

    pub fn open(allocator: std.mem.Allocator, dir: std.fs.Dir, index_path: []const u8) !Index {
        var meta = try MappedFile.open(allocator, dir, index_path, "meta.idx");
        errdefer meta.close();
        var content = try MappedFile.open(allocator, dir, index_path, "content.idx");
        errdefer content.close();
        var symbol = try MappedFile.open(allocator, dir, index_path, "symbol.idx");
        errdefer symbol.close();
        var posting = try MappedFile.open(allocator, dir, index_path, "posting.idx");
        errdefer posting.close();
        var graph = try MappedFile.open(allocator, dir, index_path, "graph.idx");
        errdefer graph.close();

        const mh = try readHeader(meta.bytes, MAGIC_META);
        const ch = try readHeader(content.bytes, MAGIC_CONTENT);
        const sh = try readHeader(symbol.bytes, MAGIC_SYMBOL);
        const ph = try readHeader(posting.bytes, MAGIC_POSTING);
        const gh = try readHeader(graph.bytes, MAGIC_GRAPH);

        return .{
            .allocator = allocator,
            .meta = meta,
            .content = content,
            .symbol = symbol,
            .posting = posting,
            .graph = graph,
            .meta_header = mh,
            .content_header = ch,
            .symbol_header = sh,
            .posting_header = ph,
            .graph_header = gh,
            .docs = bytesAsSlice(DocRecord, section1(meta.bytes, mh)),
            .string_offsets = bytesAsSlice(u32, section2(meta.bytes, mh)),
            .strings = stringSection(meta.bytes, mh),
            .contents = section1(content.bytes, ch),
            .symbols = bytesAsSlice(SymbolRecord, section1(symbol.bytes, sh)),
            .symbol_hashes = bytesAsSlice(SymbolHashRecord, section2(symbol.bytes, sh)),
            .terms = bytesAsSlice(TermRecord, section1(posting.bytes, ph)),
            .postings = bytesAsSlice(PostingRecord, section2(posting.bytes, ph)),
            .imports = bytesAsSlice(ImportRecord, section1(graph.bytes, gh)),
        };
    }

    pub fn close(self: *Index) void {
        self.meta.close();
        self.content.close();
        self.symbol.close();
        self.posting.close();
        self.graph.close();
    }

    pub fn docCount(self: *const Index) u32 {
        return @intCast(self.docs.len);
    }

    pub fn filePath(self: *const Index, doc_id: u32) []const u8 {
        return self.stringAt(self.docs[doc_id].path_sid);
    }

    pub fn fileContent(self: *const Index, doc_id: u32) []const u8 {
        const doc = self.docs[doc_id];
        const start: usize = @intCast(doc.content_off);
        return self.contents[start .. start + doc.content_len];
    }

    pub fn symbolsForDoc(self: *const Index, doc_id: u32) []const SymbolRecord {
        const doc = self.docs[doc_id];
        return self.symbols[doc.symbol_off .. doc.symbol_off + doc.symbol_len];
    }

    pub fn importsForDoc(self: *const Index, doc_id: u32) []const ImportRecord {
        const doc = self.docs[doc_id];
        return self.imports[doc.import_off .. doc.import_off + doc.import_len];
    }

    pub fn stringAt(self: *const Index, sid: u32) []const u8 {
        const off = self.string_offsets[sid];
        return std.mem.sliceTo(self.strings[off..], 0);
    }

    /// Returns the document frequency (df) for a term — how many documents
    /// contain this term. Used for IDF calculation in BM25.
    pub fn postingsLenForTerm(self: *const Index, term: []const u8) u32 {
        var buf: [256]u8 = undefined;
        const normalized = normalizeInto(&buf, term);
        var lo: usize = 0;
        var hi: usize = self.terms.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const current = self.stringAt(self.terms[mid].term_sid);
            const order = std.mem.order(u8, current, normalized);
            switch (order) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.terms[mid].postings_len,
            }
        }
        return 0;
    }

    /// Calculate average document length in tokens across all indexed documents.
    pub fn avgDocLength(self: *const Index) f32 {
        if (self.docs.len == 0) return 1.0;
        var total: u64 = 0;
        for (self.docs) |doc| {
            total += doc.token_count;
        }
        const avg = @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(self.docs.len));
        return if (avg > 0) avg else 1.0;
    }

    pub fn postingsForTerm(self: *const Index, term: []const u8) []const PostingRecord {
        var buf: [256]u8 = undefined;
        const normalized = normalizeInto(&buf, term);
        var lo: usize = 0;
        var hi: usize = self.terms.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const current = self.stringAt(self.terms[mid].term_sid);
            const order = std.mem.order(u8, current, normalized);
            switch (order) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.postings[self.terms[mid].postings_off .. self.terms[mid].postings_off + self.terms[mid].postings_len],
            }
        }
        return &.{};
    }

    /// Combined lookup: returns both df (postings_len) and the postings slice
    /// in a single binary search.  Use when both values are needed (BM25 needs
    /// df for IDF and postings for per-doc TF).
    pub fn lookupTerm(self: *const Index, normalized: []const u8) ?TermLookup {
        var lo: usize = 0;
        var hi: usize = self.terms.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const current = self.stringAt(self.terms[mid].term_sid);
            const order = std.mem.order(u8, current, normalized);
            switch (order) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    const t = self.terms[mid];
                    return .{
                        .df = t.postings_len,
                        .postings = self.postings[t.postings_off .. t.postings_off + t.postings_len],
                    };
                },
            }
        }
        return null;
    }

    pub fn symbolByName(self: *const Index, name: []const u8) ?SymbolRecord {
        const h = stableHash(name);
        var lo: usize = 0;
        var hi: usize = self.symbol_hashes.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const entry = self.symbol_hashes[mid];
            if (entry.hash < h) {
                lo = mid + 1;
            } else if (entry.hash > h) {
                hi = mid;
            } else {
                var i = mid;
                while (i > 0 and self.symbol_hashes[i - 1].hash == h) i -= 1;
                while (i < self.symbol_hashes.len and self.symbol_hashes[i].hash == h) : (i += 1) {
                    const sym = self.symbols[self.symbol_hashes[i].symbol_index];
                    if (std.mem.eql(u8, self.stringAt(sym.name_sid), name)) return sym;
                }
                return null;
            }
        }
        return null;
    }
};

pub const MappedFile = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    mode: Mode,

    const Mode = enum { allocated, posix_mmap, windows_mmap };

    pub fn open(allocator: std.mem.Allocator, dir: std.fs.Dir, index_path: []const u8, name: []const u8) !MappedFile {
        const rel = try std.fs.path.join(allocator, &.{ index_path, name });
        defer allocator.free(rel);
        var file = if (std.fs.path.isAbsolute(rel))
            try std.fs.openFileAbsolute(rel, .{})
        else
            try dir.openFile(rel, .{});
        defer file.close();
        const size_u64 = try file.getEndPos();
        const size = std.math.cast(usize, size_u64) orelse return error.FileTooBig;
        if (size == 0) return .{ .allocator = allocator, .bytes = &.{}, .mode = .allocated };

        if (builtin.os.tag == .windows) {
            return openWindows(allocator, file, size);
        }

        return openPosix(allocator, file, size) catch {
            try file.seekTo(0);
            const bytes = try file.readToEndAlloc(allocator, 1 << 34);
            return .{ .allocator = allocator, .bytes = bytes, .mode = .allocated };
        };
    }

    pub fn close(self: *MappedFile) void {
        switch (self.mode) {
            .allocated => self.allocator.free(self.bytes),
            .posix_mmap => {
                if (builtin.os.tag == .windows) unreachable;
                std.posix.munmap(@alignCast(self.bytes));
            },
            .windows_mmap => {
                if (builtin.os.tag != .windows) unreachable;
                const windows = std.os.windows;
                _ = windows.ntdll.NtUnmapViewOfSection(windows.GetCurrentProcess(), @ptrCast(self.bytes.ptr));
            },
        }
    }

    fn openPosix(allocator: std.mem.Allocator, file: std.fs.File, size: usize) !MappedFile {
        const page_size = std.heap.pageSize();
        const mapped = try std.posix.mmap(
            null,
            std.mem.alignForward(usize, size, page_size),
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        return .{ .allocator = allocator, .bytes = mapped, .mode = .posix_mmap };
    }

    fn openWindows(allocator: std.mem.Allocator, file: std.fs.File, size: usize) !MappedFile {
        const windows = std.os.windows;
        var section: windows.HANDLE = undefined;
        const create_status = windows.ntdll.NtCreateSection(
            &section,
            windows.SECTION_MAP_READ,
            null,
            null,
            windows.PAGE_READONLY,
            windows.SEC_COMMIT,
            file.handle,
        );
        if (create_status != .SUCCESS) return windows.unexpectedStatus(create_status);
        defer windows.CloseHandle(section);

        var base: ?*anyopaque = null;
        var view_size: windows.SIZE_T = size;
        const map_status = windows.ntdll.NtMapViewOfSection(
            section,
            windows.GetCurrentProcess(),
            @as(*windows.PVOID, @ptrCast(&base)),
            null,
            0,
            null,
            &view_size,
            .ViewUnmap,
            0,
            windows.PAGE_READONLY,
        );
        if (map_status != .SUCCESS) return windows.unexpectedStatus(map_status);
        const mapped_base = base orelse return error.Unexpected;
        return .{
            .allocator = allocator,
            .bytes = @as([*]u8, @ptrCast(mapped_base))[0..view_size],
            .mode = .windows_mmap,
        };
    }
};

pub fn stableHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x9e3779b97f4a7c15, bytes);
}

pub fn normalizeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, value.len);
    const normalized = normalizeInto(out, value);
    return out[0..normalized.len];
}

/// Lane width for byte-level SIMD normalization.  16 lanes maps to SSE2 /
/// NEON; the compiler scalarizes cleanly on platforms without it.
const NORM_LANES = 16;
const U8x = @Vector(NORM_LANES, u8);

/// Lowercase + filter `value`, writing the kept bytes into `buf`.
///
/// Processes 16 bytes at a time: builds an "is alphanumeric" mask in SIMD,
/// computes the lowercased byte uniformly, then uses a precomputed bitmask
/// to iterate only the kept positions for the scalar emit step.  The bulk
/// of the per-byte work (range comparisons, ORing 0x20 for uppercase)
/// stays in vector registers; only the variable-width store is scalar.
pub fn normalizeInto(buf: []u8, value: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;

    const lower_a: U8x = @splat('a');
    const lower_z: U8x = @splat('z');
    const upper_a: U8x = @splat('A');
    const upper_z: U8x = @splat('Z');
    const digit_0: U8x = @splat('0');
    const digit_9: U8x = @splat('9');
    const to_lower_bit: U8x = @splat(0x20);
    const zero: U8x = @splat(0);

    while (i + NORM_LANES <= value.len) : (i += NORM_LANES) {
        const v: U8x = value[i..][0..NORM_LANES].*;

        const is_upper = (v >= upper_a) & (v <= upper_z);
        const is_lower = (v >= lower_a) & (v <= lower_z);
        const is_digit = (v >= digit_0) & (v <= digit_9);
        const is_alnum = is_upper | is_lower | is_digit;

        const lowered = v | @select(u8, is_upper, to_lower_bit, zero);

        // Iterate the keep mask scalar-side to compact into `buf`.  The
        // SIMD work has already done the range checks and lowering; this
        // loop is just the variable-width store.
        var lane: usize = 0;
        while (lane < NORM_LANES) : (lane += 1) {
            if (is_alnum[lane]) {
                if (n >= buf.len) return buf[0..n];
                buf[n] = lowered[lane];
                n += 1;
            }
        }
    }

    // Scalar tail
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (std.ascii.isAlphanumeric(c)) {
            if (n >= buf.len) break;
            buf[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return buf[0..n];
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn readHeader(bytes: []const u8, magic: u32) !Header {
    if (bytes.len < @sizeOf(Header)) return error.BadIndex;
    const h = std.mem.bytesAsValue(Header, bytes[0..@sizeOf(Header)]).*;
    if (h.magic != magic or h.version != VERSION) return error.BadIndex;
    return h;
}

fn section1(bytes: []const u8, h: Header) []const u8 {
    const start: usize = @intCast(h.section1_off);
    return bytes[start .. start + @as(usize, @intCast(h.section1_len))];
}

fn section2(bytes: []const u8, h: Header) []const u8 {
    const start: usize = @intCast(h.section2_off);
    return bytes[start .. start + @as(usize, @intCast(h.section2_len))];
}

fn stringSection(bytes: []const u8, h: Header) []const u8 {
    const start: usize = @intCast(h.string_table_off);
    return bytes[start .. start + @as(usize, @intCast(h.string_table_len))];
}

fn bytesAsSlice(comptime T: type, bytes: []const u8) []const T {
    if (bytes.len == 0) return &.{};
    const aligned: []align(@alignOf(T)) const u8 = @alignCast(bytes);
    return std.mem.bytesAsSlice(T, aligned);
}

fn lessSymbol(_: void, a: SymbolRecord, b: SymbolRecord) bool {
    if (a.doc_id != b.doc_id) return a.doc_id < b.doc_id;
    if (a.line != b.line) return a.line < b.line;
    return a.byte_off < b.byte_off;
}

fn lessImport(_: void, a: ImportRecord, b: ImportRecord) bool {
    if (a.doc_id != b.doc_id) return a.doc_id < b.doc_id;
    return a.target_sid < b.target_sid;
}

fn lessSymbolHash(_: void, a: SymbolHashRecord, b: SymbolHashRecord) bool {
    if (a.hash != b.hash) return a.hash < b.hash;
    return a.symbol_index < b.symbol_index;
}

fn lessTokenByText(writer: *Writer, a: TokenEntry, b: TokenEntry) bool {
    if (a.term_sid != b.term_sid) {
        const left = writer.stringFromSid(a.term_sid);
        const right = writer.stringFromSid(b.term_sid);
        const order = std.mem.order(u8, left, right);
        if (order != .eq) return order == .lt;
    }
    if (a.doc_id != b.doc_id) return a.doc_id < b.doc_id;
    return a.first_pos < b.first_pos;
}
