# PhotoManager (`pm`) full-debug audit — shared context for finder/verifier agents

> Snapshot of the brief used for the 2026-09-25 run (pm 1.2.0, 440 tests, branch below). Update
> the branch and counts before reusing it.

Repo: /home/user/PhotoManager (git branch claude/full-debug-o8absa). Working tree is clean at
the start of the audit; do NOT modify any file under the repo. Use bash (cat / sed -n / grep -n)
to read code. Read files IN FULL — do not skim the first 200 lines and extrapolate.

## What the project is
A safety-first photo library manager written in Haskell (GHC 9.10.3, `src/Pm/*.hs`,
`app/Main.hs`), Windows-only (Win32 FFI in `src/Pm/Win.hs` + `cbits/pm_win.c`), with a
loopback JSON API (`pm serve`, `src/Pm/Serve*.hs`) consumed by a Tauri v2 GUI
(`gui/ui/*.js|html`, `gui/src-tauri/src/*.rs`), helper Python scripts (`scripts/*.py`), and a
tasty test suite (`test/*.hs`, 440 tests, Windows-only too). Docs are in Chinese:
`docs/DESIGN.md` (core invariants §2, domain model §3, safe-write protocol §6, risks §14),
`docs/DESIGN-COMMANDS.md` (per-command semantics), `docs/DESIGN-GUI.md`, `docs/DESIGN-P8.md`,
`docs/REVIEW-LOG*.md` (history of prior review findings and decisions — a suspected bug that
was already ruled "intended" there is NOT a bug), the `README.md` section "Roadmap and known
limitations".

No Haskell toolchain is available in this container and the code cannot be compiled or run here.
All findings must therefore be established by careful reading and tracing. Cite exact
`path:line` and quote the relevant code.

## Hard invariants the code claims to uphold (DESIGN §2)
- I1/I2: pm has NO delete primitive and NO overwrite primitive. Only Copy / Rename / Quarantine
  ops; landing is always a no-replace rename (target exists ⇒ fail). Only unlink allowed: its own
  `.pm/tmp/` temp files, and `pm trash empty` after confirmation.
- I3: every write goes through a printed+confirmed Plan; every landed file is re-read and
  sha256-verified.
- I4: every mutation writes journal Intent (with hFlush + FlushFileBuffers barrier) BEFORE the
  effect lands, then Done/Failed. Journal is append-only NDJSON in `.pm/journal.ndjson`;
  appends seal a torn tail first.
- I5: destination exists with different content ⇒ conflict, stop that item, never overwrite.
- I6: after crash/power loss/drive removal, `pm doctor` detects and recovers per the §6.4
  matrix (C1–C5, R1–R3, PM-LINK, Q1–Q2).
- I7: vault ⊆ album; album ⊆ finished ∪ inbox-origin.
- I9: pm never runs git.
- I10: single instance via `.pm/lock` + hTryLock; "read evidence → decide → act" must be
  entirely inside one lock acquisition.
- I11: never create a root inside a git worktree whose .gitignore doesn't cover `.pm/`; all
  `.pm/` writes go through `requireWritable` / `ensurePmSubdir`; path checks fail closed.
- Fail-closed philosophy: "can't determine" must never collapse into "no"/"absent"
  (three-state probes); ambiguous states are reported, not auto-repaired.

## What counts as a bug (report these)
1. Crashes / partial functions reachable with realistic input (head/tail/fromJust/!!/read/
   error/undefined/incomplete patterns/`div` by zero/`T.decodeUtf8` on arbitrary bytes, etc.).
2. Data-loss or data-safety violations of the invariants above (an overwrite path, an unlink
   outside the allowed set, a barrier missing/misordered, a lock scope that doesn't cover the
   decide→act span, a fail-open probe).
3. Wrong behaviour: logic errors, off-by-one, wrong comparison, wrong branch, wrong
   field/name, wrong path join/normalisation, case-folding mistakes (Windows is
   case-insensitive; extension matching is case-fold per DESIGN §3), Text/String/bytes encoding
   mistakes, time-zone/UTC mistakes, integer overflow/truncation, wrong exit code, misleading
   error message that would cause a user to take the wrong action.
4. Exception handling bugs: exceptions swallowed that hide failures, `catch` too broad (catching
   async exceptions), resource leaks (handles not closed on exception paths), `bracket` misuse.
5. Concurrency bugs: MVar/async misuse, races between check and act, deadlocks, lock not held
   where design says it must be.
6. Contract mismatches between producer and consumer: JSON field names/types between
   `Serve*.hs` and `gui/ui/*.js`; CLI flags vs docs vs parser; Rust sidecar args vs Haskell
   parser; Python scripts vs on-disk formats written by Haskell.
7. Security: the loopback API (auth token / origin checks / CSRF), path traversal, argument
   injection into subprocesses (`Pm.Subprocess`, `claude -p`, python), Tauri capability
   over-grants, XSS in the GUI (innerHTML with server data).
8. Test bugs that hide production bugs: assertions that would still pass if the feature were
   broken, wrong expected values, tests relying on ordering/timing, tests that don't exercise
   what their name says. (Only for agents assigned test files.)
9. Doc/code drift where the doc is what the user relies on (README quick-start commands that
   don't exist / flags renamed), CI workflow errors.

## What is NOT a bug (do not report these)
- "Doesn't work on Linux/macOS" — the project is Windows-only by design.
- Anything listed under README "Known limitations" or explicitly ruled in REVIEW-LOG/DESIGN §14
  (six residual malicious-same-user race windows, ReFS id truncation, no code signing, etc.).
- Style, naming, performance micro-optimisations, missing features, "could be simpler".
- Chinese comments/messages (that is the project's language).
- Hypotheticals requiring a malicious local process racing at millisecond scale.
- Speculation without a traced code path. If you cannot point at the line and describe the
  concrete input/state that triggers it, do not report it.

## Output discipline
For every finding give: file, line (1-indexed, from `grep -n`/`sed -n`), a one-line title, a
precise summary, the concrete failure scenario (input/state → wrong outcome), the evidence
(quoted code, and the callers/callees you traced), severity (critical = data loss or security;
high = crash or wrong result on a main path; medium = wrong result on an edge path; low =
misleading message/minor), and a confidence 0–1. Prefer fewer, well-evidenced findings over
many speculative ones — but do not stop early: read everything in your assignment.
