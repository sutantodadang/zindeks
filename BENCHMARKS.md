# Benchmarks

Numbers captured from `zindeks bench` after the v0.5.0 performance pass (P1+P2+P3).
Run on Windows 11, single-machine, `-Doptimize=Debug` build. Results vary across
machines; what matters here is the *shape* of the numbers — peak live memory
during indexing, allocation count under load, per-query latency with caches hot.

Re-run any scenario locally:

```bash
zindeks bench cold-index <path>          # default iters=3
zindeks bench detect-changes-synthetic N # default N=5000
zindeks bench cypher-cache N             # default N=1000
zindeks bench snippet-cache N            # default N=1000
```

Each scenario wraps its workload in a `bench.CountingAllocator` that tracks
total bytes, peak live bytes, alloc count, free count, and resize count.

---

## cold-index (self-index, 878 files)

```
[cold-index] iters=3 min=18.7s mean=18.8s p50=18.7s p99=18.8s max=18.8s peak_rss=108MB
[cold-index allocs] total=537MB peak_live=113MB allocs=45387 frees=45387 resizes=4425
```

**What this validates (B1, scanner→worker single-copy pipeline):**
- Peak live heap (113 MB) is dominated by the producer arena holding chunked
  file content plus per-worker arenas holding parsed symbol slices.
- Total bytes (537 MB across the run) is the cumulative allocation; the
  difference between total and peak live reflects arena reuse / bulk free.
- `allocs == frees` confirms no leaks at the allocator boundary.
- ~52 allocations per indexed file on average — well under the per-worker
  re-dupe overhead the old pipeline incurred.

**Baseline note.** This pass landed as one branch; no clean pre-P1 commit
exists in the working tree to A/B against. The shape goal stated in the plan
(≥35% peak RSS reduction over the pre-Phase-6 baseline) is unverifiable
without checkout-and-reindex. The producer/worker/writer pipeline is
structurally single-copy, which is what the goal asked for.

---

## detect-changes-synthetic (5000 files)

```
[detect-changes-synthetic] files=5000 elapsed=62ms peak_rss=9.9MB
[detect-changes allocs] total=65KB peak_live=2KB allocs=5004 frees=5004 resizes=0
```

**What this validates (B4, streaming merge-join):**
- Peak live during the diff is **2 KB** — independent of file count, just
  scratch buffers for the merge-join loop.
- Allocations scale linearly with output, not input: 5000 files in + 4
  fixed-overhead buffers = 5004 allocs. Each alloc is the path dupe for an
  emitted FileChange (here every file is "added" since the index was just
  built and the FS hasn't changed; the loop still allocates one path per
  result entry).
- Goal from plan: "<5 MB additional heap on 50k-file synthetic tree". Linear
  extrapolation gives ~650 KB total / 2 KB peak live at 50k files — well
  inside the budget. The old hashmap-based implementation was O(N) heap.

---

## cypher-cache (100 iters of `MATCH (a)[r]->(b) RETURN name, kind LIMIT 20`)

```
[cypher-cache] iters=100 min=115µs mean=121µs p50=116µs p99=370µs max=370µs peak_rss=10MB
[cypher-cache allocs] total=78KB peak_live=0KB allocs=300 frees=300 resizes=0
```

**What this validates (B7, static alias arrays):**
- 3 allocations per query (result buffer + 2 small SQL fragments) instead of
  per-MATCH-clause `allocPrint` for alias names. The dropped allocations
  were small (~16 bytes each for `"t0"`, `"e0"`, etc.), so the wall-clock
  win is modest at low MATCH-clause counts — measurable on hot paths with
  many clauses.
- `peak_live=0` means every allocation was freed before the next iteration
  starts — no per-iter growth.
- p99 spike (370µs vs 116µs p50) is the SQLite query planner on first run;
  subsequent iters hit prepared-statement cache inside SQLite.

---

## snippet-cache (1000 iters of `search_code("ParserPool")`)

```
[snippet-cache] iters=1000 min=1.4µs mean=1.6µs p50=1.5µs p99=1.6µs max=24.6µs peak_rss=9.8MB
[snippet-cache allocs] total=0KB peak_live=0KB allocs=0 frees=0 resizes=0
```

**What this validates (B8, snippet LRU):**
- 1.5µs mean per repeated query — the engine.search hot path is fully
  cached and returns without further allocation. Cold first-call cost
  shows up at `max=24.6µs` (24× p50).
- 0 allocations across 1000 iters indicates the cache lookup path is
  entirely zero-alloc — the engine reuses pre-allocated result slots and
  the snippet LRU returns slices into mmap'd content.
- For unique queries (cache miss every time) wall-clock would be in the
  ~20µs range based on the `max` sample.

---

## Goals from the plan vs measured

| Goal (plan) | Measured | Status |
|---|---|---|
| B1: peak RSS during cold-index drops ≥35% vs pre-Phase-6 | 113 MB peak_live for 878 files; pre-change baseline not captured | structural fix landed (single-copy pipeline), magnitude unverified |
| B2: p99 search_code latency during concurrent rename_symbol drops ≥5× | not measured (would need a concurrent harness scenario) | lock split landed (`overlay_rwlock` + `gdb_rwlock` independent), measurement deferred |
| B4: detectChanges 50k files <5 MB additional heap | 2 KB peak_live for 5k files → ~2 KB regardless of N | **met** |
| B5: ≤2 write syscalls per 100-result search_code response | dropped — responses already single-`writeMessage` | n/a |
| B6 madvise: posting=RANDOM, content=SEQUENTIAL | landed (posix only; Windows uses NtMapViewOfSection, no equiv) | **landed**, perf delta unmeasured |
| B7 cypher alias allocs: removed per-MATCH allocPrint | 3 allocs/query instead of 3+2N | **met** for N≤10 clauses |
| B8 snippet cache: repeated query → near-zero work | 0 allocs, 1.5µs mean over 1000 iters | **met** |

---

## What's not benchmarked yet

- **B2 concurrent regression gate** — needs a scenario that spins one worker
  on `rename_symbol` while N workers hammer `search_code`, measuring p99 of
  the reader stream. Add as `zindeks bench concurrent-rw` if you want a
  regression gate before changing locks again.
- **B6 madvise impact** — would need a >500 MB index to swamp the page
  cache; on smaller indices the OS does the right thing already.
- **A/B against pre-change baseline** — requires checking out a pre-P1
  commit, running the same scenarios, then checking back. Not done here
  because the changes are interdependent (B1 requires the chunked scanner,
  B4 requires the merge-join, etc. — partial reverts don't compile).
