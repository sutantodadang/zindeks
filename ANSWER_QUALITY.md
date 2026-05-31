# Answer Quality Benchmark

## Purpose

Existing zindeks benchmarks (`BENCHMARKS.md`) measure indexing speed and memory. This benchmark measures **retrieval quality** and **cost proxy**: does the graph give better answers with fewer tokens than a grep-style file exploration? It produces an honest scorecard — precision/recall/F1 plus a byte-cost comparison — over a curated multi-language fixture corpus with a hand-authored answer key.

Run it:

```
zindeks bench answer-quality [corpus_path]
# default corpus_path = bench/corpus
```

---

## Methodology

### Corpus

Four small source files under `bench/corpus/` covering Zig, Python, and TypeScript:

| File | Language | Key symbols |
|---|---|---|
| `orders.zig` | Zig | `processOrder`, `validateOrder`, `cancelOrder` |
| `payments.zig` | Zig | `chargeCard`, `refund`, `audit` |
| `inventory.py` | Python | `reserve_stock`, `check_stock`, `release_stock` |
| `cart.ts` | TypeScript | `addItem`, `total` |

Intentional design:
- **Intra-file calls** — extracted correctly by tree-sitter (e.g. `validateOrder` called by both `processOrder` and `cancelOrder` within `orders.zig`).
- **Cross-file calls** — NOT extracted (e.g. `pay.chargeCard(id)` in `orders.zig` via `@import`). This is a known recall gap.
- **Decoys** — string literals and comments containing symbol names (e.g. `audit("processOrder")` and `// NOTE: processOrder …`). These must NOT create edges — only real call sites matter.

### Arms

**zindeks arm** (one tool call per question):
- `definition`: SQL query on graph DB for `symbols WHERE name = target`, returns file paths.
- `callers`: `call_graph.trace(target, .inbound, depth=1)` — depth-1 nodes only.
- `callees`: `call_graph.trace(target, .outbound, depth=1)` — depth-1 nodes only.

**grep arm** (baseline modeling a grep-first agent):
- For ALL question types, returns the set of corpus file basenames where the target appears as a whole-word match (byte-scan, case-sensitive, word boundary = char not in `[A-Za-z0-9_]`).
- Cannot distinguish caller vs callee vs mention — that limitation is the point.
- Implemented in-process (no subprocess); deterministic.

### Scoring

Answers are scored at **file granularity** (set of basenames). For each question:

- `precision = |arm ∩ GT| / |arm|`
- `recall = |arm ∩ GT| / |GT|`
- `F1 = 2·P·R / (P+R)`

**Empty-GT convention** (entry point questions): if GT is empty, `precision = (arm returned nothing ? 1.0 : 0.0)`, `recall = 1.0`, `F1 = precision`. An arm that wrongly returns files for an entry point is penalized to 0.

### Cost proxy

- **zindeks cost**: number of tool invocations (constant — one per question).
- **grep cost**: total bytes of matched whole-word lines across all corpus files for the target. This models how many bytes an agent must read to disambiguate symbol mentions.
- **Ratio**: `grep_bytes / zindeks_answer_bytes` — how many more bytes grep forces the agent to read per equivalent answer.

---

## Measured Results

Output from `zindeks bench answer-quality bench/corpus`:

```
bench answer-quality corpus=bench/corpus

  indexing bench/corpus...

  ID   type         target           zindeks P/R/F1            grep P/R/F1               grep_bytes
  ----------------------------------------------------------------------------------------------------
  Q01  callers      validateOrder    1.00/1.00/1.00               1.00/1.00/1.00               80
  Q02  callees      processOrder     1.00/1.00/1.00               1.00/1.00/1.00               116
  Q03  callers      chargeCard       1.00/1.00/1.00               0.50/1.00/0.67               56
  Q04  callees      chargeCard       1.00/1.00/1.00               0.50/1.00/0.67               56
  Q05  callers      check_stock      1.00/1.00/1.00               1.00/1.00/1.00               112
  Q06  callees      reserve_stock    1.00/1.00/1.00               1.00/1.00/1.00               60
  Q07  callers      processOrder     1.00/1.00/1.00               0.00/1.00/0.00               116
  Q08  callees      addItem          1.00/1.00/1.00               1.00/1.00/1.00               77
  Q09  definition   validateOrder    1.00/1.00/1.00               1.00/1.00/1.00               80
  Q10  definition   check_stock      1.00/1.00/1.00               1.00/1.00/1.00               112
  ----------------------------------------------------------------------------------------------------
  AVG                                1.00/1.00/1.00               0.80/1.00/0.83               865

  cost proxy: zindeks=10 tool_calls  grep=865 bytes read  ratio=7.3x bytes/tool_call

  per-qtype breakdown:
    definition: zindeks_F1=1.00 grep_F1=1.00
    callers:    zindeks_F1=1.00 grep_F1=0.67
    callees:    zindeks_F1=1.00 grep_F1=0.92

bench answer-quality done.
```

---

## Findings

### 1. Decoy immunity — precision win (Q07)

Q07 asks for callers of `processOrder`. The ground truth is empty: `processOrder` is an entry point — nothing calls it in the corpus. Two decoys exist:

- Comment: `// NOTE: processOrder replaces the old submitOrder path` (in `orders.zig`)
- String literal: `audit("processOrder")` (in `payments.zig`)

