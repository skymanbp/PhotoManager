export const meta = {
  name: 'pm-debug-find-verify',
  description: 'Exhaustive bug hunt over PhotoManager file clusters with per-cluster dedup and 3-lens adversarial verification',
  phases: [
    { title: 'Find', detail: 'two independent lenses per code cluster, one for test clusters' },
    { title: 'Merge', detail: 'dedup findings within a cluster' },
    { title: 'Verify', detail: 'three adversarial refuters per finding' },
  ],
}

const CTX = args.ctx
const clusters = args.clusters

const FINDINGS = {
  type: 'object',
  properties: {
    files_read: { type: 'array', items: { type: 'string' } },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          title: { type: 'string' },
          summary: { type: 'string' },
          failure_scenario: { type: 'string' },
          evidence: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          confidence: { type: 'number' },
          category: { type: 'string' },
        },
        required: ['file', 'line', 'title', 'summary', 'failure_scenario', 'evidence', 'severity', 'confidence', 'category'],
      },
    },
  },
  required: ['files_read', 'findings'],
}

const MERGED = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          title: { type: 'string' },
          summary: { type: 'string' },
          failure_scenario: { type: 'string' },
          evidence: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          confidence: { type: 'number' },
          category: { type: 'string' },
          merged_from: { type: 'integer' },
        },
        required: ['file', 'line', 'title', 'summary', 'failure_scenario', 'evidence', 'severity', 'confidence', 'category', 'merged_from'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean' },
    reasoning: { type: 'string' },
    severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
    corrected_summary: { type: 'string' },
    suggested_fix: { type: 'string' },
  },
  required: ['refuted', 'reasoning', 'severity', 'corrected_summary', 'suggested_fix'],
}

const LENSES = {
  code: [
    {
      key: 'crash-logic',
      prompt: `LENS: crashes, partial functions, logic errors, wrong results, exception/resource handling, concurrency.
For each function ask: what input or on-disk state makes this crash, return the wrong value, take the wrong branch, leak a handle, or swallow a failure? Check every pattern match for completeness, every list operation for empty input, every index/arithmetic for off-by-one, every path join/split for Windows semantics (drive letters, backslashes, case-insensitivity, trailing separators, UNC/\\\\?\\ prefixes), every Text/ByteString/String conversion for encoding, every catch/handle/try for over-broad or under-broad scope, every bracket/finally for exception-path cleanup, every MVar/async/lock for races.`,
    },
    {
      key: 'invariant-contract',
      prompt: `LENS: violations of the documented safety invariants and producer/consumer contract mismatches.
Read the relevant sections of docs/DESIGN.md (§2 invariants, §6 safe-write protocol incl. §6.4 recovery matrix, §6.7 concurrency) and docs/DESIGN-COMMANDS.md for the commands your files implement. Then check the code against them line by line: is every mutation preceded by a flushed Intent? Is every landing a no-replace rename? Is every "read evidence → decide → act" span inside the lock? Do three-state probes stay three-state (never collapse "cannot determine" into "absent")? Are the doctor matrix rows implemented as specified? Also trace every cross-module/cross-language contract your files participate in: JSON field names and types between Haskell producers and JS/Python/Rust consumers, CLI flag parsing vs. documented flags, on-disk formats read by one module and written by another, error codes/exit codes, and the meaning of each record field. Report any mismatch with both sides quoted.`,
    },
  ],
  test: [
    {
      key: 'test-quality',
      prompt: `LENS: test files as evidence. For each test, read the production code it exercises and determine (a) whether the assertion would still pass if the production behaviour were broken in the obvious way (weak/vacuous assertions, asserting on the wrong value, catching all exceptions, only checking "no crash"), (b) whether the expected value encoded in the test is actually correct per the design docs — a test that pins WRONG behaviour is a production bug with a test guarding it, report it as such against the production line, (c) ordering/timing/shared-state fragility given the suite runs with NumThreads 1 and a process-wide PM_CONFIG, (d) production bugs you notice while tracing the code under test (report those against the production file). Tests that are simply thin are not bugs; only report cases where a real defect could hide.`,
    },
  ],
}

