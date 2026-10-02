# Spike N0: does crawling the memstore tree beat keyword search?

Status: **complete** (2026-10-02). Decision: **the Navigator ships as keyword search + a local-model re-rank over the project tree's units; the pure crawl and the navigation summaries do not ship.** Gate defined in
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
| D (C + summaries, yes/no) | 0.12 | **0.28** | 0.20 | 21.8 | 6.9 | 1,212 | 0.5 |
| D_choice | 0.44 | **0.72** | 0.55 | 14.8 | 9.9 | 4,194 | 0.5 |
| D_hyb | 0.60 | **0.72** | 0.66 | 13.8 | 4.0 | 7,878 | 0.05 |

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
| D (C + summaries) | 13,347 | 8,879 | 5 |

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

## Validation run (15 new questions, frozen before running)

| Arm | hit@1 | **hit@3** | MRR | calls/q | s/q | tokens |
|---|---|---|---|---|---|---|
| A_leaf (baseline) | 0.27 | **0.47** | 0.33 | 0 | 0.01 | 737 |
| A_unit | 0.27 | **0.47** | 0.33 | 0 | 0.02 | 9,151 |
| C_choice | 0.33 | **0.53** | 0.42 | 14.6 | 9.5 | 2,869 |
| D_choice | 0.33 | **0.47** | 0.40 | 12.4 | 8.8 | 2,780 |
| F_D_choice (pre-registered fusion) | 0.27 | **0.53** | 0.39 | 12.4 | 8.8 | 1,752 |
| F_C_choice | 0.27 | **0.53** | 0.40 | 14.6 | 9.5 | 2,075 |
| **C_hyb** (keyword hits re-ranked by the local model, then crawl) | **0.47** | **0.60** | 0.53 | 13.6 | 4.0 | 8,533 |

(F used its crawl arm's frozen τ = 0.5; the summary file prints the default.)

Both sets pooled (40 questions): A_leaf hit@3 **0.575**, hit@1 0.50; C_hyb hit@3 **0.675**,
hit@1 0.55. A_unit equals A_leaf on both sets, so the gain is the local model's re-ranking with
the tree's titles and previews, not the bigger unit size.

## Decision (rules applied as written)

1. **Pure crawl (§14.1):** best pure tree arm on the 25 is D_choice at 0.72, +8 over BM25 —
   below +10. **Does not ship.**
2. **Summaries (arm D vs C):** +4 on the 25, −7 on validation. **Do not ship; N9 is archived.**
   User question Q4 is moot.
3. **Fusion F (pre-registered):** +7 on validation, hit@1 equal — below +10. **Does not ship.**
4. **Fallback (§14.1):** "BM25 plus a re-rank of the top hits". C_hyb is exactly that: BM25's
   top 16 leaves mapped to project-tree units, each scored by the local model on its title and
   preview, best first. It has the best hit@3 on both sets (0.72 on the 25, tied with D_choice
   and D_hyb; 0.60 alone on the 15) and is +10 points pooled. Its hit@1 on the 25 (0.60) is
   below BM25's 0.64; on the 15 it is above (0.47 vs 0.27). **This is the v1 Navigator.**

Caveats: 25 and 15 questions are small samples; one question is 4 and 7 points respectively,
so differences under ~10 points are within noise. Gold labels are session-level and were set by
the experimenter. The summaries were written by the same model that later read them.

## What this changes in the design

- **§7 Navigator:** default = keyword seeds → map to units → local-model yes/no re-rank on
  title + preview → top units; then continue a short crawl from the best seeds' parents. The
  pure crawl stays available to frontier models through the tools in §7.6, not as the default.
- **§7.1:** for re-ranking, independent yes/no works well; for choosing among siblings in a
  crawl, the permuted choice beats yes/no (0.68 vs 0.40).
- **§5 tree:** still needed. Its units, titles and previews are what the re-rank reads, its
  structure feeds the packet's "where you are" slot and the agentic tools. Keep v2 (project
  tree + deterministic previews); the date tree is dropped even as a secondary navigation view.
- **§5.4 / N9:** navigation summaries dropped.
- **S6 done-when:** replace "beats the date tree's search cost" with "C_hyb-style retrieval on
  this question set does not regress (hit@3 ≥ 0.70 on the 25, ≥ 0.60 on the 15)". PageIndex's
  search-cost metric rewards uninformative trees.
- **Open lead, not a decision:** keyword search and the crawl miss different questions (union
  0.92 on the 25). A better fusion than F's simple interleave may close the gap; it would need a
  third, fresh question set.
