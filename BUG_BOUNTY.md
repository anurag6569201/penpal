# Penpal — Bug Bounty Audit

Full-application audit. Findings are ranked by **user-visible impact × likelihood**,
not by how interesting they are to fix. Each entry states the symptom the user
would report, the mechanism, and the decision taken.

Status legend: **FIXED** (done this pass) · **OPEN** (tracked in `BACKLOG.md`) ·
**ACCEPTED** (known, deliberately not fixed yet — with reasoning)

---

## P0 — Correctness of the core promise

### BB-01 · Math symbols render at random sizes and heights — **FIXED**
**Symptom:** "some symbols small, some large, some numbers below the baseline
and up, some places it invents letters, like there is no ruleset."

**Mechanism:** three independent defects compounding.

1. `GlyphAlign.normalize` returned math symbols through `rebaseWidth` **only** —
   no vertical anchoring, no size normalization. Whatever offset and scale a
   capture happened to have was kept forever. A `=` trained floating high stayed
   high; one trained small stayed small.
2. `GlyphAlign.reseat` (called at *render* time by
   `PersonalFontStore.inkStrokes(for:)`) baseline-snapped **every** glyph,
   including symbols. So even a correctly-anchored `=` was dragged onto the
   baseline at draw time. This one silently defeated any capture-side fix.
3. `MathCorrectionTrainer` derived baseline and x-height from **each symbol's own
   bounding box**. A `-` therefore reported its baseline at the dash and an
   x-height of ~3pt, normalizing to a giant floating dash. Every symbol on the
   same line claimed a different x-height.

**Fix:** an explicit ruleset replaces "trust the capture".
- `GlyphAlign.mathAnchors` — canonical `(center, height)` per symbol in unit
  space, mirroring `StrokeFont`'s fallback glyphs exactly, so trained and
  synthetic symbols are interchangeable.
- Operators are anchored by **center** (the math axis), never snapped to the
  baseline. Digits are anchored to **baseline 0 + cap height**.
- `reseat` is now character-aware and re-anchors instead of snapping.
- `MathCorrectionTrainer` measures **one baseline and one x-height per line**,
  from baseline-sitting glyphs (digits/letters) only, via median — operators are
  excluded because they don't touch the baseline and would drag it upward.
- Scale clamps are wide for symbols (0.3–3.0) and narrower for digits
  (0.42–2.4). Rationale: for *letters*, relative size is personal style and
  rescaling is destructive; a math symbol has canonical proportions, so a bad
  capture should be corrected fully **in one pass** — a partial correction also
  makes the migration non-idempotent.
- Migration `penpal.glyphsAligned.v7` repairs existing banks. **No retraining.**

**Verification:** `penpalTests/GlyphGeometryTests.swift` (PEN-01), 17 tests.
Four properties are asserted, and writing them down changed the code:

1. **Anchors agree with the built-in font** — all 26 symbols, max deviation
   0.05 against a 0.12 tolerance. This is what makes trained and synthetic
   symbols interchangeable on one line.
2. **One pass is exact** for any capture within 4× of its target.
3. **Pathological captures converge** — monotonically toward the target, never
   crossing it, so re-running the migration can only improve the bank.
4. **Rendering never drifts** — `reseat()` reads the stored glyph and is never
   written back, so 100 renders give one identical result.

Writing property 2 exposed that the original clamps (3.0 for symbols, 2.4 for
digits) were too tight: a `(` trained at a third of its height hit the clamp and
only partially corrected, which *also* made the migration non-idempotent — it
would drift a little further on every re-run. Clamps widened to 4.0/3.0 so the
correction completes in one pass. **The test found a real bug in the fix.**

---

### BB-02 · Handwriting synthesis invents glyphs inside equations — **FIXED**
**Symptom:** "some places it invents the letters."

**Mechanism:** `resolveWordGlyph` falls through *exact → fragment stitch → VAE
synthesis*. Synthesis generates a plausible-looking shape that was never written.
Charming in prose; in an equation a hallucinated glyph is a **wrong answer**
rendered in the user's own handwriting, which is the worst possible failure mode
because it looks authoritative.

**Fix:** `allowSynthesis` threaded through
`layoutSequence → inkStrokes(forWord:) → resolveWordGlyph`. Math content resolves
to real captured ink or the deterministic built-in font — never a generated
shape. Also guards the VAE cache so a cached synthetic shape can't leak to a
no-synthesis caller. Ghost steps are hardcoded `allowSynthesis: false`.