const VLENSES = [
  {
    key: 'code-refuter',
    prompt: `YOUR LENS: refute by code. Read the cited file around the line AND every caller/callee that matters (grep for the function name). Look for a guard elsewhere that prevents the state, a type that makes the input impossible, a caller that never passes such input, or a misreading of the code by the finder. If the claim depends on a specific behaviour of a library function (directory, filepath, aeson, text, warp, Win32), state what that library actually does. If you cannot demonstrate that the defect is real by tracing a concrete path, set refuted=true.`,
  },
  {
    key: 'design-refuter',
    prompt: `YOUR LENS: refute by design intent and documentation. Check docs/DESIGN.md, docs/DESIGN-COMMANDS.md, docs/DESIGN-GUI.md, docs/DESIGN-P8.md, README.md section "Roadmap and known limitations", docs/REVIEW-LOG*.md (grep for the function/file/behaviour) and the code comments around the site. If the behaviour is documented as intended, listed as a known limitation, or was explicitly ruled on in a review round, set refuted=true and cite where. Also check whether an existing test in test/*.hs pins the behaviour the finder calls a bug; if the test encodes the finder's "buggy" behaviour as expected AND the docs agree with the test, refute. If the docs agree with the FINDER (the code contradicts the documented contract), do not refute.`,
  },
  {
    key: 'repro-judge',
    prompt: `YOUR LENS: concrete reproduction by tracing. Construct one concrete scenario (exact input values, exact on-disk state, exact command/API call) and trace execution through the code step by step, quoting each line you pass. Either you reach the wrong outcome the finder describes (then refuted=false, and write the trace into reasoning) or you do not (refuted=true, and say where the trace diverges from the finder's claim). Then rate severity honestly: critical = data loss / security; high = crash or wrong result on a main path; medium = edge path; low = message/cosmetic. If the only way to trigger it is a malicious local process racing at millisecond scale, or running on a non-Windows OS, refute.`,
  },
]

function finderPrompt(c, lens) {
  return `You are auditing part of the PhotoManager repository for real bugs. First run: cat ${CTX}
and follow its rules exactly (what is / is not a bug, output discipline). Then read EVERY file in your
assignment in full with sed -n / cat, in this order: ${c.files.join(', ')}.
Cluster focus: ${c.focus}

${lens.prompt}

You may (and should) read other modules when tracing callers/callees — grep -rn across src/, app/, test/,
gui/, scripts/ is allowed. Read the related docs sections named in the context file when the code claims to
implement them. Do not modify any file.

Be exhaustive: you are one of several independent auditors and the project has already survived many review
rounds, so remaining defects are subtle — edge cases, second-order interactions, error paths, and
cross-module assumptions. Spend your effort on tracing, not on summarising. List in files_read every file you
actually read in full. Report every defect you can substantiate with a concrete failure scenario; do not pad
with speculation, and do not report items from the "NOT a bug" list.`
}

function mergePrompt(c, lists) {
  return `You are deduplicating bug findings from independent auditors of the same files (${c.files.join(', ')}) of the
PhotoManager repo. Input findings (JSON):
${JSON.stringify(lists, null, 1)}

Merge findings that describe the SAME defect (same root cause at the same or adjacent code site) into one entry,
keeping the most precise file:line, the strongest evidence, the highest confidence and the more severe rating,
and set merged_from to the number of inputs merged. Keep distinct defects separate even if they are in the same
function. Do not drop any distinct finding and do not add new ones. Preserve the wording of failure_scenario
and evidence (you may concatenate). Return the merged list.`
}

function verifyPrompt(f, v) {
  return `You are an adversarial verifier for a suspected bug in the PhotoManager repository. First run: cat ${CTX}
Then read the suspected bug:

${JSON.stringify(f, null, 1)}

${v.prompt}

Rules: read the actual code with sed -n / cat / grep -n before deciding; do not trust the finder's quotes. Do not
modify any file. Default to refuted=true when uncertain. In corrected_summary, restate the defect precisely as
you now understand it (or state why it is not a defect). In suggested_fix, describe the minimal safe code change
(or "none" if refuted).`
}

const out = await pipeline(
  clusters,
  c => parallel((c.kind === 'test' ? LENSES.test : LENSES.code).map(l => () =>
    agent(finderPrompt(c, l), { label: `find:${c.key}:${l.key}`, phase: 'Find', schema: FINDINGS, effort: 'high' })
  )),
  (lists, c) => {
    const all = lists.filter(Boolean).flatMap(r => r.findings || [])
    log(`${c.key}: ${all.length} raw findings from ${lists.filter(Boolean).length} finders`)
    if (all.length === 0) return { findings: [] }
    if (lists.filter(Boolean).length === 1) return { findings: all.map(f => ({ ...f, merged_from: 1 })) }
    return agent(mergePrompt(c, all), { label: `merge:${c.key}`, phase: 'Merge', schema: MERGED, effort: 'low' })
  },
  (merged, c) => {
    const fs = (merged && merged.findings) || []
    log(`${c.key}: ${fs.length} findings after merge → verifying`)
    return parallel(fs.map(f => () =>
      parallel(VLENSES.map(v => () =>
        agent(verifyPrompt(f, v), { label: `verify:${v.key}:${f.file.split('/').pop()}:${f.line}`, phase: 'Verify', schema: VERDICT, effort: 'high' })
      )).then(votes => ({ ...f, cluster: c.key, votes: votes.map((vt, i) => ({ lens: VLENSES[i].key, ...(vt || { refuted: true, reasoning: 'verifier died', severity: f.severity, corrected_summary: '', suggested_fix: '' }) })) }))
    ))
  },
)

const findings = out.filter(Boolean).flat()
const confirmed = findings.filter(f => f.votes.filter(v => !v.refuted).length >= 2)
const refuted = findings.filter(f => f.votes.filter(v => !v.refuted).length < 2)
log(`done: ${findings.length} verified findings, ${confirmed.length} confirmed, ${refuted.length} refuted`)
return { confirmed, refuted }