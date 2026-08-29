# Post-pin upstream round 3 (2026-08-22/23) — three candidates checked, production unchanged

> **Dated 2026-08-23.** Production **stays** `c8r-tbfix-ixfix-c128arev-smpcache`
> ([docs/17](17-postpin-upstream-round2.md)). This page is the negative-result
> receipt for the third post-pin survey: every candidate that reached a serving
> window was **held**, and a fourth was rejected before staging — for reasons
> written down here so they are not re-proposed.

The third upstream survey of the vLLM `main` delta on top of the production pin,
run exactly like rounds 1–2: one payload per lane, standing qualification gate
(warm paired non-inferiority ≥6 paired runs, needles on both arms, T2 logprobs,
functional battery, energy sampling, bookend drift guard, finalizer always
restores prod), cold arms discarded and re-armed warm. **All three lanes HELD;
nothing was promoted; no knob, image, or cache root moved.**

- **Survey window:** `69d3335066..bbe8b23e1a` — 235 commits since the round-2
  survey (526 since the `48bada6ea4` pin), ~30 shortlisted and triaged, six
  deep-dived (diff + PR body + prod-path check + port cost), plus a community
  scan (NVIDIA DGX Spark forums / GitHub, Aug 2026).
- **Honest expectation management:** this round had no Tier-S silent-corruption
  fix like round 2's trio. The payloads were a defensive assert-class cherry-pick,
  an upstream re-land we had explicitly barred pending a fixed implementation,
  and a community CPU-burn fix with no proven throughput number. Holding all
  three is a real result, not a null one.

## Production (unchanged)

| Knob | Value |
|---|---|
| Image | `vllm-dspark-runtime:v0261-main-c8r-tbfix-ixfix-c128arev-smpcache` (`sha256:603bb93273b9…`) |
| Upstream pin | vLLM `main` @ `48bada6ea4` + overlay0261 + #49731 revert + four derivative layers |
| Weights | `deepseek-ai/DeepSeek-V4-Flash-0731` @ `9e165c30e2704aec5d9d593cce3eebd58bbef1cb` |
| Cache roots | the `-smpcache` set (`vllm-cache-smpcache`, `flashinfer-smpcache`, `tilelang-smpcache`, `triton-cache-smpcache`) |
| KV | `nvfp4_ds_mla`, `KV_CACHE_MEMORY_BYTES=21316272128` → **3,027,217** tokens |

Rollback ladder and every config example in this kit are unchanged. If you are
cloning the kit today, build exactly what [docs/17](17-postpin-upstream-round2.md)
says — round 3 adds nothing to copy.

## Lane 1 — #53017 draft-logits cache column stride ("gumbelfix") → **HOLD**

Upstream fixed `gumbel_sample`'s draft-logits cache indexing
(`req_state_idx * logits_cache_stride + col * vocab_size`) to pass strides
separately, for the case where a draft model pads its cache rows narrower than
vocab. Prod runs MRV2 + DSpark probabilistic drafting at n=2 — the exact feature
intersection this kernel serves — so the assert-class hardening (zero cost even
if the misalignment never triggers here) justified a window. Ported as a
two-file cherry-pick (`gumbel.py` + call site) onto the smpcache image; the fork
files were byte-identical to the pin, so the pick was clean.

Correctness was fully arm-neutral: T2 logprobs **bit-exact 826/826 on both
bookends**, needles **3/3 @ 200K / 1M-early / 1M-late on both arms**, acceptance
flat 0.504 → 0.506. Throughput split the decision across two windows:

| Window | C1 | C8 |
|---|---|---|
| Cold gate (fresh `-gumbelfix` roots) | **pass**: +0.67% (lower95 −1.27%) | **fail**: −0.35%, lower95 −3.08% vs −3.0% margin; energy upper95 +3.04% vs +3.0% |
| Warm re-arm | **fail**: −1.73%, lower95 −4.00% | **pass**: +0.21% (lower95 −2.80%) |

No clean non-inferiority pass in either window, and the marginal cell *flipped*
between windows while bookends stayed clean (drift ≤0.93%). That is the noise
signature, not an effect. **Held.** The fix arrives free at the next rebase;
do not spend another window on it standalone.

## Lane 2 — #52823 adaptive topk width, stride-safe re-land ("atw") → **HOLD, closed**

Round 2's c128arev revert (#51318) carried an explicit reopen-bar: revisit when
upstream lands adaptive packing *without* the row-stride corruption. #52823 is
that re-land — buffers are column-sliced (`[:, :active_topk_width]`) instead of
row-width-packed, with stride asserts and regression tests — so the bar was met
and the port was made onto the fork's own c128arev-state `sparse_mla.py` (one
file, over the smpcache image).

The corruption battery passed cleanly — this is the interesting part:

- Needles **3/3 on both arms** (200K / 1M-early / 1M-late).
- T2 max \|Δlogp\| **4.4e−07** (n=826, both bookends) — numerically benign.
- Spec-decode acceptance **improved** 0.512 → 0.594.

