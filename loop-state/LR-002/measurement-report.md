# Measurement Report: EVM-2 — Attempt 3

## Summary
NEUTRAL — No measurable improvement. Allocation is identical; timing is within noise.

## Results
| Benchmark | Baseline | Candidate | Delta Mean | Delta Alloc |
|-----------|----------|-----------|--------|---------|
| SSTORE | 4483ns / 379B | 4314ns / 379B | -3.8% (noise) | 0B (0%) |
| TSTORE | 489ns / 57B | 392ns / 57B | -19.8% (noise) | 0B (0%) |

## Notes on Noise
- SSTORE StdDev: baseline=426ns, candidate=412ns (9-10% of mean)
- TSTORE StdDev: baseline=33ns, candidate=11ns
- BDN warnings: "minimum observed iteration time is very small" for both
- 10 iterations with InProcess toolchain — insufficient for reliable timing
- The -19.8% TSTORE delta is likely noise (2 outliers removed by BDN)

## Adjacent Benchmarks
No adjacent benchmarks run. The EvmOpcodesBenchmark SSTORE test produces
unreliable results (no stats output) due to benchmark setup issues.

## Analysis

### Why the hypothesis failed (across all 3 attempts)

The optimization target — `bytes.ToArray()` in SSTORE/TSTORE — is a **tiny
fraction** of total per-operation cost:

- **SSTORE total allocation: 379B/op**. The `.ToArray()` contributes ~20-32B
  (after `WithoutLeadingZeros()` strips leading zeros). That's only **5-8%**
  of total allocation.

- **The remaining ~350B/op comes from**: trie reads via `LoadFromTree()`
  (allocates byte[] from storage backend), dictionary operations on
  `_intraBlockCache` and `_originalValues`, `StackList<int>` rentals,
  and `Change` struct storage in `List<Change>`.

- **Small array allocation is nearly free**: .NET Gen0 allocation for a
  32-byte array is essentially a pointer bump (~1-2ns). ArrayPool/custom
  pooling has comparable overhead from thread-static access, list management,
  and return tracking.

### What each attempt tried

1. **Attempt 1**: StorageValuePool (custom exact-size pool) — saved 7B/op (~2%)
2. **Attempt 2**: Same approach with refinements — still 7B/op
3. **Attempt 3**: Removed pooling complexity, kept span API only — 0B change
   (confirms the `.ToArray()` just moves location, no allocation saved)

### Root cause
The hypothesis incorrectly estimated "5-15% allocation reduction" because it
assumed `.ToArray()` was a significant portion of SSTORE cost. In reality:
- Gen0 allocation of small arrays is near-free
- The real allocation hotspots are in the storage provider infrastructure
  (trie reads, dictionary entries, change tracking)
- Pooling small arrays adds complexity without meaningful benefit

## Recommendation
**DISCARD** — The optimization target (`.ToArray()` in SSTORE/TSTORE) is not
a meaningful contributor to allocation or timing overhead. The span API
overloads are a clean architectural improvement but provide no performance
benefit. Future work should target the larger allocation sources (trie reads,
change tracking infrastructure) or explore value-type storage representations
similar to Geth (common.Hash) and Reth (U256).
