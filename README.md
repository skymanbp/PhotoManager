# PhotoManager (`pm`)

[中文版 (Chinese)](README.zh.md) · This English README is the primary entry point; the Chinese version mirrors it section by section.

## Overview

A **zero-loss** photo library manager written in Haskell, plus a Rust/Tauri desktop
front-end. For one three-tier photo library (Raw originals → finished JPGs → album
favourites, plus a staging area) it provides integrity-checked indexing, sorting of
new photos, archiving, backup-drive sync, naming governance and showcase-set (vault)
distribution. **Every operation that touches photo bytes is two-phase** — first a
human-readable plan is generated, a person reads it, then `pm apply` executes it;
execution is journaled, can be reconciled afterwards (`pm doctor`) and rolled back as
a whole (`pm undo`).

> ### Positioning: personal tool, public to read
>
> This is a tool the author wrote for **one specific** photo library: directory
> layout, tier semantics and vault categories are fixed to the author's workflow. It
> is public so that it can be audited and borrowed from (above all on the question
> "how do you make a tool that touches your data worth trusting"), **not as a
> general-purpose product** — no support promise, no compatibility promise, no plan
> to adapt to other directory layouts. Issues/PRs may go unanswered for a long time.
> The CLI/GUI text and the design documents under `docs/` are in Chinese; this
> README is the English entry point.
>
> But "personal project" is no excuse for discounting safety — photos are
> non-reproducible data: pm **has no delete primitive**; the only removal mechanism
> is a quarantine area with a manifest; every write path passes an adversarial
> review gate (**recorded round by round in [docs/REVIEW-LOG.md](docs/REVIEW-LOG.md);
> the convergence verdict is whatever its last section says and is not copied
> here**), and each gate with an observable automated anchor gets a "delete it and
> exactly one test turns red" mutation case (436 tests, 0 GHC warnings); gates
> without an anchor (the GUI has no harness; concurrent interleavings have no
> deterministic observation point) are registered in REVIEW-LOG as residuals rather
> than passed off as covered.

**Design and invariants: [docs/DESIGN.md](docs/DESIGN.md)** (read §2, the eleven
invariants, first). Command details: [docs/DESIGN-COMMANDS.md](docs/DESIGN-COMMANDS.md).
GUI and the `pm serve` API: [docs/DESIGN-GUI.md](docs/DESIGN-GUI.md). P8 (Photography
as the photo SoT: album channel / AI suggestions / jpg conversion / 1.0.0 wrap-up)
rulings and design: [docs/DESIGN-P8.md](docs/DESIGN-P8.md).
Development history (P0–P8): [docs/HISTORY.md](docs/HISTORY.md).
Adversarial review archive: [docs/reviews/](docs/reviews/).

## Features and scope

- **Feature 1 · Index and overview**: `pm scan` ((size, mtime) incremental reuse +
  parallel hashing), `pm status` (four tier cards + vault diff + backup-drive lag +
  "next step"); real scale 4633 files / 459.4 GiB (measured 2026-08-26).
- **Feature 2 · Sort new photos**: `pm sort` segments a camera card / download
  directory by EXIF capture time — without arguments it only **proposes** (time cannot
  separate events; the boundaries are decided by a person); only once place and range
  are given does it generate a copy plan; **copy, not move** — the source card is never
  modified.
- **Feature 3 · Archive**: `pm import` files a staging-area event folder into
  `Raw\<year>\<event>-Raw` + `成片\<event>` (finished); `--also-album` copies the
  finished jpgs from the same source into `相册\` (album) as well (grouped with the
  finished item: if the finished copy did not land, the album copy is not executed);
  `pm album add <event folder>/<file>…` picks already-archived finished jpgs into the
  album (`pm album candidates` lists candidates and non-jpg files;
  `pm album ignore|unignore` ignores/restores unwanted candidates by content sha — a
  record in the main library's `.pm` only, zero photo changes); `pm convert
  <library-relative path>…` derives a jpg from tif/png etc. under finished/album (local
  python + Pillow; the original stays untouched in place) and lands it in the same
  finished event folder (`--also-album` also into the album) or in the album.
- **Feature 4 · Backup**: `pm backup` — main library → backup drive, one-way
  incremental; the drive is recognised by root UUID, not by drive letter; **backup
  scope = main library minus the staging area** (`To-Be-Sync'd\` is transit only and
  never enters the backup drive, ruled 2026-08-31); anything extra on the backup
  drive (EXTRA) is only reported, never touched. A USB drive that drops mid-scan or
  mid-apply is waited for and the run resumes where it stopped (1.1.2, `[backup]
  drive-wait`, default 1800 s) — finished files are never re-copied or re-hashed.