The numbers were still decisively bad. C1 read +40.4% mean (lower95 +32.2%) —
but at energy/token **+73.7%** (upper95 +83.6%), i.e. ~**2.4× sustained package
power** (1.40× tok/s × 1.74× J/tok): the signature of an untuned fallback kernel
path, not an optimization. C8 collapsed: **−17.2%** (lower95 −21.7%) with energy
+47.0% (upper95 +70.2%), and the candidate's C8 outer means ranged 61.3–76.1
against production's 84.0–89.2 — a mid-burn collapse, not a uniform slowdown.
Three non-inferiority failures. **Held and closed.** Same lesson as round 2's
Lane B: B300-tuned kernels do not transfer to GB10 un-tuned — GB300≠GB10 yet
again. Re-evaluate only as part of a future rebase where the autotune surface
moves with it.

## Lane 3 — SpinCondition bounded busy-wait sleep ("spinwait") → **HOLD**

Community finding (DGX Spark forums, Aug 2026): on 2×GB10 TP=2, vLLM's
`shm_broadcast` reader spins at memory speed between steps — measured ~1.9 head
cores burned vs worker; a bounded `time.sleep(250µs)` inside the busy branch cut
that −98.7% and dropped head thermals meaningfully (>95 °C time 8.25% → 1.02%).
On GB10 the CPU/GPU share package and thermal budget, spark1 has the thin boot
memory margin, and the watchdog pages on swap churn — so a free CPU/thermal
co-benefit was worth a window even with no proven throughput number. Upstream
has zero commits touching `shm_broadcast.py` between the pin and current `main`
(nothing to adopt); the payload is a one-file local patch, with the sleep placed
*inside* the busy branch deliberately — lowering `busy_loop_s` instead would push
every decode step into idle mode whose indefinite zmq wait is a deadlock
candidate.

Gate result: correctness bit-exact (T2 826/826 both bookends, needles 3/3 both
arms, acceptance flat 0.507 → 0.503), and throughput non-inferiority **passed
both cells** — C1 −1.03% (lower95 −2.36%), C8 **+2.50%** (lower95 −0.41%). C8
energy was clean (mean −1.08%, upper95 +1.16%). The single miss: **C1
energy/token upper95 +3.84% vs the +3.0% margin** (mean +2.14%).

**Held on one marginal energy cell.** This is the cheapest lane to re-gate — a
single file over current prod, no rebase dependency — and the mechanism predicts
idle/low-concurrency benefit that a C1-heavy window may under-sample. Left out
of production because a marginal-fail is a marginal-fail under the standing bar;
revisit with a longer warm soak or after any scheduler change that touches
per-step host work.

## The three candidate payloads (held, therefore not under [patches/](../patches/))

By kit convention this repo only ships **promoted** derivative layers. The round-3
candidates were built and gated in the private ops workspace; each is a small,
reviewable file over the smpcache image, recorded here precisely enough to
reconstruct:

