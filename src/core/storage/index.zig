const std = @import("std");
const builtin = @import("builtin");

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
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    index_path: []const u8,
    strings: std.ArrayList(u8),
    string_offsets: std.ArrayList(u32),
    string_ids: std.StringHashMap(u32),
    docs: std.ArrayList(MutableDoc),
    content_file: std.fs.File,
    content_len: u64,
    symbols: std.ArrayList(SymbolRecord),
    imports: std.ArrayList(ImportRecord),
    tokens: std.ArrayList(TokenEntry),

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, index_path: []const u8) !Writer {
        var content_file = try createIndexFile(allocator, dir, index_path, "content.idx");
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
            .allocator = allocator,
            .dir = dir,
            .index_path = try allocator.dupe(u8, index_path),
            .strings = .{},
            .string_offsets = .{},
            .string_ids = std.StringHashMap(u32).init(allocator),
            .docs = .{},
            .content_file = content_file,
            .content_len = 0,
            .symbols = .{},
            .imports = .{},
            .tokens = .{},
        };
    }

    pub fn deinit(self: *Writer) void {
        var it = self.string_ids.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.string_ids.deinit();
        self.string_offsets.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.docs.deinit(self.allocator);
        self.content_file.close();
        self.symbols.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        self.allocator.free(self.index_path);
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
        try self.string_offsets.append(self.allocator, @intCast(self.strings.items.len));
        try self.strings.appendSlice(self.allocator, value);
        try self.strings.append(self.allocator, 0);
        const owned = try self.allocator.dupe(u8, value);
        try self.string_ids.put(owned, sid);
        return sid;
    }

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

        var part_buf: [256]u8 = undefined;
        var part_len: usize = 0;
        var prev_lower = false;
        for (ident) |c| {
            if (!std.ascii.isAlphanumeric(c)) {
                if (part_len > 0) {
                    try self.addToken(doc_id, part_buf[0..part_len], pos);
                    part_len = 0;
                }
                prev_lower = false;
                continue;
            }
            const upper_boundary = std.ascii.isUpper(c) and prev_lower;
            if (upper_boundary and part_len > 0) {
                try self.addToken(doc_id, part_buf[0..part_len], pos);
                part_len = 0;
            }
            if (part_len < part_buf.len and std.ascii.isAlphanumeric(c)) {
                part_buf[part_len] = std.ascii.toLower(c);
                part_len += 1;
            }
            prev_lower = std.ascii.isLower(c) or std.ascii.isDigit(c);
        }
        if (part_len > 0) try self.addToken(doc_id, part_buf[0..part_len], pos);
    }

    fn indexIdentifierIntoMap(self: *Writer, doc_id: u32, tokens_for_doc: *std.AutoHashMap(u32, TokenAccum), ident: []const u8, pos: u32) !void {
        var normalized_buf: [256]u8 = undefined;
        const normalized = normalizeInto(&normalized_buf, ident);
        if (normalized.len > 0) try self.addTokenToMap(doc_id, tokens_for_doc, normalized, pos);

        var part_buf: [256]u8 = undefined;
        var part_len: usize = 0;
        var prev_lower = false;
        for (ident) |c| {
            if (!std.ascii.isAlphanumeric(c)) {
                if (part_len > 0) {
                    try self.addTokenToMap(doc_id, tokens_for_doc, part_buf[0..part_len], pos);
                    part_len = 0;
                }
                prev_lower = false;
                continue;
            }
            const upper_boundary = std.ascii.isUpper(c) and prev_lower;
            if (upper_boundary and part_len > 0) {
                try self.addTokenToMap(doc_id, tokens_for_doc, part_buf[0..part_len], pos);
                part_len = 0;
            }
            if (part_len < part_buf.len) {
                part_buf[part_len] = std.ascii.toLower(c);
                part_len += 1;
            }
            prev_lower = std.ascii.isLower(c) or std.ascii.isDigit(c);
        }
        if (part_len > 0) try self.addTokenToMap(doc_id, tokens_for_doc, part_buf[0..part_len], pos);
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

pub fn normalizeInto(buf: []u8, value: []const u8) []const u8 {
    var n: usize = 0;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (n < buf.len) {
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
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