- **Feature 5 · Showcase distribution**: `pm vault status` (album ↔ vault nine-state
  diff, `--json` compatible with the legacy script), `pm vault push` (copy into a
  category + DRIFT adjudication plan + print the explicit git steps — pm never runs
  git), `pm vault hold` (a local "not syncing for now" decision that expires
  automatically when the photo changes), `pm vault note|notes` (photo record:
  category / place / coordinates / title, a local record on the main-library side,
  stored with the sha at record time and going stale when the bytes change;
  `/photo-publish` reads the `pending` entries of `notes --json` to write photos.json
  — photos.json is still outside pm's write domain), `pm vault ingest` (bulk intake:
  source → two plans, album + vault category; `_inbox→_done` and photos.json belong to
  the caller).
- **Feature 6 · Naming governance**: `pm names` unifies Raw event folders to the
  canonical naming scheme; ambiguity is not guessed, it is reported to a person.
- **Feature 7 · Duplicate handling**: `pm versions` (version groups / exact duplicates
  outside the designed redundancy, read-only), `pm dedupe` (every duplicate is an
  independent item awaiting adjudication; which copy to keep is never chosen for you).
- **Feature 8 · Staging cleanup**: `pm clean staging` only cleans staging files that
  have same-sha copies in **both** the archive tier and the backup drive; all three
  copies are re-verified at execution time.
- **Feature 9 · Safety net**: `pm trash` (list / empty the quarantine — entries to be
  deleted are always listed one by one and only `--yes` acts; clean-staging / dedupe
  records additionally get a real disk re-read confirming the copies still exist, other
  records get no copy re-verification), `pm undo` (generates a reverse plan from the
  journal; after `pm apply` it rolls back the last N completed operations), `pm doctor`
  (crash-recovery reconciliation + integrity check: by default re-verifies "the batch
  written since the last clean exit", `--deep` re-reads and re-hashes **every** index
  entry and reports entry count and mismatch count).
- **Feature 10 · GUI**: a seven-page Tauri desktop front-end (Status / Sort new photos
  / Archive / Categorise & push / Plans / Settings / Getting started) — generates
  plans, records decisions, edits configuration, AI suggestions (launches `claude -p`
  under your own account in read-only mode to look at the pictures; it only pre-fills,
  never clicks for you, and each call costs money); since 0.6.0 the Plans page can
  **execute** a saved plan directly (the same button clicked twice to confirm; the
  execution chain is the same as `pm apply`, `pm undo` works afterwards), and the
  Status page can **copy the publish commands** with one click (git command text
  generated from the two repo paths / push targets in Settings; paste it into your own
  terminal — pm never runs git).

**Explicitly out of scope**: no adaptation to other directory layouts; never runs git
(I9); `photos.json` is outside the write domain (category and coordinates are judged by
looking at the picture — pm only writes the record into the main library's `.pm`; the
projection belongs to the upstream workflow); no delete primitive (I2).

## Install (Windows x64)

> Structure note: install and quick start come before implementation details — a CLI
> tool's README should get you running first.