| Kit | Files changed | Change |
|---|---|---|
| gumbelfix (#53017) | `vllm/v1/spec_decode/eagle/gumbel.py` + 3-line call site in `rejection_sampler_utils.py` | Pass `logits_cache_stride_0` / `logits_cache_stride_1` separately instead of indexing `req_state_idx * logits_cache_stride + col * vocab_size`; assert cache not narrower than sampled logits. |
| atw (#52823) | `vllm/v1/attention/backends/mla/common/sparse_mla.py` (fork's c128arev state) | Column-slice adaptive-width buffers (`[:, :active_topk_width]`) + stride asserts, replacing the fixed capacity-width rows c128arev restored. |
| spinwait | `vllm/distributed/device_communicators/shm_broadcast.py` | `_SPINWAIT_SLEEP_S = 0.00025`; inside `SpinCondition.wait`'s busy branch, `time.sleep(_SPINWAIT_SLEEP_S)` after `sched_yield()` — never entering idle mode. |

Each shipped with its own `Dockerfile.runtime` and `build-and-distribute.sh`
(byte-identical image IDs across both nodes), its own `-gumbelfix` / `-atw` /
`-spinwait` generated-cache roots, and was removed from rotation by the window
finalizer after the hold verdicts.

## Checked before staging — #52998 FlashInfer all-reduce default flip: structurally N/A

Upstream flipped `VLLM_ALLREDUCE_USE_FLASHINFER` toward default-on. In-code triage
(at the prod pin) found two independent blockers for this deployment:

1. `FI_ALLREDUCE_FUSION_MAX_SIZE_MB` has **no sm_121 row** (capabilities 90/100/
   103/107 only) → `FlashInferAllReduce.__init__` gets `max_workspace_size=None`
   and **hard-disables itself**, regardless of the env var. There is nothing to
   flip.
2. Even with a table entry patched in, FlashInfer's trtllm/mnnvl all-reduce
   workspaces require **intra-host NVLink P2P/IPC** — impossible for a TP group
   spanning two nodes over QSFP RoCE. Cross-node collectives ride NCCL here
   (already tuned, 23.1 GB/s dual-rail).

The upstream flip was validated on single-host NVLink domains (GB200-class). Do
not re-propose without an SM12x table entry **and** a single-host topology.

## Also checked this round — evaluated and rejected / deferred

| Commit / PR | Verdict | Reason |
|---|---|---|
| #52796 normalize FlashInfer prefill LSE | next rebase | Patched files sit on the generic FlashInfer MLA prefill backend; prod's sparse path goes through the fork's `flashinfer_sparse.py`. Re-check when the backend surface moves. |
| #52795 adaptive verification | SKIP | sm90-gated — dead code on GB10/sm_121. |
| #53040 MegaMoE shared-expert fusion | SKIP | Requires `moe_backend=deep_gemm_mega_moe`; prod runs the default MoE path. Switching backends is the barred EP/deep_gemm class. |
| #53152 K3 MXFP4 top-k tail fusion (~5% E2E claimed) | SKIP | Kimi-K3-specific runner/ops; not on the deepseek_v4 path. |
| #52041 skip MM broadcast for prefix-cached items | SKIP | Multimodal-only; prod serves text-only. |
| #52882 / #52737 AITER DSV4 kernels | SKIP | ROCm/gfx950-only. |
| #52948 bidirectional encoder attention | SKIP | Encoder-only; no bearing on causal serving. |
| #52560 Qwen3-Omni DSpark support | SKIP | Different model. |
| #53139 remove FlashInfer DSpark DCP | next rebase | Cleanup of a path prod doesn't use; nothing to test. |
| #52836 revert DSv4 eager workspace reuse | next rebase | Hygiene; prod never showed eager-workspace symptoms, no perf claim. |
| #52809 scope DSpark backend inheritance to V4 | next rebase | Multi-model-server bugfix; single-model deployment unaffected. |
| #38962 / #53304 compile-cache device index | N/A | Single-GPU-visible nodes; device-index ambiguity cannot arise. |
| #52775 SM120 swapAB fp8 GEMM dispatch | N/A | sm_120 CUTLASS blockwise-fp8 path; prod's GEMMs ride the DSpark/MXFP4 stack with a frozen DeepGEMM pin. |
| #52681 FlashInfer 0.6.17 bump | rides next rebase | Whole-dependency bump = rebase-class change, never a derivative payload. |
| #50723 sparse checkpoint updates | N/A | RL training flow. |

Still standing from earlier rounds ([docs/16](16-post-pin-qualification.md),
[docs/17](17-postpin-upstream-round2.md)): no rebasing the kit onto later `main`,
`reasoning_effort=high` kept, async stays explicitly off, retention interval left
alone until #52216's default arrives.

## Community scan — what transferred and what didn't

- **SpinCondition busy-wait** → became Lane 3 above (held on one energy cell).
- **UCX rcache request leak** → N/A here, reaffirmed: no UCX env vars or libs in
  the running container; the fabric is NCCL NET=IB directly. Recorded so it is
  not re-proposed (third time it has surfaced).
- **MiaAI-Lab 0731 recipe** → different base image lineage; its headline knobs
  (breakable graphs OFF, MTP n=5, `flashinfer_b12x` MoE) belong to builds where
  FULL cudagraphs won the author's A/B. Our breakable-graphs lane is separately
  gated (W5 saturation, still uncalibrated) — not transferable advice either way.
- **Push-based allreduce (#44891)** → NVLink-only; N/A on a QSFP fabric.

## Wiring lessons (recorded so the next lane costs one window, not three)

Every new lane needs **four** things, not one: a profile dir + kit +
`build-and-distribute.sh`, plus three code wiring points — the
`qualify-lane.sh` case, `next-lane-admission.py` (PROFILES + ROOTS entries,
source-marker gate, image-differs tuple), **and the `ab-switch.sh` target
allowlist** (missed twice; the switcher correctly refuses unknown targets, which
aborts the window after prod is restored). Source-marker gates that grep-count an
**absent** marker must terminate the remote command with `; true` — bare
`grep -c` exits 1 on zero matches and fails the whole ssh chain. Two windows
aborted on wiring this round; the finalizer restored prod cleanly both times,
which is exactly what it is for.

## What you should copy if you deployed an older revision of this kit

**Nothing moved in this round.** Build per [docs/17](17-postpin-upstream-round2.md).
What to watch for at the next natural rebase point: #53017 (draft-logits stride),
#52823 (adaptive topk width — needs its autotune story validated on GB10, not
assumed), #51538 (sparse MLA fixes), and #52216's retention default arrive
together there. The spinwait patch remains a documented one-file option for
head-core/thermal relief, held to the same evidence bar as everything else.
