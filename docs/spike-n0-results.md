# Spike N0: does crawling the memstore tree beat keyword search?

Status: **in progress** (2026-10-02). Gate defined in
[design-pageindex-memstore.md §14.1](design-pageindex-memstore.md). Code: `spikes/n0/`.
This page publishes aggregate numbers only. The question set, gold labels and the scratch
database hold private history and stay in `~/.local/share/omarchy-memstore/spike-n0/`
(mode 700), never in this repository.

## Setup

- **Data:** 14 days (2026-09-18 → 2026-10-02) of real history on this laptop: 49 Claude Code
  sessions (subagent transcripts attached to their parent), 498 Hermes sessions across 7 agent
  homes, and 906 commits in 13 `~/Work` repos. 59.9k leaves, ~8.0M tokens, 890 leaves
  scrubbed by `harness/secrets.py redact()`. The session that ran this spike was excluded.
- **Model:** Qwen3.8-4B-Distill Q4_K_M on llama-server, fully on the RTX 3050 Ti (3.47 GB VRAM,
  supergfx Hybrid). Decisions are single-token logprob calls (`max_tokens: 1`).
- **Retrieval unit:** at most 3,500 tokens of consecutive leaves (the 4B's facts budget). All
  tree arms end in the same unit size. A hit is a top-3 unit from a gold session.
- **Questions:** 30 "where did we…" questions written before any arm existed, paraphrased away
  from their source wording, gold labelled at session level by distinctive-string search
  (12 commit-backed, 12 conversation-backed, 6 machine-change). 5 are for tuning τ; **25 are
  the evaluation set**. Frozen: sha256 `e7c7c91001407d087719180b1ca2dfe81e8747ab56338d65110b4c855a2af1e3`.

## Arms

| Arm | What it is |
|---|---|
| A_leaf | BM25 (SQLite FTS5) over leaves, top 3 — the keyword baseline |
| A_unit | BM25 aggregated to the same 3,500-token units the crawls return |
| B | v1 date tree (month → day → session → chunk), field titles, independent yes/no per child |
| B_choice | B with a permuted A/B/C… choice (two orders, averaged) instead of yes/no |
| C | v2 project tree (project → workstream → session → episode → chunk), title + deterministic preview, yes/no per child |
| C_choice | C with the permuted choice |
| C_hyb | C seeded with BM25's top 16 leaves (secondary arm; uses keywords) |
| D, D_choice, D_hyb | C's arms plus local-model navigation summaries on interior nodes |

Crawl budget: 48 decision calls per question. τ (the branch threshold) was tuned per arm on
the 5 tuning questions, then frozen.

## Results on the 25 evaluation questions

| Arm | hit@1 | **hit@3** | MRR | calls/q | s/q (GPU) | tokens delivered | τ |
|---|---|---|---|---|---|---|---|
| A_leaf (baseline) | 0.64 | **0.64** | 0.64 | 0 | 0.02 | 584 | – |
| A_unit | 0.64 | **0.64** | 0.64 | 0 | 0.02 | 8,903 | – |
| B (date tree) | 0.00 | **0.00** | 0.00 | 2.0 | 0.27 | 0 | 0.5 |
| B_choice | 0.04 | **0.04** | 0.04 | 21.0 | 11.3 | 4,093 | 0.05 |
| C (project tree, yes/no) | 0.24 | **0.40** | 0.31 | 39.6 | 7.4 | 3,027 | 0.3 |
| **C_choice** (project tree, permuted choice) | 0.52 | **0.68** | 0.58 | 14.2 | 7.4 | 3,976 | 0.5 |
| C_hyb (C + BM25 seeds) | 0.60 | **0.72** | 0.66 | 13.8 | 3.8 | 7,878 | 0.05 |
| D / D_choice / D_hyb | pending | | | | | | |

By question type (hit@3):

| Type | A_leaf | C | C_choice | C_hyb |
|---|---|---|---|---|
| commit (10) | **8/10** | 4/10 | 5/10 | **8/10** |
| conversation (10) | 4/10 | 6/10 | **8/10** | 6/10 |
| machine (5) | **4/5** | 0/5 | **4/5** | **4/5** |

Search cost (PageIndex's `tree_optimize` measure, in tokens: routing views read plus the unit):

| Tree | worst case | average to a unit | sibling groups that look identical |
|---|---|---|---|
| B (date) | 5,943 | 3,943 | 291 |
| C (project + previews) | 11,200 | 6,134 | 5 |

## Findings so far

1. **The date tree cannot be crawled.** 0/25 and 1/25. Its 291 groups of identical-looking
   siblings leave the model nothing to choose between, which confirms the 2026-10-01 test.
2. **The project tree with previews is navigable without any keywords.** C_choice reaches
   0.68, above BM25's 0.64. That is +4 points, short of the gate's +10.
3. **Choice beats yes/no** on this tree (0.68 vs 0.40, with a third of the calls). Comparing
   siblings side by side, in two orders to cancel position bias, routes better than judging
   each branch alone. This reverses design §7.1's default.
4. **Keyword search and the crawl fail on different questions.** BM25 wins on commits (exact
   subjects), the crawl wins on conversations (paraphrased intent). The union of their top-3
   lists covers **23/25 (0.92)**. Seeding the crawl with BM25 (C_hyb, 0.72) is a weak way to
   combine them: the seeds crowd out the crawl's best finds.
5. **PageIndex's search-cost metric is the wrong acceptance test for us.** It counts tokens
   read, so the uninformative date tree "wins" (5.9k vs 11.2k worst case). S6's done-when in
   the design (beat the date tree's search cost) is replaced by retrieval quality on this set.
6. Prompt-cache reuse was lower than the design assumed (11–46% of prompt tokens), because
   each call's tail differs. Calls still cost only 126–436 ms on the GPU.

## Pre-registered follow-up: fusion arm F (registered before it was run)

Finding 4 was not anticipated by §14.1, so it is tested on **new** questions rather than
argued from the set that suggested it:

- **Arm F_T** returns keyword and crawl hits interleaved (A1, T1, A2), skipping duplicates,
  where T is the best pure crawl arm (C_choice, or D_choice if it scores higher on the 25).
- **Validation set:** 15 new questions written after the 25-question results and before F
  was run, same rules (paraphrased, gold at session level). Frozen: sha256
  `bd5a70b5d7f621dc8db03e78317f36a20fbdd5972171d564bc13ece4a9101ede`.
- **Rule:** F ships as the Navigator if, on the validation set, it beats A_leaf's hit@3 by
  ≥ 10 points **and** does not lose on hit@1. Otherwise the Navigator is BM25 + re-rank.

## Decision

Pending arm D and the validation run.