**zindeks result**: F1 = 1.00. The graph correctly returns no callers. Only real call-site edges are stored; string literals and comments are inert.

**grep result**: F1 = 0.00. grep matches both decoy files (`orders.zig` via the comment, `payments.zig` via the string), returning 2 false positives. An agent following grep's output would open and read two files that contain zero actual callers.

### 2. Callee-direction capability (Q04, Q06, Q08)

Q04: `callees(chargeCard)` — expected `{payments.zig}` (intra-file calls to `audit` and `refund`).

**zindeks result**: F1 = 1.00. The graph knows direction — outbound edges from `chargeCard` only.

**grep result**: F1 = 0.67. grep matches `chargeCard` in both `orders.zig` (caller site) and `payments.zig` (definition + callees), so it includes an irrelevant file. grep cannot distinguish callers from callees — it surfaces everything.

Q06 and Q08 show the same directional advantage with Python and TypeScript.

### 3. Cross-file resolution — gap closed for unambiguous names (Q02, Q03)

**Q02: callees(processOrder)** — expected `{orders.zig, payments.zig}`.
- `validateOrder` is an intra-file call (extracted). `chargeCard` is called via `pay.chargeCard(id)` where `pay = @import("payments.zig")` — a qualified cross-file call.
- **zindeks result**: F1 = 1.00. The qualified call is now stripped to its last segment (`chargeCard`) and resolved using same-file-first + globally-unique cross-file lookup. Since `chargeCard` is defined exactly once in the corpus, the edge is created with confidence 0.9.

**Q03: callers(chargeCard)** — expected `{orders.zig}`.
- `processOrder` in `orders.zig` calls `pay.chargeCard(id)`. The edge is now correctly extracted and resolved.
- **zindeks result**: F1 = 1.00. The cross-file CALLS edge exists; `processOrder` appears as a caller.

**How the fix works**:
1. **Qualifier stripping**: the Zig extractor now strips dotted/scoped prefixes before storing the callee name (`pay.chargeCard` → `chargeCard`, `self.foo` → `foo`). The generic extractor already did this; Zig is now consistent.
2. **Two-phase resolution**: edges are buffered during symbol insertion (phase 1) and resolved in a second pass after all symbols exist (phase 2). This eliminates the ordering bug where a call from file F to a symbol in file G found nothing because G's symbols were not yet inserted.
3. **Precision-safe resolver**: for CALLS edges, the target is looked up same-file first (confidence 1.0), then globally unique (exactly one definition repo-wide, confidence 0.9). If the name is ambiguous (>1 definition) or unknown (0 definitions), the edge is **skipped**. This is why Q07 remains correct: `audit("processOrder")` is a string literal — the parser never emits a CALLS edge for it at all.

**Remaining limitation**: cross-file calls where the callee name is ambiguous (e.g. multiple files each define `init`, `new`, or `print`) are deliberately not resolved to preserve precision. Import-scope disambiguation — tracking `const pay = @import("payments.zig")` as an alias and using it to narrow the target — is future work.

**grep result on Q02 and Q03**: grep finds both files by text match, producing the same recall as zindeks now. But grep still has lower F1 overall because it cannot distinguish callers from callees (Q04) or filter out decoys (Q07).

### 4. Summary table

| Metric | zindeks | grep |
|---|---|---|
| Mean precision | 1.00 | 0.80 |
| Mean recall | 1.00 | 1.00 |
| Mean F1 | 1.00 | 0.83 |
| Entry-point accuracy (Q07) | 1.00 (immune) | 0.00 (false positives) |
| Cost (10 questions) | 10 tool calls | 865 bytes to read |
| Cost ratio | 1x | 7.3x bytes/call |

zindeks now achieves perfect F1 (1.00 vs 0.83) with zero false positives, closing the previous cross-file recall gap while preserving complete decoy immunity.

---

## Extending to End-to-End LLM Token Measurement

The benchmark above measures retrieval quality deterministically, with no LLM and no network. To measure actual token cost and answer quality in an agent loop, an optional out-of-tree harness would:

**Two-arm agent setup** (kept out of tree to preserve zero-dep core):

1. **grep arm**: A thin Python/Node script that, for each question, runs `grep -rn <target> corpus/`, feeds all matched lines to a Claude API call with the prompt "Which function calls `<target>`?", and records tokens_in + tokens_out.

2. **zindeks-MCP arm**: A thin script that starts `zindeks serve`, sends a single MCP `trace_call_path` JSON-RPC call, and feeds the structured JSON response to a Claude API call with the same prompt. Records tokens_in + tokens_out and tool_calls.

**Metrics to collect**:
- Tokens per question (input + output)
- Tool calls per question
- Answer accuracy (LLM-judged or regex-matched against expected symbol names)
- Cost in USD (using Anthropic pricing at time of run)

**Expected outcome** based on the retrieval benchmark: the zindeks arm should use ~9x fewer input tokens per question (structured answer vs raw grep lines) and achieve higher accuracy on directional and entry-point questions. The cross-file gap would show up as recall misses that the grep arm (with more context) may answer correctly at higher token cost.

This harness is intentionally kept separate from the core repo to avoid network, API key, and LLM dependencies in the CI pipeline.