Download one of these from [Releases](https://github.com/skymanbp/PhotoManager/releases):

| Asset | Description |
|---|---|
| `pm-ui_<version>_x64-setup.exe` | Installer (NSIS, per-user, no administrator rights): GUI and CLI go into the same directory + a Start Menu entry |
| `pm-<version>-windows-x64.zip` | Portable: unzip and run; contains `pm.exe` (CLI) and `pm-ui.exe` (GUI) |

- **Requirements**: Windows 10/11 x64 + the WebView2 runtime (built into Win11; on
  Win10 it usually comes with Edge, and the installer launches Microsoft's official
  installer if it is missing).
- To type `pm` directly in a terminal, add the install directory to `PATH` (the
  installer does not modify `PATH`). Start the GUI from the Start Menu or with `pm ui`
  — it launches `pm serve` itself and shuts it down on exit; no manual service needed.
- Neither asset is **code-signed** (personal project, no certificate); SmartScreen will
  warn about an "unknown publisher" on first run. If that bothers you, build it yourself
  per "Build from source" below — the output is identical.
- Verification: the release notes list the SHA-256 of every asset.

## Quick start

```
pm init --main D:\Photography    # once: write config + root identity
pm scan                          # index (first full hash ~10–25 min, incremental afterwards in seconds)
pm                               # = pm status, the overview dashboard
pm ui                            # desktop GUI
```

The seven GUI pages (left-hand navigation order): **Status** (four tier cards Raw ·
finished · album · staging + vault sync diff list + backup-drive lag + "next step"; the
vault card can **copy the publish commands** with one click — the git sequence for both
repos is generated from Settings, pm never runs git), **Sort new photos** (enter the
source directory → segment by capture time → per segment enter a place / pick an
existing event → generate a copy plan; the source directory is read-only; "AI suggest
place" only pre-fills), **Archive** (staging event folder → Raw/finished, optionally
into the album at the same time; tick finished jpgs into the album — unwanted
candidates can be **ignored** (remembered by content sha, undoable any time from the
collapsed list); derive jpgs from tif/png etc. — all three only produce plans),
**Categorise & push** (album photos the
vault does not have yet: pick a category on the thumbnail, fill in place / coordinates /
title record (optionally pre-filled by "AI suggest category/place"), or pick the fourth
button "not syncing for now" → one button "save decisions and generate push plan" does
all three), **Plans** (item-by-item detail + execution-state badges — executed /
partial / not executed, folded from the journal, executed rows dimmed; plans can be
deleted one by one or pruned in one click ("clear executed"), which only removes the
regenerable plan files; since 0.6.0 pending plans can be **executed directly** — the
same button clicked twice to confirm, the execution chain is the same as `pm apply`,
`pm undo` works afterwards), **Settings** (paths and concurrency: vault /
photos.json / worker count editable, backup drive registrable, the portfolio repo path
and both repos' push targets for the publish commands customisable; changes take
effect immediately, and so does `pm config set` run in a terminal; the main library
path is read-only — it is the identity anchor, changing it means switching libraries,
that is what `pm init` is for), **Getting started**.

Command cheat sheet:

```
pm sort <source dir>              # sort new photos: segment by EXIF capture time (no args = read-only proposal)
pm sort <source> --place Atlanta --from 2026-08-01 --to 2026-08-03   # generate a copy plan
pm import [--also-album]         # staging → Raw\<year>\<event>-Raw + 成片\<event> archive plan (--also-album: finished jpgs also into the album)
pm album add 26-06-R66/_DSC9621.jpg …   # finished → album (flat, jpg only; same name / different bytes in the album → awaits adjudication)
pm album candidates              # read-only: finished jpgs not yet in the album (per event folder) + non-jpg under finished/album (→ pm convert) + ignored list
pm album ignore 26-06-R66/x.jpg …   # ignore a candidate: recorded by content sha in the main library's .pm/album-ignore.json (zero photo
                                 # changes; survives renames/moves, a re-export with new bytes reappears); unignore takes a path or sha
pm convert 成片/26-06-R66/x.tif --also-album   # non-jpg → derived jpg (Pillow, written to .pm/derived) → same finished event folder (+ album) plan; original untouched
pm backup init E:\Photography    # once: register the backup drive (recognised by UUID, not by drive letter)
pm backup                        # main library → backup drive, one-way incremental (staging To-Be-Sync'd excluded; EXTRA is only reported, never touched)
                                 # flaky USB drive (built in since 1.1.2): if the drive drops mid-scan or mid-apply, pm waits for it to come back
                                 # (up to `[backup] drive-wait`, default 1800 s), runs `doctor --repair` for the interrupted item and resumes from where it
                                 # stopped — finished files are never re-copied or re-hashed; `pm apply` and `pm doctor --backup [--deep]` behave the same
python scripts/verify_backup_dst.py --plan <id> --root E:\Photography          # media check after a big write: re-read every copy target of that plan in full, compare sha
python scripts/verify_backup_entries.py --root E:\Photography --verified-on 2026-08-26   # same, by catalog entries (e.g. only those hashed at write time, never re-read)
                                 # both wait for a dropped drive to come back and resume by themselves (shared kernel scripts/backup_verify.py)
pm clean staging                 # only cleans staging files that have same-sha copies in BOTH the archive tier and the backup drive
pm vault status                  # album ↔ vault showcase nine-state diff (six states compatible with sync_photos.py,
                                 # --json copies those six field by field; the other three: UNPUSHABLE/UNSTABLE/HELD)
pm vault push --category landscape A.jpg …   # NEW: copy into the vault category; DRIFT: adjudication plan;
                                 # prints the explicit git steps at the end (pm never runs git)
pm vault hold A.jpg …            # decide "not syncing for now": writes one local record in the main library's .pm only,
                                 # vault and photos untouched; the decision expires as soon as the photo bytes change
pm vault unhold A.jpg …          # revoke; the file goes back to NEW
pm vault note A.jpg --category landscape --location "Hallstatt, AT" --coordinates "47.556533, 13.648033"
                                 # photo record: written only to the main library's .pm/vault-notes.json (sha at record time; bytes changed → stale); --clear removes it
pm vault notes [--json]          # list records with publish state unsynced/pending/published/stale/unknown (/photo-publish consumes pending)
pm vault ingest --category landscape <absolute path…>   # bulk intake: source → main library 相册\ + vault <category>\
                                 # two plans (pm prints the execution order; apply the album one first); _inbox→_done
                                 # and photos.json are finished by the caller; pm only copies, never touches the source
pm names                         # Raw event folder unification plan, Scheme A (class-B months restored from finished; ambiguity is not guessed)
pm versions                      # version groups / exact duplicates outside the designed redundancy (read-only)
pm dedupe                        # exact duplicates → a quarantine plan adjudicated copy by copy (all await adjudication; which to keep
                                 # is not chosen for you — approve each with pm resolve --item N --unskip)

pm plan [list]                   # list plans with execution state (executed / partial / not executed — folded from the journal; plan files are never written back)
pm plan rm <id> … / pm plan prune   # delete plan files / one-click prune of executed plans (only regenerable files are removed; journal/undo unaffected)
pm apply <planId>                # execute a plan (--dry full preview / --only 1,3-5 partial execution)
pm resolve <id> --item N [--unskip]            # skip that item (default action) / --unskip restores it to pending;
                                               # dedupe plans all await adjudication — only items approved with --unskip execute on apply
pm resolve <id> --item N --keep src|dst|both   # conflict adjudication (src = the old target is quarantined first); Copy conflict items only
pm doctor                        # crash-recovery reconciliation + integrity check (read-only by default)
pm undo --last [N]               # generate a reverse plan from the journal: undo the last N completed operations (default 1; --backup/--vault select the side), then pm apply
pm config                        # print configuration and the health of every path (read-only)
pm config set --vault <dir>      # change vault / --photos-json / --workers / --drive-wait (seconds to wait for a dropped backup
                                 # drive, 0 = off) / --portfolio-dir / --vault-push / --portfolio-push
                                 # (the three publish-command settings; the main library path is read-only, use pm init)
pm serve                         # 127.0.0.1 JSON API (for the GUI; read-only by default, see --writable / --allow-apply)
```

All commands are read-only by default (they generate plans; exit 1 means "there is
something to do"); **touching photo bytes** is either `--apply` with interactive
confirmation or the two-phase `pm apply <planId>` — the only byte write that bypasses a
plan is `pm trash empty --yes` (final purge of the quarantine: itemised listing, second
confirmation, see item 1 below). A few commands write pm's own state and configuration
directly, **none of them touch photo bytes**: `pm scan`, `pm init` / `pm backup init`,
`pm config set`, `pm vault hold|unhold` / `pm vault note` (one "not syncing for now"
decision / one photo record in the main library's `.pm`), `pm convert` (phase one writes
the derived jpg into the main library's `.pm/derived` — pm's own state; landing still
goes through a plan), `pm resolve` (edits a plan), `pm doctor --repair` (also removes
derived files in `.pm/derived` that have landed, lost their source or are half-written),
`pm serve --writable` (behind the GUI: writes plans / configuration / the "not syncing
for now" list / photo records; `--allow-apply` executes plans through the very same plan
path).

## How it is built — why this tool deserves your photos

1. **No delete primitive.** The Op algebra has only Copy / Rename / Quarantine; the
   only removal mechanism is a quarantine area with a write-ahead manifest. `pm trash
   empty` is the single path in the whole program that unlinks user data: **all**
   entries are listed one by one, nothing happens without `--yes`, and before each
   deletion the path is re-verified by descending from the root level by level to
   confirm it really lies inside `.pm/trash`, then deleted on the handle; the
   `clean-staging` and `dedupe` record classes get an **additional** barrier before
   permanent deletion — a **real disk re-hash** confirming one copy each in the
   archive tier and on the backup drive, or a live copy still in the archive tier, and
   the witness must not be the object about to be deleted itself (the catalog is only
   used to locate witnesses; the evidence is that disk read — a snapshot is not
   evidence). Other records (the old bytes of `supersede:`, `undo:`,
   `rollback-displaced:`, `doctor-c5:`) are outside the barrier and are accounted for
   by the plan that generated them.
2. **Two-phase + journal + fault injection.** A plan is diff-able JSON on disk;
   execution writes its intent before landing, and after writing re-reads to verify the
   sha; the tests inject a crash at **every protocol checkpoint** and assert that doctor
   can reconcile and undo can roll back — not "it probably survived the crash", but
   proven point by point.
3. **The kernel trusts no caller.** Eleven invariants are enforced at the kernel layer:
   root identity, plan format, I11 and the trustworthiness of `.pm` are all re-checked
   inside the lock; the execution-time barrier ("the archive tier keeps at least one
   live copy") is invoked by the kernel inside the lock — **required but not supplied
   by the caller = the whole batch is rejected**, and the barrier's return value is
   checked to contain only downgrades — guarding not against malice, but against "some
   future call site forgot".
4. **`.pm` state only through the trusted access port.** After opening, the path the
   handle is bound to is looked up on the **handle** with `GetFinalPathNameByHandleW`
   (the answer comes from the very object being read or written; swapping a directory
   after the open cannot change what the handle points to); object identity is judged
   by `(volume serial, file index)`, hardlinks by the link count on the handle —
   junction / symlink / hardlink renames and other out-of-library reads and writes are
   stopped at this layer. Path-string validation (`resolveUnder`) is only a pre-filter,
   not the security boundary.
5. **Judgement and disk action are one cross-process transaction.** Every "read
   evidence → decide → write" sequence runs inside the I10 lock with the evidence taken
   inside the lock: the execution barrier, trash empty, resolve, doctor --repair,
   catalog write-back and all four read-modify-write paths of the configuration. Two
   concurrent pm processes cannot erase each other's decisions.
6. **Adversarial review gate + mutation verification (rounds and convergence verdicts
   live in REVIEW-LOG and are not copied here).** Every write path passes an independent
   review before merging (NO-GO findings are verified first-hand one by one — the
   confirmed ones are fixed, the refuted ones are recorded openly in
   [REVIEW-LOG](docs/REVIEW-LOG.md), including cases where the reviewer was right and I
   was wrong, and where my earlier documentation overstated); each load-bearing gate
   with an automated anchor gets a "delete it and exactly one test turns red" mutation —
   a green light proves the gate bears load, not that a test happened to pass by; gates
   without an anchor are registered as residuals (REVIEW-LOG, per round) and not
   passed off as mutation coverage.
7. **No unreviewed dependency on any path that decides where a photo goes.** EXIF
   reading is a first-party minimal parser: only the tags needed, uniform bounds
   checking, and if it cannot be read the decision goes to a person (fail-closed); the
   file modification time is never guessed from.
8. **The GUI never touches photos directly.** The Rust shell only does three things:
   spawn / hand over the token / kill; everything goes through `pm serve` (127.0.0.1 +
   random port + Bearer token with constant-time comparison + Host/Origin checks);
   serve has three authorisation levels: **read-only by default**; `--writable` opens
   twelve write endpoints — generate push / sort / archive / album / convert plans (writes
   `.pm/plans`; convert additionally writes derived files into `.pm/derived`, the
   originals untouched), record "not syncing for now" decisions and photo records,
   record "ignore this candidate" decisions, delete/prune plan files (only the
   regenerable `.pm/plans` files), edit configuration (main library path read-only),
   register the backup drive — **none of them touch photo bytes**; the AI suggestion endpoint `POST /api/suggest` is
   read-only level and only produces suggestions; only `--allow-apply` opens `POST
   /api/apply` (the sole endpoint that touches photo bytes; since 0.6.0 the GUI passes
   it at launch, the page confirms with two clicks; execution happens inside the serve
   process through the same load / re-verify / journal chain as the CLI).

## In practice

The daily overview on the real library (`pm status`, recorded 2026-08-26, excerpt; pm's
output is Chinese):

```
pm · 索引 2026-08-26 12:53（0 分钟前）· 4633 文件 / 459.4 GiB
  相册                94 文件      2.5 GiB
  ⚠ 暂存区 1 个事件未归档: ["26-06-R66"]
  备份盘     上次同步 2026-08-26 12:32 · 当时无滞后（EXTRA 21）
  vault      上次比对 2026-08-25 21:47 · 无差异（dup 0 · unpushable 0）
  ✓ 索引与磁盘一致
```

(index 4633 files / 459.4 GiB; album 94 files / 2.5 GiB; 1 staging event not yet
archived; backup drive last synced 2026-08-26 12:32 with no lag, EXTRA 21; vault last
compared 2026-08-25 21:47, no diff; index consistent with disk.)

A duplicate adjudication plan (`pm apply <id> --dry`; every copy awaits its own
decision, which one to keep is not chosen for you):

```
计划 20260825-224708-d24f7e (dedupe) · root D:\Photography
    0 | DECIDE    | quarantine Raw\2023\23-04-EU-Raw\202304景\A7R06770.JPG (dedupe:同 sha 2 份之一)
    1 | PENDING   | quarantine Raw\2023\23-04-EU-Raw\A7R06770.JPG (dedupe:同 sha 2 份之一)
    2 | PENDING   | quarantine Raw\2024\24-12-New York-Raw\_DSC9625.ARW (dedupe:同 sha 2 份之一)
    3 | DECIDE    | quarantine Raw\2025\25-01-Atlanta-Raw\_DSC9625.ARW (dedupe:同 sha 2 份之一)
```

Real writes that have happened (all journaled, all undoable, all after a review-gate GO
plus item-by-item user rulings):

- 220 files / 21.4 GiB first archive run, byte-exact, catalog fully verified;
- 6 Raw event folder renames (6/6 DONE, doctor 0 anomalies);
- 15 "not syncing for now" decisions (the vault repo's `git status` shows zero changes
  — the decision lives only in the main library's `.pm`);
- duplicate handling: 8 same-sha duplicates quarantined after copy-by-copy adjudication
  (sha recomputed at execution time, 16/16 independently re-verified afterwards);
- 2 ARW files recovered from the backup drive (sha checked on both source and landing
  side);
- incremental backup 1016 items / 98.5 GiB (including 2 supersede composite groups;
  regenerating the comparison afterwards yields zero: 0 new · 0 updated);
- staging cleanup 220 items / 21.4 GiB — the redundant staging copies of the "first
  archive run" batch above, quarantined after a real three-copy re-hash at generation
  time and the execution-time barrier re-check (4 items HELD: pm refused them, left for
  `pm import`).

An example of "no guessing": on a real card `pm sort` found the New York and Atlanta
events back to back — time **cannot** separate the events, so 7 consecutively numbered
ARW files landed in two event folders. Segmentation is therefore only a proposal and
the boundary is decided by a person; the place can only come from a person as well (the
camera measured zero GPS).

## Performance and quality metrics

All measured on the real library (commands and sources reproducible, not estimates):

| Metric | Measured | Source |
|---|---|---|
| Incremental scan (4633 files, 4633 reused / 0 to hash, workers=16) | 1.58 s | `pm scan` 2026-09-02 on 1.1.1, [release-notes/v1.1.1](docs/release-notes/v1.1.1.md) |
| Hash throughput (14.0 GiB across 122 ARW, workers=16) | 19.4 s | `pm scan` 2026-08-26 — the pre-1.1.1 future-mtime re-hash, which no longer happens |
| First full hash (480 GiB class) | ~10–25 min | first library build, recorded |
| Test suite (436 tests, whole suite serialised — required by process-level stdout redirection) | 10–90 s | `stack test` |
| GHC warnings | 0 | `stack build` |
| Adversarial review gate | recorded per round (NO-GO findings verified first-hand → class-level fix → focused re-review; convergence = the last section's verdict) | [REVIEW-LOG](docs/REVIEW-LOG.md) |
| Mutation verification | one mutation per load-bearing gate with an observable automated anchor, its paired test turns red (all discrimination tables of rounds 34–36 and the P7 rounds pass; gates without an anchor registered as residuals) | REVIEW-LOG convergence evidence per round |

## The three-tier library topology and "designed redundancy"

```
D:\Photography
├── Raw\<year>\<event>-Raw\   originals (ARW/DNG/JPG + sidecars)
├── 成片\<event>\             finished JPGs ("成片" = finished)
├── 相册\                     album favourites, flat (bytes frozen; "相册" = album)
├── To-Be-Sync'd\             staging area (transit before archiving)
└── .pm\                      pm's own state (index / journal / plans / quarantine)
```

The same photo appearing in both finished and album is **designed redundancy** (a
favourite is by definition a copy of a finished picture); `pm versions` / `pm dedupe`
only treat exact duplicates **within one tier** as a problem. A JPG inside a Raw event
folder is not necessarily misplaced — when the original is a JPG (straight out of the
camera / phone / lost RAW) it is the original. These criteria are written into the
tool, not left to memory. The showcase set (vault) is the album's categorised mirror
living in another git repository; the backup drive is a one-way incremental mirror of
the whole library.

## Tech stack · design philosophy

**Tech stack**: GHC 9.10.3 + stack (lts-24.46), Win32 API through cbits FFI (handle
lookup, file identity and reparse probing all need exact error codes); the GUI is Rust /
Tauri v2 + plain static HTML (no npm, no front-end build chain); tests with tasty +
fault injection + mutation verification.

**Design philosophy** (full version in [DESIGN.md](docs/DESIGN.md)):

- **No guessing** (I1): if it cannot be decided, report and hand over — ambiguous
  names, inseparable events, unreadable EXIF.
- **Plans are data**: printable, diff-able, hand-editable (apply re-runs every check).
- **Fail-closed**: evidence unobtainable = refuse, instead of carrying on with the last
  judgement.
- **Honest record**: cases where the reviewer was right and I was wrong, and where the
  documentation overstated, stay in REVIEW-LOG unerased.
- **Minimal dependencies**: no unreviewed code on any path that touches photos.

## Build from source

```bash
# CLI (GHC 9.10.3 / lts-24.46)
# --no-interleaved-output --no-dump-logs are required: with ACP=CP936 on this machine,
# stack crashes when it re-encodes dependency warnings (containing •/» characters)
# back to its own stderr (a GHC 9.10 binary printing an unencodable character to a
# non-UTF-8 pipe hits a commitBuffer crash, confirmed experimentally; GHC_CHARENC only
# affects the GHC compiler itself and does not help stack). pm itself sets UTF-8 on the
# first line of main (Pm.Win.setupConsole).
stack build --test --no-interleaved-output --no-dump-logs
stack install                    # puts pm into %APPDATA%\local\bin

# GUI + installer (Rust / Tauri v2; on Windows only the MSVC target is supported)
cp "$APPDATA/local/bin/pm.exe" gui/src-tauri/binaries/pm-x86_64-pc-windows-msvc.exe
cd gui/src-tauri
# remap the user home directory out of the cargo registry source paths — do not bake
# local machine paths into a public binary
RUSTFLAGS="--remap-path-prefix=$USERPROFILE=~" \
  cargo tauri build --target x86_64-pc-windows-msvc
# → target/x86_64-pc-windows-msvc/release/bundle/nsis/pm-ui_<version>_x64-setup.exe

# Before release: binary leak scan (user directory / %APPDATA% segments / repository
# paths, in both UTF-8 and UTF-16; all patterns derived from the environment at run
# time; any hit exits 1). Part of the release chain since 0.6.0.
V=$(awk '/^version:/{print $2}' ../../package.yaml)   # the version has one source of truth, do not copy by hand
python ../../scripts/leakscan.py binaries/pm-x86_64-pc-windows-msvc.exe \
  target/x86_64-pc-windows-msvc/release/pm-ui.exe \
  "target/x86_64-pc-windows-msvc/release/bundle/nsis/pm-ui_${V}_x64-setup.exe"
```

CI (`.github/workflows/build.yml`) runs **the same chain with the same gates** on
GitHub's windows-latest: version-consistency gate → `stack test` (including the 750-line
budget gate and the documentation-drift sentinels) → `pm --version` gate → sidecar →
tauri build (remapped) → `scripts/leakscan.py` → zip + NSIS installer + `sha256.txt`, all
produced by one run; after pushing the tag `v<version>` the release job attaches the
artifacts of **that same run** to the Release, with the SHA-256 of every asset in the
release notes (this is where the promise in the "Install" section above is kept). The
binaries in a Release are not built on the author's machine.

## Roadmap and known limitations

**Roadmap** (advanced as needed, no dates promised):

- ~~`pm vault ingest`~~ ✅ P6-D: pm only copies inside the root (two plans: album + vault
  category); `_inbox→_done` is left to the caller and printed as explicit steps; the 9
  ingest findings of review round 32 are all fixed (execution-order gate tightened, see
  REVIEW-LOG; rounds 33–37 closed the remaining "read-port fail-closed" gaps one after
  another: round 35 swept the whole set of IO read primitives, round 36 removed the I11
  existence-boolean probe, round 37 removed the collapse-to-False of the link-attribute
  probe); the convergence state of the gate is in REVIEW-LOG's last section; the first
  real use of `_inbox` only awaits the user's ruling.
- ~~Type-level closure of the barrier protocol~~ ✅ P6-A: `BarrierKind` classifier +
  barriers return only a downgrade list; upgrades / rewrites cannot be expressed in the
  types.
- ~~Handle-based landing renames~~ ✅ P6-C: all committing renames / unlinks go through
  `SetFileInformationByHandle` (binding verified before, same handle verified after,
  migration back); the name-based path is reduced to zero.
- ~~GUI execution surface~~ ✅ P7 (user ruling 2026-08-26): `pm ui` launches with
  `--allow-apply`; the Plans page executes a saved plan after two-click confirmation
  (execution chain shared with the CLI); one-click copy of the publish commands
  (`[portfolio] dir` + both repos' push targets configurable; paths and push targets are
  **re-rendered after parsing** — whitelist syntax, `/` separators, `--` before operands
  — rather than blacklist-filtered and spliced verbatim; pm never runs git); on the
  archive-vault side a new `/photo-publish` skill acts as the delegated execution entry.
- ~~Album channel / AI suggestions / jpg conversion / CI release~~ ✅ P8 → 1.0.0 (user
  ruling 2026-08-27): Photography is the photo SoT — `pm import --also-album` / `pm album
  add`, `pm convert` (Pillow-derived jpg), `pm vault note`, the seventh GUI page
  "Archive" + two AI entry points (`claude -p` read-only, pre-fill only); one shell for
  external processes, `Pm.Subprocess`; full first-party review + two Opus gate rounds +
  a single CI chain (this release's binaries are produced by GitHub Actions).
- ~~Plans page completion / candidate ignore / backup scope~~ ✅ 1.1.0 (three user
  rulings 2026-08-31): execution-state badges folded from the journal + `pm plan
  list|rm|prune` (plan files are never written back); `pm album ignore|unignore` by
  content sha (a local `.pm` decision, zero photo changes); backup scope = main
  library minus the staging area (`To-Be-Sync'd\` is transit only; narrowed at the
  single point `Pm.Diff.backupDiff`).
- ~~Future-mtime index reuse~~ ✅ 1.1.1 (real-drive review 2026-09-02): files whose
  mtime lies in the future (camera clock + preserved timestamps) were re-hashed on every
  scan (14 GiB per run on this library); `statHitStable` now also trusts a write window
  that has not opened yet — one re-hash when it does, then stable for good.
- ~~Built-in protection against a backup drive that drops mid-run~~ ✅ 1.1.2 (user ruling
  2026-09-02, after a day with 11 USB drops): `Pm.Removable` — an I/O error is judged by
  error type and by whether `.pm/root-id.json` is still readable (deterministic errors are
  rethrown unchanged; drive gone → wait up to `[backup] drive-wait`, default 1800 s;
  drive present but EINVAL-style → short pause, bounded retries). `pm backup` re-scans
  reusing everything already hashed; `pm apply` records per-item progress, runs
  `doctor --repair` between sessions so a copy interrupted between rename and Done counts
  as done, and re-runs only the unfinished groups; `pm doctor --deep` waits per entry
  instead of reporting thousands of bogus "unreadable" rows. The former
  `scripts/backup_watchdog.py` is retired; the two verify scripts stay.

**Known limitations**:

- Windows-only; directory layout and tier semantics are tailored to the author's
  library and are not meant to be generalised.
- File identity is exact on NTFS; on ReFS the 128-bit id truncated to 64 bits **can only
  reject more** (HELD / awaiting adjudication), never admit more — deliberate
  (DESIGN-COMMANDS §8.1).
- If the library sits on a mounted volume without a DOS path, handle lookup fails → the
  trusted access port rejects everything (explicit failure, not silent).
- Threat model (DESIGN §14): guards against crashes / power loss / media errors /
  concurrent benign processes; **does not** guard against millisecond-level races by a
  malicious process of the same user on the same machine — the six residual windows are
  registered one by one in §14, not hidden behind "etc.".
- No code signing.

## License

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 skymanbp.

The public repository is the complete development history (since 2026-08-27): local
machine paths in early commits were rewritten with `<vault-root>` / `<stack-root>`
placeholders (`git filter-repo`, every commit scanned with zero hits); the remote `main`
and the local one are the same lineage.
