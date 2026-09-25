export const meta = {
  name: 'pm-debug-aggregate-verify',
  description: 'Deduplicate all raw PhotoManager audit findings across clusters/lenses, then verify each distinct finding once (one verifier agent per file group)',
  phases: [
    { title: 'Merge', detail: 'chunked dedup, then a final cross-chunk dedup' },
    { title: 'Verify', detail: 'one verifier per file group; a verdict per finding' },
  ],
}

const CTX = args.ctx
const chunkFiles = args.chunkFiles
const rawCount = args.rawCount

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
          sources: { type: 'array', items: { type: 'string' } },
        },
        required: ['file', 'line', 'title', 'summary', 'failure_scenario', 'evidence', 'severity', 'confidence', 'category', 'sources'],
      },
    },
  },
  required: ['findings'],
}

const VERDICTS = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'integer' },
          refuted: { type: 'boolean' },
          reasoning: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          corrected_summary: { type: 'string' },
          suggested_fix: { type: 'string' },
          fix_risk: { type: 'string', enum: ['trivial', 'small', 'moderate', 'large'] },
        },
        required: ['id', 'refuted', 'reasoning', 'severity', 'corrected_summary', 'suggested_fix', 'fix_risk'],
      },
    },
  },
  required: ['verdicts'],
}

function mergePrompt(listOrPath, stage) {
  const input = typeof listOrPath === 'string'
    ? `Input findings: a JSON array in the file ${listOrPath} — read it in full with: cat ${listOrPath}\n(each entry carries "cluster"/"lens" tags naming which auditor produced it).`
    : `Input findings (JSON array; each carries "cluster"/"lens" tags or a "sources" list naming which auditor produced it):\n${JSON.stringify(listOrPath, null, 1)}`
  return `You are deduplicating bug findings produced by independent auditors of the PhotoManager repo (Haskell CLI + Tauri GUI).
Stage: ${stage}. ${input}

Merge entries that describe the SAME defect (same root cause at the same or adjacent code site, or the same root cause
reported at two call sites) into one entry: keep the most precise file:line, the strongest evidence, the highest
confidence, the more severe rating, and set "sources" to the union of the inputs' cluster/lens tags (format
"cluster/lens") or existing sources. Keep genuinely distinct defects separate even when they sit in the same function.
Do not drop any distinct finding and do not invent new ones. Preserve the wording of failure_scenario and evidence
(concatenate when merging). Return the list.`
}

function verifyPrompt(group) {
  const items = group.map((f, i) => ({ id: i, ...f }))
  return `You are the single adversarial verifier for ${items.length} suspected bug(s) in the PhotoManager repository, all in or
around ${group[0].file}. First run: cat ${CTX}
Then read the suspected bugs (each has an "id"; return exactly one verdict per id):

${JSON.stringify(items, null, 1)}

For EACH finding do all three checks, in order, reading the real code with sed -n / cat / grep -rn (never trust the
finder's quotes):
(1) CODE: read the cited site and every caller/callee that matters. Look for a guard elsewhere, a type that makes the input
impossible, a caller that never passes such input, or a misreading. If the claim depends on a library function's behaviour
(directory, filepath, aeson, text, warp, Win32, GHC default encodings on Windows), state what it actually does.
(2) REPRO: construct one concrete scenario (exact inputs, exact on-disk state, exact command/API call) and trace it step by
step, quoting lines. Either you reach the wrong outcome (refuted=false, put the trace in reasoning) or you do not
(refuted=true, say where the trace diverges).
(3) DESIGN: grep docs/DESIGN.md, docs/DESIGN-COMMANDS.md, docs/DESIGN-GUI.md, docs/DESIGN-P8.md, docs/REVIEW-LOG*.md,
README.md lines 465-553, and the comments near the site. If the behaviour is documented as intended, a known limitation,
or was explicitly ruled on in a review round, set refuted=true and cite where. If a test in test/*.hs pins the behaviour
AND the docs agree with the test, refute. If the docs agree with the FINDER (code contradicts the documented contract), do
not refute. Refute anything that needs a malicious local process racing at millisecond scale or a non-Windows OS.

Default to refuted=true when uncertain. Rate severity honestly (critical = data loss / security; high = crash or wrong
result on a main path; medium = edge path; low = message/cosmetic). In corrected_summary restate the defect precisely as
you now understand it (or why it is not one). In suggested_fix describe the minimal safe change (or "none"); in fix_risk
rate how invasive that change is. Do not modify any file. Judge each finding on its own merits; a group may contain a mix
of real and refuted items.`
}

phase('Merge')
log(`aggregating ${rawCount} raw findings from ${chunkFiles.length} chunk files`)
const chunks = chunkFiles
const partials = await parallel(chunks.map((c, i) => () =>
  agent(mergePrompt(c, `chunk ${i + 1}/${chunks.length}`), { label: `merge:chunk${i + 1}`, phase: 'Merge', schema: MERGED, effort: 'low' })))
const flat = partials.filter(Boolean).flatMap(p => p.findings)
log(`chunk merge: ${rawCount} → ${flat.length}`)
const finalMerged = chunks.length > 1
  ? await agent(mergePrompt(flat, 'final cross-chunk pass (inputs are already partially merged; only merge true duplicates)'), { label: 'merge:final', phase: 'Merge', schema: MERGED, effort: 'low' })
  : { findings: flat }
const merged = (finalMerged && finalMerged.findings) || flat
log(`final merge: ${flat.length} → ${merged.length} distinct findings`)

phase('Verify')
// group by file, at most 4 findings per verifier so each agent's reading cost is shared
const byFile = {}
for (const f of merged) (byFile[f.file] = byFile[f.file] || []).push(f)
const groups = []
for (const file of Object.keys(byFile).sort()) {
  const fs = byFile[file].sort((a, b) => a.line - b.line)
  for (let i = 0; i < fs.length; i += 4) groups.push(fs.slice(i, i + 4))
}
log(`verifying ${merged.length} findings in ${groups.length} file groups`)
const results = await parallel(groups.map((g, gi) => () =>
  agent(verifyPrompt(g), { label: `verify:${g[0].file.split('/').pop()}:${g[0].line}${g.length > 1 ? '+' + (g.length - 1) : ''}`, phase: 'Verify', schema: VERDICTS, effort: 'high' })
    .then(r => g.map((f, i) => {
      const v = r && r.verdicts ? r.verdicts.find(x => x.id === i) : null
      return { ...f, verdict: v || { refuted: true, reasoning: 'verifier died or returned no verdict for this id', severity: f.severity, corrected_summary: '', suggested_fix: '', fix_risk: 'large' } }
    }))
))

const findings = results.filter(Boolean).flat()
const confirmed = findings.filter(f => !f.verdict.refuted)
const refuted = findings.filter(f => f.verdict.refuted)
log(`done: ${findings.length} verified, ${confirmed.length} confirmed, ${refuted.length} refuted`)
return { confirmed, refuted }