**Decision:** applied by content detection (`looksLikeMath`) rather than by
capability, so boxed math in Companion mode is covered too.

---

### BB-03 · Verifier JSON truncation drops the safety net — **FIXED**
**Symptom:** server log — `json.decoder.JSONDecodeError: Unterminated string`,
every boxed solve.

**Mechanism:** the referee ran with `max_output_tokens=300`. On a thinking model
that budget is shared with reasoning tokens, so the JSON verdict was cut
mid-string. The pipeline failed open (correct — a broken checker must never break
a reply), but that silently disabled verification entirely: **every** answer was
returned unverified while appearing to be checked.

**Fix:** JSON response mode + `thinking_budget=0` (the referee should spend
tokens on the verdict, not visible reasoning) + 1500-token ceiling, with fallback
if the model rejects those knobs. Plus a salvage parser: first `{...}` block,
then a raw-text sniff, so even a truncated verdict is usable. Solver budget
raised to 8000 for the same shared-budget reason.

**Lesson recorded:** a fail-open safety net needs its own alarm. See BACKLOG
PEN-31 (verification telemetry) — silent degradation of a correctness feature is
worse than a loud failure.

---

### BB-04 · Large boxes never detected — **FIXED**
**Symptom:** "big box drawing bro but its not recognizing."

**Mechanism:** two causes, found in sequence.
1. `enclosureRect` required the path to **hug its bounding rectangle**
   (>55% of points near an edge). Large loops are drawn lazier and rounder,
   dipping far inside the bbox, so the hug ratio collapsed. The test encoded
   "is this a neat rectangle?" when the question is "does this encircle
   something?"
2. Even once detected, `problemBox` required enclosed content to be ≥4% smaller
   than the box in **both** dimensions. A box drawn tightly around a full page of
   work fails instantly — the content nearly fills the box.

**Fix:** replaced the hug test with a **shoelace polygon area** test — does the
stroke actually encircle most of its bounds? Shape-agnostic, so page-sized
rectangles, lazy ovals and wobbly lassos all pass. Guardrails added so the looser
test doesn't over-trigger: net-turning bound (~576°) rejects spirals, and edge
coverage is **binned** (strict majority of bins per edge) so U- and C-shapes
can't fake closure with corner clusters. The content-ratio guard is deleted.

**Verification:** 15 geometry cases — page-sized closed/gapped rects, lazy
ellipses, flat ovals, blob lassos, 2- and 4-segment boxes, half-page circles and
tiny circles around `5+5` all detect; U-shapes, lines, underlines, small `o`,
zigzags, spirals and open C-curves all reject.

---

### BB-05 · Boxed problems lost strokes to OCR and containment tests — **FIXED**
**Symptom:** boxed answers occasionally solved a *different* problem than the one
drawn.

**Mechanism:** the boxed region was OCR'd to text (mangling stacked fractions and
exponents), and later the image was assembled only from strokes that individually
passed a containment test — so any misclassified stroke silently vanished from
the problem. Both stages could drop or corrupt content **without any signal to
the user**.

**Fix:** the payload is now a **crop of the region**: everything visible inside
the loop rect (padded, minus the loop stroke) is rendered to the image, including
strokes that merely pass through. No OCR anywhere in the path. The per-stroke
enclosed list survives only to drive the pulse highlight, where a mistake is
cosmetic. The model states its reading (`Reading as: …`) so a misread is visible
rather than silent.

---

## P1 — Robustness, cost, security

### BB-06 · Server trusts client-side limits — **FIXED**
**Mechanism:** `/api/chat/` and `/api/solve-math/` accepted unbounded `message`
and `history`. The iOS client caps history at 24 turns, but the server is
reachable directly. A 10MB message or a 500-turn history is a direct token-cost
blowup — a denial-of-wallet vector requiring no authentication.

**Fix:** `_clean_history()` — validated and bounded (24 turns × 4000 chars,
non-dict entries dropped, roles normalized), and `MAX_MESSAGE_CHARS = 4000`.
Verified with 5 unit checks including junk input and role normalization.

**Still open:** no rate limiting and no authentication at all — see PEN-27/PEN-28.

---

