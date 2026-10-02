# Multi-agent audit tooling (2026-09-25 full debug)

These files reproduce the audit that produced `docs/reviews/2026-09-25-full-debug-audit.md`.
They are Claude Code **Workflow** scripts (plain JavaScript orchestrating subagents), not part of
the pm build.

- `AUDIT-BRIEF.md` — the shared brief every finder/verifier reads first: what the project is,
  the invariants (DESIGN §2), what counts as a bug, what does not, output discipline. Adjust the
  repo path at the top when reusing.
- `find-verify.workflow.js` — per-file-cluster finders (two lenses per code cluster, one per test
  cluster) → per-cluster dedup → three adversarial verifiers per finding. Args:
  `{ctx: <brief path>, clusters: [{key, kind: 'code'|'test', files: [...], focus}]}`.
  The 2026-09-25 run used 14 clusters (see §0 of `docs/reviews/2026-09-25-full-debug-audit.md`) and, to save tokens, was later cut
  to finders only (strip the merge/verify stages) with verification done once at the end.
- `aggregate-verify.workflow.js` — the single aggregation + verification pass: chunked semantic
  dedup of all raw findings (read from JSON chunk files on disk) → final cross-chunk dedup → one
  verifier per file group (≤4 findings each), each verdict carrying `refuted`, corrected
  summary, suggested fix and fix risk. Args: `{ctx, rawCount, chunkFiles: [...]}`.

Token notes from the run: a finder over ~2 k lines costs ~150 k tokens; a verifier per finding
at high effort ~100–200 k; grouping verification by file roughly halves that. Run one workflow
at a time in a 4-CPU container (agent concurrency is capped at 2 per workflow).