### BB-07 · Endpoints were unauthenticated and unthrottled — **FIXED** (PEN-26)
Every endpoint was `AllowAny` with no throttle. The practical risk is a bill, not
a breach: this server holds a Gemini key and spends it on request, so anyone who
could reach the host could burn the owner's quota.

**Fix:** `chat/access.py` — shared per-device tokens (constant-time comparison via
`secrets.compare_digest`, so a timing side channel can't leak them), plus
per-token rate limits (20/min, 500/day, configurable). `/api/health/` stays open
so monitoring still works. Rejected requests don't consume quota. 12 tests.

**Decision — tokens, not user accounts.** Penpal has no notion of users and
doesn't want one. A per-device token is the smallest thing that solves the actual
problem; adding accounts would be a product decision smuggled in under a security
fix.

**Decision — in-process counters, not Redis.** One small server, one process. A
dependency-free limiter that is always on beats a better one that never gets
deployed. Documented as the upgrade point if this scales out.

### BB-08 · Unsafe-by-default configuration — **FIXED** (PEN-25)
`DEBUG` defaulted to true, with `ALLOWED_HOSTS = ["*"]` and open CORS. The danger
wasn't the dev convenience — it was that the default *failed silently and
unsafely*. Forgetting one env var in production exposed everything, with no
symptom.

**Fix:** inverted. Secure by default; the permissive LAN setup is an explicit
`PENPAL_DEV=1` opt-in. Without it the server **refuses to boot** unless
`DJANGO_SECRET_KEY` and `PENPAL_TOKENS` are set. Production also enables HSTS,
secure cookies, nosniff and SSL redirect. The failure mode is now loud and
immediate (your phone can't connect) rather than silent and dangerous.

**Subtle bug found while verifying this:** the first version keyed the security
decisions off `DEBUG`. But `.env` sets `DJANGO_DEBUG=true` and `load_dotenv` puts
it in the environment — so a deployment that accidentally shipped its `.env` would
have re-enabled debug *and every insecure fallback with it*. All security
decisions now key off `DEV_MODE`, which can only be set deliberately from the
command line. This is exactly the class of silent-failure bug the audit is about,
and it was introduced by the fix for a silent-failure bug.

### BB-09 · Zero backend test coverage — **FIXED** (PEN-02)
`chat/tests.py` was 3 lines. Everything had been verified by throwaway scripts
that were never committed.

**Fix:** 92 tests, no network, mocked Gemini. Assertions are on request *shape*,
not just output strings — does the CAS hint actually reach the solver, does the
verifier actually receive the image — because BB-03 and BB-05 were both cases
where the output looked right while the pipeline was wrong.

### BB-10 · No offline queue or retry — **OPEN** (PEN-12)
`URLSession` calls have no retry and no queue. A dropped connection mid-solve
loses the request; the user sees a raw `localizedDescription` and their ink just
sits there. Handwriting is a *slow, deliberate* medium — losing work to a network
blip is disproportionately painful.

### BB-11 · `UserDefaults` used as conversation database — **FIXED** (PEN-30)
`UserDefaults` is a plist for small preferences: read into memory in full at
launch, rewritten in full on every change. Fine when a turn was a one-line note;
the Mathematician now returns up to 8000 tokens, and 24 of those was hundreds of
KB re-serialised every time the user asked anything. It also shared a store with
every user preference, so a corrupt write would have taken their settings too.

**Fix:** a single JSON file in Application Support, written off the main thread
via the existing `DebouncedSaver`. Same public API. Legacy data migrates on first
launch, and the old key is only cleared after the new file is **verified on
disk** — a crash mid-migration must not lose history. `conversationId` stays in
`UserDefaults`, which is what it's for.

### BB-15 · Sharing from dark mode exported a blank page — **FIXED** (PEN-21, new)
`shareCurrentNote` used `drawing.image(from:scale:)`, which renders onto a
**transparent** background in the **current** appearance. In dark mode the user's
ink is near-white, so the shared image was white-on-transparent — effectively
blank. Worse, it is invisible at the moment of sending: the share sheet
thumbnail looks plausible and the sender only finds out when the recipient says
the page is empty.

**Fix:** `NoteExporter` renders onto opaque white paper (including the ruled/
grid/dotted background) with a forced light trait — the same rule the vision
export already followed. PDF is now the primary format (vector, printable, what
"hand this in" expects) with a flattened image alongside for apps that won't
take one.

### BB-14 · Quadratic box detection on dense pages — **FIXED** (PEN-34, new)
Found while writing the performance budget. `detectProblemBox` scans
`count - newStart` candidates and examines every stroke on the page for each, so
cost is quadratic in that gap. `newStart` resets to 0 when a note loads and is
clamped down by undo/erase — so a user who fills a page without triggering a
reply (**exactly what worksheet mode encourages**) hit ~230k operations on every
idle pause, i.e. every time they stopped to think. Writing must never stutter;
it's the one interaction the product rests on.

**Fix:** bound the candidate scan to the 12 newest strokes — 40× less work on a
full page, and no loss of correctness, since an enclosure is always among the
newest strokes (a multi-segment box is at most 4). Regression test included.

### BB-12 · Force-unwraps in glyph pipelines — **ACCEPTED**, monitored
~20 sites (`GlyphAlign`, `InkHand`, `ScaleConsensus`, `SigmaLognormal`,
`StyleRL`). All are guarded by a preceding `nil` check or `if x != nil` in
current control flow, so none is presently reachable. They are one careless
refactor away from a crash in the *only* code path the product depends on.
Tracked as PEN-32 (defensive sweep), not treated as an active bug.

### BB-13 · `Int(NaN)` crash risk in binning code — **ACCEPTED** (verified safe)
`InkAnalyzer:328-329` and `GlyphAlign:430` divide by `b.width`/`span` before an
`Int()` cast. `Int(Double.nan)` traps in Swift. Verified every call site is
dominated by a `guard` establishing a positive divisor (`b.width > 56`,
`span > 0.04`). Safe today; noted because the guard and the use are far apart.

---

## Cross-cutting observations

**The recurring failure pattern in this codebase is *silent* degradation.**
BB-01, BB-02, BB-03 and BB-05 all share a shape: something goes wrong, the system
recovers gracefully, and the user is shown a confident, beautifully-rendered
result that is subtly incorrect. In a product whose entire promise is "this is
*your* handwriting and the answer is *verified*", a silent wrong answer costs
more trust than a visible error.

Two structural consequences, both now in the backlog:
- **PEN-31 · Verification telemetry** — every fail-open path must record that it
  fired. A safety net nobody can see isn't a safety net.
- **PEN-33 · Confidence surfacing** — when a reply is composed from synthesized
  or low-confidence ink, the UI should say so rather than presenting it
  identically to captured ink.

**Second observation: the glyph pipeline had too many opinions.** — **RESOLVED**
(PEN-06)

The suspicion was that `GlyphAlign`, `ScaleConsensus`, `InkUnity`, `HandMetrics`,
`StyleRL` and `GlyphPDM` all reserved the right to move a glyph. Auditing it
found something narrower and more actionable: only **four** components mutate
geometry (`GlyphAlign`, `ScaleConsensus.apply`, `StrokeVAE.morphToward` via
`InkUnity`, and `InkHand`'s connector insertion), and BB-01 was not a six-way
argument at all.

The real mechanism: `normalize` (capture time) and `reseat` (render time) each
carried **their own copy of the same if-chain**, and the copies disagreed. One
anchored math symbols; the other baseline-snapped them. A glyph was placed
correctly and then moved somewhere else milliseconds before being drawn, and
nothing in the codebase declared which was supposed to win.

**Fix:** one classifier (`GlyphAlign.role(for:)`) and one owner of placement and
scale (`GlyphAlign.place(_:as:settled:)`). Both entry points route through it, so
they cannot drift apart. `GlyphRole` makes the four placement rules explicit —
symbols anchored by centre, digits baseline + cap height, letters seated under
line trust, small marks untouched. No caller outside `GlyphAlign` reaches the
low-level anchors (verified).

This also silently fixed a second bug: `reseat` had been treating **digits as
letters**, so a digit nudged by a VAE morph was re-seated with lowercase rules
and lost its cap height.

**And writing the invariant found a third.** The test "capture and render must
agree" failed for digits: the clamp was too tight to correct a digit captured at
~30% of cap height in one pass, so capture left it short and render finished the
job — reintroducing exactly the capture/render disagreement PEN-06 exists to
prevent. Clamp widened to 3.5.

**The pattern worth keeping:** each of these was found by writing down a property
the system was assumed to have, not by reading code. Three passes of "fix the
silent failure" each contained their own silent failure, and only the executable
invariant caught them.
