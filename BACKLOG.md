# Penpal — Product Backlog

Owner: autonomous. Decisions below are **made**, not proposed. Where I rejected a
tempting idea I've said so and why, because the rejections carry more information
than the acceptances.

---

## Product thesis

Penpal is not a chat app that happens to use handwriting, and not a calculator
that happens to be pretty. It is **paper that thinks back in your own hand**.

Three properties define it. Everything below either strengthens one or is cut:

1. **It is your hand.** Not a font. Not "handwriting-style". If a reply contains a
   glyph you never wrote, we broke the core promise.
2. **The page is the interface.** Every interaction that leaves the paper — a
   modal, a settings trip, a chat bubble — is a small failure. The box gesture is
   the model for all future interaction: draw a thing, the thing happens, the
   gesture dissolves.
3. **The answer is trustworthy.** Verified before it is written. Handwriting makes
   output look *human and casual*, which paradoxically raises the trust cost of
   being wrong — a wrong answer in your own handwriting is uniquely convincing.

**The strategic risk is #3 undermining #1.** Every trust mechanism (verification,
CAS, no-synthesis) pushes toward deterministic, checkable output; every delight
mechanism pushes toward organic, variable output. This backlog resolves that
tension explicitly rather than letting it be decided accidentally by whoever
edits `GlyphAlign` last.

---

## Now — trust and correctness (P0)

These ship before anything visual. A beautiful wrong answer is the worst product
we could build.

### PEN-01 · Golden-file rendering regression suite
Snapshot every glyph in the bank (letters, digits, all 26 math symbols) rendered
at three sizes, committed as reference geometry. CI fails on any vertical or
scale drift beyond tolerance.
**Why now:** BB-01 was three bugs that each individually "looked fine" in
isolation and only compounded on real pages. Without golden files the next
`GlyphAlign` edit re-breaks it and nobody notices for weeks.
**Done when:** deliberately shifting one anchor by 0.05 fails CI.

### PEN-02 · Backend test suite for the solve pipeline
Cover solve→verify→correct, CAS hint injection, verifier truncation salvage,
input-validation bounds, image path. Mocked Gemini client — no network in CI.
**Why now:** every one of these behaviours was validated by throwaway scripts
during development. None survives a refactor. (BB-09)

### PEN-03 · CAS coverage expansion
`mathengine` currently handles arithmetic, single-variable solve, systems and
simplification. Add: integrals/derivatives with verification, matrix ops,
limits, unit handling. Each becomes ground truth the LLM writes *around*.
**Rationale:** every problem class the CAS covers is a class where we are
*exactly* right rather than *probably* right. This is the highest-leverage
accuracy work available and it compounds with PEN-31.

### PEN-04 · Verification telemetry + visible degradation
Record every fail-open (verifier crash, CAS timeout, synthesis fallback). Surface
sustained degradation in Settings as an honest status line.
**Why:** BB-03 disabled verification entirely for an unknown period while
appearing to work. A safety net nobody can observe is not a safety net.
Formerly PEN-31; promoted to P0 — this is the lesson of the whole audit.

### PEN-05 · Confidence surfacing in rendered ink — **SHIPPED**
`InkStroke.confidence` had been populated all along (1.0 for a captured word,
0.52 for letters assembled from a char bank) and **nothing consumed it**. Every
reply looked equally certain, including ones built from shapes the user never
wrote. Ink alpha now tracks it.

**Decision — ink weight, not a badge.** An icon says "error"; lighter ink says
"not sure yet", which is what is actually true. Range is 0.72–1.0, so it reads
as pen pressure rather than illegibility: a reply must be readable first and
honest second. Confidence ≥ 0.8 (captured or fragment-stitched real ink) renders
at full strength — only genuinely synthesised glyphs lighten.

### PEN-06 · Single-owner glyph geometry model
Exactly one component owns vertical placement; exactly one owns scale. Document
it; delete or subordinate every other opinion.
**Why:** `GlyphAlign`, `ScaleConsensus`, `InkUnity`, `HandMetrics`, `StyleRL` and
`GlyphPDM` all currently reserve the right to move a glyph. BB-01 was two of them
disagreeing at capture time vs render time. This is the root-cause fix; PEN-01 is
the safety net that lets us do it without fear.

---

## Next — the page as the interface (P1)

### PEN-07 · Gesture vocabulary beyond the box — **SHIPPED** (2 of 4)
The box gesture works because it is *drawn intent*: draw a thing, it happens, it
dissolves. Two more now follow the same grammar:

- **Double underline** under your working → check it (PEN-16's proper gesture;
  it shipped behind a ⋯ menu item, which was always a placeholder)
- **Strike-through** existing ink → delete it

Both acknowledge with the trace animation, then dissolve. Gesture detection runs
**before** box detection, because a double underline is also two long thin
strokes and box detection would otherwise claim them.

**Decision — conservative detection, reversible actions.** These act on the
user's page without asking, so a false positive rewrites their work uninvited —
much worse than a gesture needing a second try. Every detector demands clear
geometry, and 13 tests are mostly *negative* cases: a single underline is
emphasis, not a command; a line passing beneath ink is an underline, not a
delete; a ruled line clipping one letter is not a strike-through; ordinary
handwriting is never a gesture. Strike-through deletion is one undo away from
being restored.

**Still open:** circle + `?` ("explain, don't solve") and arrows ("apply this to
that"). Arrows in particular need disambiguation work — a hand-drawn arrow and
a struck-through `7` are not as distinct as they sound.

### PEN-08 · Ink-native progress instead of spinners
The banner currently shows a `ProgressView` — a UIKit spinner on a page of
handwriting. Replace with ink-native beats: the analyzing pulse (exists), a pen
that hovers and taps while thinking, a nib that draws a slow ellipsis.
**Why:** the spinner is the single most out-of-place element in the app. It
announces "software is working" in a product pretending to be paper.

### PEN-09 · Answer arrival choreography
Right now the answer appears by being written. Add a beat structure: brief pause
(reading) → ghost steps fade in (working) → answer writes (conclusion) →
celebrate wash settles. Different problem classes get different rhythms — an
instant arithmetic answer should feel *fast*, a proof should feel *considered*.
**Rationale:** perceived intelligence lives almost entirely in pacing. The same
2-second wait feels attentive or broken depending on what fills it.

### PEN-10 · Handwriting-aware page layout — **SHIPPED**
The placer already avoided collisions, but assumed **every reply ran to the right
page edge**. So a two-character answer ("= 4") reserved a full line and got
pushed below anything in its way — often several lines further down than a person
would ever have written it.

Placement now takes the reply's real width, measured with the same `StrokeFont`
metrics the renderer uses, so reserved space matches inked space. Two effects:

- **Short answers go in the margin**, beside the problem, the way a person
  answers in place rather than starting a new line.
- **Long answers still flow below**, but skip only lines genuinely inside their
  own width.

**Decision — longest line, not total characters.** Replies wrap at line breaks,
so only the widest line matters; estimating from total length would make every
multi-line answer look enormous and push it needlessly down the page.

**Safe by default:** the estimate is optional. Where the reply text isn't known
yet (the placer runs before the request), behaviour is exactly as before.
Verified that no width variant places ink on top of existing work.

### PEN-11 · Live solve preview on the ruled line
As `=` is written, show the on-device CAS result ghosted ahead of the pen, before
the user lifts. Confirm by lifting; dismiss by writing on.
**Decision:** on-device only (`mathengine` parity in Swift), never a network call.
A network round-trip here would make the page feel laggy, which is fatal for a
writing surface.

### PEN-12 · Offline queue and graceful retry — **SHIPPED**
`Outbox` keeps work that failed because the device was offline, retries with
exponential backoff when the connection returns, and survives relaunch. The
banner shows the state plainly ("Offline — 2 notes saved for later").

**Why it earns its complexity:** a typed message lost to a dropped connection
costs seconds to retype; a page of worked-out algebra costs minutes and a lot of
goodwill. That asymmetry is the entire justification.

**Decision — only OFFLINE failures queue.** A 500 or a rejected token will fail
identically on retry, so queueing them just delays honest news. `isOffline` is
deliberately narrower than `isTransient` for this reason.

**Decision — bounded retries, and failures leave the queue.** Five attempts,
then the item is dropped and the user is *told*. One undeliverable item must
never block everything behind it, and a promise we've abandoned must not be
kept silently.

**Decision — stale work is discarded on load.** Anything older than a day is
dropped at launch: writing yesterday's answer onto today's page is worse than
not answering.

### PEN-13 · Error messages in the product's voice — **SHIPPED**
`PenpalError` maps every failure to something worth reading. `NSURLErrorDomain
-1009` became "No connection right now. I've kept this — I'll answer as soon as
we're back."

**The rule that shaped the copy:** on a writing surface, the first question
after any failure is *"did I lose my work?"* — so every message answers it.
Beyond that: say what happened in words a person would use, say what happens
next (one thing, not three), never blame the user, never show an error code.

Rate limiting (429) is phrased as a pace rather than a fault: "We're going a bit
fast for my brain." A cancelled request says nothing at all — the user did that
on purpose.

All five raw `localizedDescription` surfaces are gone; the only one left is
inside `APIError` itself, which is correct.

### PEN-14 · Undo that understands intent
`⌘Z` currently undoes strokes. Make it undo *actions*: one undo removes an entire
written reply, restores a dissolved box, or reverts a solve — matching what the
user thinks they did.

---

## Notebook foundation — required to compete (P0 for retention)

Penpal's intelligence is a reason to try it; a dependable notebook is the
reason to trust it with a semester. These are not a pivot to being a generic
Goodnotes clone. They are the minimum substrate that lets the page-as-interface
thesis survive real coursework.

### PEN-40 · Offline-first cloud notebook sync — iCloud or Google Drive — **PARTIALLY SHIPPED**
Move notes, folders, page assets and handwriting profiles from the single local
Documents JSON snapshot to an offline-first, versioned document store with
user-selected iCloud or Google Drive sync. Every stroke must be durable locally
before sync begins; sync is an enhancement, never a condition of writing.

**Done when:** the same notebook can be edited offline on two iPads, reconnect
without data loss, surface an understandable conflict when necessary, and be
restored after reinstall. Include an explicit export/backup path independent of
the selected provider.

**Provider design:** iCloud is the recommended default for an iPad-only user:
it needs no separate Penpal account and supports the most natural Apple-device
sync. Google Drive is an equal opt-in choice for a user who wants Google-backed
recovery or later cross-platform access. Connect it with narrowly scoped OAuth,
storing Penpal's private data in Drive's `appDataFolder`; never ask for broad
access to a student's Drive merely to sync notes.

**Decision — one active two-way provider per notebook.** A notebook's canonical
state remains local, and it has exactly one configured cloud replica: iCloud,
Google Drive, or none. Switching provider creates a verified copy then asks the
user to confirm the new source of truth. Do not let iCloud and Drive both write
to the same notebook in v1: two independent conflict engines make silent data
loss much more likely. A second provider may later be offered as one-way,
versioned backup—not bidirectional sync.

**Conflict rule:** merge at page/stroke or block level wherever possible; never
choose "last writer wins" for a whole notebook. If the app cannot merge safely,
preserve both versions and let the student decide.

**Why now:** losing a semester of notes is a terminal trust failure. The current
local-only store is a useful prototype, not a student-safe product.

**Shipped foundation:** Settings now exports one self-contained
`.penpalbackup` file (notes, drawings, folders and attachments) and restores it
as a non-destructive merge. It works without an account and is deliberately
provider-neutral: save it in Files, iCloud Drive, Google Drive or an external
disk. Direct two-way provider sync remains open.

### PEN-41 · Real notebook and page model
Replace the one-canvas-note assumption with notebooks containing ordered,
individually persistent pages. Add notebook covers, duplicate/reorder/delete
page actions, page thumbnails, and a small curated template set (ruled, grid,
dot, blank, Cornell, graph, A4/Letter).

**Decision — no infinite canvas as the default.** Coursework is pages, PDFs and
hand-ins. A conventional page makes printing, exporting, search results and
worksheet placement reliable. An infinite board can be reconsidered later as a
separate document type, not smuggled into every note.

### PEN-42 · PDF, scan and Files workflow
Import PDFs from Files/share sheet, annotate them with the same ink tools, add
and reorder blank pages, and export a flattened, printable copy without
damaging the original. Add camera document scanning with crop, perspective
correction and OCR; a scanned worksheet should become a working page, not a
dead image attachment.

**Done when:** a student can receive lecture slides in Files, mark them up,
solve a boxed question, and send a correct PDF back to their teacher.

### PEN-43 · Search every meaningful mark — **PARTIALLY SHIPPED**
Run handwriting OCR lazily and locally after an idle save; index the user's ink,
typed text, Penpal replies, PDF text, scanned-document OCR, titles, folders and
tags. Results must navigate to and visibly highlight the matching page region.

**Decision — preserve ink.** OCR is a search index and accessibility transcript,
never a destructive conversion or a reason to replace a person's handwriting.

**Shipped foundation:** the app now performs local Vision OCR after an idle
pause and indexes the user's handwriting alongside typed text, Penpal replies
and tags. Stale OCR is cancelled whenever the drawing changes. PDF/scan index
coverage and result-region highlighting remain open.

### PEN-44 · Pencil-first editing baseline
Make the writing surface feel unremarkably reliable before adding more AI:
selection/lasso, move/resize, copy/paste, eraser modes, shapes and ruler,
zoom-writing window, stable undo/redo by intent, palm rejection, and no dropped
strokes under load. Respect system Apple Pencil double-tap; add hover previews,
squeeze palette and haptics where supported, with touch-only equivalents.

**Performance contract:** ink begins immediately, stays responsive on supported
older iPads, and saves cannot visibly interrupt a stroke.

### PEN-45 · Lecture capture and replay
Record audio alongside page time, replay notes in sync with the recording, and
provide timestamped transcripts that can be searched and copied. Keep raw audio
local by default; make cloud transcription an explicit, revocable choice.

**Why it belongs here:** lectures are a core iPad-notes job. Voice input is not
a substitute for a recording a student can revisit three weeks later.

### PEN-46 · Organization that scales past one class
Add tags, favourites/pins, recents, smart folders (course, tag, date, review
due), predictable sort controls, deep links to a page, and a one-gesture quick
note. Preserve the existing simple folder hierarchy; power should be additive,
not a tax on opening a blank page.

### PEN-47 · Privacy, account and release contract
Separate Penpal identity from storage identity. Ship a real Penpal account only
when a feature genuinely needs one. iCloud sync uses the person's Apple account;
Google Drive sync uses Google OAuth solely to access the selected storage. Keep
an account-free local mode. If Google becomes a primary Penpal login rather than
only a storage connection, offer the Apple-equivalent route. Document exactly
what goes to an AI service, obtain consent before upload, provide
delete-my-data/export controls, encrypt synced content, and publish accurate App
Store privacy disclosures.

**Decision — a student must never need an account to start writing.** Account
creation is for sync and recovery, not a growth gate.

### PEN-48 · Accessibility as a complete notebook workflow
Extend PEN-32 from chrome-level polish to the complete work loop: create,
write, navigate, search, import, export and review a note with VoiceOver, Voice
Control, keyboard, Dynamic Type and reduced motion. OCR/reply transcripts must
make ink discoverable without pretending the visual page is text.

### PEN-49 · Course-long beta and quality gates
Recruit 20–30 iPad students who already use a leading notes app. Ask each to
use Penpal for one real course for two weeks. Track return-to-old-app reasons,
sync integrity, dropped-stroke rate, launch/write latency, search success,
export success and verified-solve trust.

**Exit criterion:** students can complete a course workflow—capture, annotate,
search, review, solve and submit—without returning to another app for notebook
basics. Do not use download count as a proxy for this.

## Then — new capability (P2)

### PEN-15 · Worksheet mode — **SHIPPED**
Write a page of numbered problems, then ⋯ → Solve Whole Page. Every problem is
solved in one pass and each answer written beside its own question.

**Why this is the killer feature:** it converts Penpal from a calculator you
consult into the thing you *do your homework on*.

Built: `/api/worksheet/` returning **structured per-problem** results
(`label`, `reading`, `steps`, `answer`, `box`, `readable`) rather than one block
of prose, because the app must place each answer independently. Same
solve → verify → correct discipline, but the referee reports per problem and
only flagged problems are rewritten — a wrong answer on question 2 must not
cost the user questions 1 and 3. 21 tests.

**Decision — the model returns positions.** Each problem carries a bounding box
(0–1000, top-left) that the app maps back onto the page. A malformed or
inverted box becomes `nil` and the answer flows to the bottom instead: an
answer written beside the *wrong* question is far worse than one in the margin.

**Decision — unreadable problems are named, never dropped.** A problem that
silently produces no answer looks like the app missed it. It is reported.

**Decision — boxing still means "this one problem".** A large box around several
questions could have been auto-routed to worksheet mode, but a heuristic that
sometimes reinterprets a familiar gesture is worse than an explicit action.
Boxing stays predictable; the whole-page solve is a deliberate choice.

**Resolved since:** answers now chain on the renderer's completion (PEN-09), not
a fixed delay — the 0.45s guess raced a long answer and two pens could fight over
the page. The ⋯ entry point remains; the double-underline gesture (PEN-07) covers
the grading half.

### PEN-16 · Show-your-work grading — **SHIPPED**
Write out your working, then ⋯ → Check My Working. Penpal finds the **first**
wrong line, draws a soft pencil mark under it, and writes what happened there.
This is the actual job of a tutor, and it is defensible — a generic chat
assistant cannot mark up *your* paper in place.

**Decision — first wrong line only.** Everything after a mistake is usually a
faithful continuation of a wrong value. Listing five errors when four are
consequences of the first is discouraging and useless.

**Decision — the safety property is INVERTED here.** Everywhere else in this
codebase a broken checker fails *open* (ship the answer). Grading fails *safe*:
a claimed error is double-checked by a referee whose only job is catching false
accusations, and if that referee is unavailable, breaks, or disputes the flag,
the mark is **withdrawn**. Telling a student their correct line is wrong costs
far more trust than missing a slip. A "correct" verdict skips the second call
entirely — no accusation, nothing to guard against.

**Decision — a pencil underline, not a red cross.** The mark says "look here",
not "you failed". A student who feels caught out stops showing their working,
which defeats the feature. Same reasoning drives the copy: it points at a line
("You flipped the sign when dividing by −2") and never delivers a verdict on
the person.

**Decision — an error with no reason is not shown.** A vague accusation is worse
than none; it degrades to "couldn't read this".

18 tests. `/api/check-work/`.

### PEN-17 · Graphing on the page — **SHIPPED**
Write "plot x^2" or "y = sin(x)" and Penpal draws it, in ink, with the same pen
and the same slight imprecision as its handwriting. Axes get a hand-drawn drift;
the curve carries a low-frequency wobble (not per-point noise, which would read
as a shaky hand rather than a confident sweep).

Fully on-device via `MathEvaluator` — plotting is interactive, and a network
round trip would make it feel like a document loading instead of someone
sketching. Undoable as one action, and described to VoiceOver, which cannot see
a curve.

**The bug worth recording.** The first version broke a segment only when the
expression failed to evaluate. Verification showed that's not enough: sample
points never land exactly on a pole, so `1/x` evaluates fine either side of zero
(±22 at the nearest samples) and the curve was drawn **straight through the
asymptote**. That line is a *drawn lie* — it asserts the function takes values it
never takes. Segments now also break on a value jump larger than 1.5× the
function's own interquartile spread, so the threshold adapts to sin (range 2) and
x² (range 100) alike. Verified: 1/x → 2 strokes, tan → 7, smooth curves stay 1.

### PEN-18 · Notebook search — **SHIPPED** (partial)
Search covered title and body only — so a note whose entire content is
handwriting was **unfindable**, which is exactly the case for the pages that
matter most: a worked problem, a solved worksheet. Those notes usually have an
empty title and an empty sticky note.

**The same insight as the VoiceOver work:** Penpal's reply is *text* before it is
ever drawn as ink. Capturing it at that moment costs nothing, so replies and
typed page notes are now indexed and searchable. Bounded to 100 entries per note
and de-duplicated against re-renders.

**Honestly partial:** the user's *own* handwriting still isn't searchable — that
needs OCR over stored strokes, which is expensive and deserves its own pass
(lazily, on save, off the main thread). Tags and per-subject organisation are
also still open. What shipped is the free 80%; the rest is tracked rather than
pretended.

### PEN-19 · Study sessions with spaced repetition — **SHIPPED**
The feature that changes what Penpal *is*. Everything else helps the moment a
student is stuck; this gives them a reason to open the app when they are not.
"Solve this for me" is a tool. "Here are the two things you keep getting wrong"
is a tutor.

**The signal was already there and unused.** PEN-16 grading tells us exactly when
a student got something wrong *and what the mistake was*. That beats
self-reported difficulty outright — people are poor judges of what they don't
know, and a wrong line on your own page is not an opinion. The grader now feeds
the schedule directly, and a graded practice attempt closes the loop.

Practice problems are generated against **the specific mistake**, not the general
topic: a generic "give me an algebra question" is easy and nearly useless. The
problem is written on real paper in the user's own hand, because practice should
be the same act as homework, in the same place — a separate quiz screen would
make it feel like a different app.

**Decision — no streaks, no points.** Gamifying homework produces people who
optimise the game. The reward here is the honest one: the list of things you get
wrong gets shorter, and items graduate off it after three clean reviews.

**Decision — a first failure gets an *easier* problem**, not a harder one. A
student who just got something wrong needs a win they can respect.

Simplified SM-2, verified: intervals grow 2.3 → 5.5 → 13.8 → 35.9 days and then
graduate; a wrong answer always returns tomorrow; ease is bounded [1.3, 2.8] so
it can neither spiral nor run away; one slip doesn't erase all progress.

### PEN-20 · Multi-hand profiles — **SHIPPED**
A shared iPad is the normal case, not the exotic one. Previously the second
person to open Penpal trained *over* the first person's hand, silently degrading
it — the bank had no notion of whose writing it held.

**The non-obvious part: five stores are per-hand, not one.** `personal_font`,
`ink_fragments`, `ligature_stats`, `stroke_vae` and `style_rl` are all derived
from the same training, so they must move together — a mismatched set renders one
person's letters with another person's joins. All five now resolve through
`HandProfiles.fileURL`, so adding a sixth store means one line, not five
forgotten call sites.

**Decision — notes are NOT per-hand.** A shared iPad has shared paper. The hand
is *who is writing*, not *whose notebook this is*. Splitting notes too would make
switching feel like switching accounts, which is a far bigger product claim than
"write in my handwriting".

**Decision — migration copies, never moves.** The existing trained hand becomes
profile one with its files copied into place; the originals stay put, so a failed
migration costs nothing and is recoverable.

Switching posts `handProfileDidChange`; `PersonalFontStore` drops every cache
(kerning, PDM, consensus, VAE) and rebuilds derived models. Deleting the last
hand is refused — there must always be a hand to write in.

### PEN-21 · Export and share
Export a page as PDF/image with real ink fidelity; share a solved worksheet.
Needed for the homework use case — work has to leave the app to be handed in.

### PEN-22 · Apple Pencil hover and squeeze
Hover to preview where a reply will land; squeeze (Pencil Pro) to summon the
capability switcher without leaving the page.
**Why:** hover-preview directly serves "the page is the interface" — it removes a
whole class of surprise about where ink will appear.

### PEN-23 · Voice input as an ink source — **SHIPPED**
Speak a problem; it appears on the page in your handwriting, then solves like
anything else.

**Accessibility first.** Penpal otherwise requires a stylus and fine motor
control — someone with a tremor, an injury, or no Pencil to hand simply cannot
use the core of the product. Dictation gives them the same page.

**Decision — on-device recognition where the hardware allows.** A page of
homework is personal; requiring it to be sent to a speech server to be written
down is a poor trade.

**Spoken maths is transcribed to symbols**, because "three x squared plus five"
written out as words on ruled paper is useless. `SpokenMath` handles operators,
comparisons, roots and powers.

**Two bugs caught in verification**, both of which would have produced confident
wrong maths: suffix operators left a space (`x ^2` rather than `x^2`), and
compound numbers broke apart — "one hundred" became `1 100` and "twenty five"
became `20 5`. Compounds are now collapsed before single words are substituted.
12 phrases verified end to end.

### PEN-24 · Handwriting improvement coach
We have a model of the user's hand and a critic (`StyleRL`). Show gentle
consistency feedback over time — letter-form drift, slant variance, spacing.
**Decision:** ship as opt-in, framed as observation not correction. An app that
critiques your handwriting unprompted is unpleasant; one that shows you your own
patterns when asked is delightful.

### PEN-35 · Photo import — **SHIPPED (v1)**
Photograph an existing paper page — a worksheet, a notebook page, a printed
handout — and Penpal reads it and rebuilds it on a live page: text and math
come back as real ink in the user's hand, top to bottom in reading order.

**Decision — reconstruction, not a computed answer, so no referee.** Every
other image endpoint (`solve-math`, `worksheet`) runs solve → verify →
correct because the model is computing something that can be right or wrong.
Import isn't computing anything — it's transcription, the same job
`transcribe_math` already does without a referee pass. Doubling cost with a
verification call here would be paying for a correctness guarantee this
endpoint doesn't need.

**Decision — content that can't honestly become ink stays a real photo, not
fake ink.** A diagram, a table, a photo-within-the-photo: forcing these into
handwritten glyphs would be exactly the "confident and wrong" failure this
whole backlog exists to prevent (see the product thesis at the top of this
file). Instead the model returns a crop box for anything it can't
faithfully transcribe, and the app crops the box from the **original**
photo — never a server-side re-render — and drops it in as a page block,
reusing the embedded-asset model `insertImageBlock`/`CodeBlockView` already
built for attachments. One endpoint, two honest outcomes: real ink or real
pixels, never a guess dressed up as either.

**Decision — linear layout, not positional reconstruction.** Text/math blocks
are written top to bottom in reading order (the same placement a Companion
or Mathematician reply uses), not placed at the page's original 2-D
coordinates. Exact layout preservation would need the same box/collision
placement machinery `worksheet` uses per-problem, generalized to arbitrary
content — a real v2, not a first pass. Image blocks are the one exception:
their box IS how they get cropped, not just where they'd be placed, so it's
load-bearing there in a way it isn't for ink.

**Decision — independently configurable model (`GEMINI_IMPORT_MODEL`).**
Reading a photographed page is a different job with a different cost/accuracy
curve than solving one; pointing it at a different model shouldn't touch the
solve pipeline's routing. Defaults to empty, falling back to `GEMINI_MODEL` —
same opt-in-only shape as `GEMINI_FAST_MODEL` (PEN-29).

**The bug that ate a day, and its actual cause — sub-3pt PencilKit strokes
render transparent but stay selectable.** Imported ink wrote, animated, then
turned invisible the instant the animation finished. It was fully present the
whole time: lasso Select All highlighted it, the eraser removed it, undo
restored it — it simply wasn't *painted*. The real cause is a PencilKit
rendering threshold: a programmatically-built `PKStroke` whose point `size` is
below ~3 pt is kept as selectable geometry but drawn transparent (or nearly
so). Imported prose commonly computes a tip width of 1.6–2 pt, so every glyph
landed under the floor. Companion/Mathematician replies escaped it only by
accident — their width is boosted to match the user's captured pen tip, which
happens to clear 3 pt.

The fix is one line in `pkStroke`: `minWidth = max(3, …)`. Everything else
tried first was chasing the wrong layer and is recorded here so nobody repeats
it: it is **not** a persistence bug (the strokes saved fine), **not** a
first-responder/active-canvas bug (opening the markup tray didn't help),
**not** a repaint bug (re-assigning `.drawing`, a clear-then-set, and a
sub-pixel scroll nudge all failed), and **not** a reason to detour onto the
`renderer.drawStatic` overlay (which rendered but couldn't be tray-erased).
The diagnostic that would have found it in five minutes: log each committed
stroke's `renderBounds` and tip width — the width printed `1.20`/`1.65` early
and was dismissed because Companion ink used similar numbers, before the 3 pt
threshold was known. Lesson: when ink is *selectable but invisible*, suspect
stroke geometry (size/width) before repaint or persistence.

**Decision — one bake path, selected by `purpose`.** With visibility fixed,
import no longer needs its own writer: it flows through the same
`renderReply(purpose: .pageImport)` Companion and Mathematician use, so
imported ink is native canvas ink — visible, persistent, and erasable/
selectable by the markup tray like everything else. `purpose` carries the
import-only differences (always handwriting even when replies are configured
as typed text; tighter line spacing via `importLineStep ≈ lineGap * 0.65`)
without forking the pipeline.

**Still open:** positional layout preservation (v2, above); an on-page entry
point beyond the "Insert on Page" menu (camera capture directly, rather than
picking an existing photo); telemetry for image-blocks-dropped-for-no-box, to
see in practice how often the model can't produce a usable crop.

### PEN-36 · Illustrator capability — traced, not pasted — **IMAGINATIVE V1 SHIPPED**
A third capability alongside Companion and Mathematician. Ask for a diagram —
a cell, a circuit, a map, a dragon, whatever — and watch Penpal **draw** it,
stroke by stroke, in the same pen it writes everything else with. Never a
pasted image.

**What shipped in v1:** Illustrator is selectable from the on-page capability
bar. Typed or handwritten requests go to a dedicated structured endpoint that
returns bounded, ordered outline/detail paths. The app adds slight hand-drawn
drift, reveals those paths through `HandwritingRenderer`, and bakes each one
into the page's `PKDrawing`; the whole sketch is one undo action. Long paths
use visibly drawn time-lapse pacing. Because there is not yet a trusted
reference-image source, factual, technical and labelled requests fail closed
with an honest note instead of a generated guess.

**The reference point is a specific childhood memory, and it's the right
one:** tracing paper laid over a picture with a light underneath, following
the glowing outline with a pencil. That's the effect to build toward — not
"an image appears," but "a hand is visibly tracing something," which is the
same promise the rest of the product already makes about text.

**How it actually works:** get a reference image (source depends on the
decision below), run edge/contour detection and path simplification on it to
produce an **ordered stroke list** — outline first, then interior detail, the
order a hand would actually draw in, not a raster scan — and feed that list
into the *same* `HandwritingRenderer` stroke-reveal pipeline (`strokeEnd`
animation, travelling pen-tip dot, per-stroke pacing) already used for ink.
The sketch gets the same hand-drawn imprecision PEN-17 gives graphed curves,
so it reads as the same hand, not an imported asset.

**Decision — two source paths, chosen by whether accuracy matters.** A
labeled diagram of mitosis or a circuit schematic can be *wrong*, and a wrong
diagram traced confidently is the same "confident and wrong" failure this
whole backlog exists to prevent — so factual content traces a **real**
reference image (vetted source / image search), never a generative guess.
Purely imaginative requests ("sketch a dragon", "draw what you're picturing")
have no fact to get wrong and can go through a generative image model
instead. This is the Illustrator equivalent of Mathematician's CAS
verification: right by construction where correctness is possible, honestly
generative only where it isn't.

**Decision — draw it, don't load it.** The trace has to happen at a pace that
reads as *drawing*, not a spinner with extra steps (PEN-08's whole point).
Long or detailed sketches may need to accelerate rather than fully real-time
— still visibly hand-drawn, just faster than realtime, the way a time-lapse
of a real sketch still reads as sketching.

**Still open:** the factual path — vetted reference search/upload, provenance,
and contour tracing — plus whether that vectorization belongs server-side or
on-device. The current imaginative path emits line geometry directly rather
than tracing a generated reference image; richer subjects may benefit from the
reference → contour pipeline once its latency and cost are measured.

### PEN-37 · Language partner capability — **LATIN-LANGUAGE V1 SHIPPED**
Write — or speak, via PEN-23 — in the language you're learning. Penpal
replies in that language, and corrects gently in the margin rather than
rewriting your sentence.

**What shipped in v1:** choose English, Spanish, French, German, Italian or
Brazilian Portuguese from the on-page capability bar. Handwritten recognition
uses that locale, and a dedicated structured endpoint returns a short
target-language reply plus at most one correction. Corrections only survive
above an 85% confidence gate; they softly underline the learner's untouched
ink and write a small "Try:" note beside it. Confident grammar/vocabulary
misses enter PEN-19's existing spaced-repetition queue, whose practice
generator now has a language-specific path.

**Decision — correct the ink, never overwrite it.** Your sentence stays
exactly as you wrote it; the correction is a small note beside it, the same
"pencil underline, not a red cross" discipline PEN-16 established for math.
A language learner who feels corrected-over stops writing in the language,
which defeats the feature the same way an intimidating math mark stops a
student showing their working.

**Reuses, doesn't duplicate:** PEN-19's spaced-repetition engine takes missed
vocabulary and grammar as its mistake queue instead of missed math steps —
same scheduler, same "no streaks, no points" honesty, new mistake type.

**Open question, worth an eval before real engineering time:** does grammar
correction need a translation-tuned model rather than the general chat model,
or is a well-built prompt enough? Decide with a small accuracy check, not by
assumption.

**Still open:** wire PEN-23's currently dormant microphone UI to the selected
locale; evaluate false-correction rates against a translation-tuned model; add
non-Latin scripts. Language text containing glyphs the trained stroke font
cannot represent deliberately falls back to the selected typeset reply font
rather than dropping accents or drawing question marks.

### PEN-38 · Debate / devil's advocate capability — **SHIPPED**
Write an argument or an essay position. Penpal writes back the strongest
good-faith counter-argument, in the margin — not a verdict on whether you're
right.

**What shipped:** Debate Partner accepts typed or handwritten claims through a
dedicated structured endpoint. It writes a concise steelmanned counterargument
and one testing question as native ink below the claim. Every response begins
`Another view:` and the API reports the `perspective` trust tier; it never
uses Mathematician's verified language, scores the argument, or grades the
writer. Double-underlining in this mode cannot accidentally invoke the math
grader.

**Why this is a real gap, not a nice-to-have:** every other capability is
STEM-shaped (solve, check, graph, practice). This is the first thing in the
app for essay and critical-thinking homework, which is most of what
humanities subjects actually assign.

**Decision — argue the position, never grade the person.** Same tone rule as
PEN-16, aimed at a different target: the counter-argument attacks the *claim*
("this assumes X, but Y complicates it"), never the writer. No score, no
"weak argument" — that's a verdict, and this capability doesn't deliver
verdicts.

**Decision — labelled as a lower trust tier than Mathematician or
Scientist-if-built.** A counter-argument is useful even when it isn't
independently verified — the point is exposure to a real opposing view, not
a checked fact. It should never be dressed up with the same "verified"
visual language (PEN-04's honest-degradation line) that math and CAS-backed
answers get, because it isn't the same kind of claim.

### PEN-39 · Vision capability — reading what the camera sees — **V1 SHIPPED**
Point the camera at something that **isn't your own page** — a textbook
diagram, a whiteboard, a friend's handwritten problem — and Penpal reads it
and responds directly onto *your* page, in your hand.

**Not the same job as PEN-35 Photo Import — worth keeping distinct.** Photo
Import reconstructs a page of your *own* prior work: transcription, no
referee, because there's nothing to compute. Vision capability looks at
something external and *responds* to it — explains a diagram, solves a
problem someone else wrote, answers "what is this" — which is computing a
claim about content the app didn't produce. That routes through the same
solve → verify → correct discipline as everything else that can be right or
wrong (PEN-01/PEN-16's territory), not the transcription path. A hallucinated
reading of someone else's diagram, written confidently in your own hand, is
exactly the failure mode this backlog is built to prevent — arguably a worse
one than usual, since the source material isn't even yours to double-check
against memory.

**Decision — input modality, not another capability tab.** The on-page Penpal
bar now offers Take Photo / Choose Photo inside Companion, Mathematician,
Language Partner and Debate Partner. The selected capability controls the
response. Mathematician photos run through the existing image-aware
solve → verify → correct pipeline; Companion first classifies visible maths
and promotes it to that same checked path. Language and Debate preserve their
confidence/trust contracts. Replies land as normal page ink. Illustrator is
disabled for photo Q&A until its vetted-reference tracing path exists.

This remains deliberately separate from PEN-35: **Import Page** reconstructs
your old page without computing a claim; the camera button inspects external
content and responds. Camera uploads are orientation-normalised, reduced to a
2048-pixel long edge, and kept under the backend's independent 6 MiB cap.

**Still open:** an optional spoken/typed question before upload (v1 uses a
capability-specific default and supports written follow-up), source thumbnails,
and richer positional responses for multi-part textbook diagrams.

---

## Platform and release (P3)

### PEN-25 · Secure-by-default backend configuration
Invert the defaults: `DEBUG=False`, explicit `ALLOWED_HOSTS`, scoped CORS, with
`PENPAL_DEV=1` opting into the permissive LAN setup. **Release blocker.** (BB-08)

### PEN-26 · Authentication and rate limiting
Per-device token, per-token throttling and daily quota. **Release blocker** —
currently anyone who can reach the host spends the owner's Gemini quota. (BB-07)

### PEN-27 · Cost controls and observability
Token accounting per request, budget ceilings, structured logging of latency and
verification outcomes. Multi-call verification roughly doubled per-solve cost;
right now that is unmeasured.

### PEN-28 · Streamed replies — **SHIPPED**
The solution now forms visibly while it is being produced, instead of the page
sitting still until the whole response arrives.

**The original plan was wrong and got changed.** This backlog said: stream the
draft, and correct visibly if the referee objects. That works for a chat bubble
and fails for paper — **ink cannot be unwritten.** A streamed draft the referee
later rejects would leave a wrong answer on the page with a correction awkwardly
beside it, which is precisely the "confident and wrong" failure the whole audit
was about.

**What shipped instead** reuses the ghost layer built for the live preview
(PEN-11). The stream renders into the ghost — faint, visibly provisional — and
real ink is committed only on `final` or `corrected`. The user gets the
responsiveness of streaming; the product never writes anything it hasn't checked.
A rejected draft is replaced silently rather than crossed out.

The protocol makes this explicit rather than relying on client discipline:
`draft` events are typed differently from `final` and `corrected`, so treating a
draft as authoritative would be a visible mistake in the code. A dropped
connection clears the ghost and says so — it never inks an unverified draft.

11 tests, including the guarantee that a rejected draft is **never** emitted as
`final`.

### PEN-29 · Model routing by problem class
Cheap fast model for arithmetic (or pure CAS, no LLM at all), strong model for
proofs. `mathengine` already identifies many classes deterministically.

### PEN-30 · Conversation storage off `UserDefaults`
Move to a real store (SQLite/Core Data). Currently up to 24 turns of long
solutions load wholesale into memory at launch. (BB-11)

### PEN-31 · Defensive sweep of force-unwraps
~20 sites in the glyph pipeline, all currently guarded by control flow, none
structurally safe. One refactor from crashing the app's only critical path.
(BB-12)

### PEN-32 · Accessibility pass
Dynamic Type in all chrome, VoiceOver labels for ink content (reply text is known
— it should be readable), sufficient contrast for ink washes, reduced-motion
honouring for every animation added above.
**Non-negotiable, not optional polish.** Reduced-motion in particular is a
correctness issue for the animation work in P1.

### PEN-33 · Onboarding that teaches the gestures
The box gesture is the product's best idea and is currently undiscoverable. Teach
it in the first session, on the page, by having the user draw one.

### PEN-34 · Performance budget for large pages
Full-page ink, 2560px image renders and stroke-heavy replies on older iPads need
a measured budget: frame time while writing, memory during image export.

---

## Sequencing

**Milestone 0 — Keep it.** PEN-40, PEN-41, PEN-42, PEN-43, PEN-44, PEN-47.
Before calling Penpal a competitor, make it safe to use as a daily notebook:
durable local writes, sync and recovery, pages and PDFs, handwriting search,
Pencil-grade editing, and honest data controls. PEN-45 and PEN-46 follow this
foundation; PEN-48 and PEN-49 are release gates rather than optional polish.

**Milestone 1 — Trust it.** PEN-01 … PEN-06.
Nothing visual ships until rendering is regression-locked and verification is
observable. The audit showed we cannot currently tell whether our correctness
features are running.

**Milestone 2 — Feel it.** PEN-07 … PEN-14.
The page becomes the interface. Spinners die. Gestures multiply. Errors speak
the product's language.

**Milestone 3 — Live in it.** PEN-15, PEN-16, PEN-18, PEN-21.
Worksheet mode plus grading plus export turns Penpal into where homework
actually happens.

**Milestone 4 — Ship it.** PEN-25 … PEN-28, PEN-32, PEN-33, PEN-48, PEN-49.
Release blockers, cost control, accessible full-workflow use, onboarding and a
course-long student beta.

Everything else is opportunistic.

---

## Explicitly rejected

**A chat transcript view.** Requested by instinct in every notes-adjacent app.
Rejected: it would give users a "normal" surface to retreat to, and the page
would slowly become a novelty. If the page is not sufficient, we fix the page.

**Real-time collaboration.** Expensive, and the product's emotional core is
solitary — it's a *penpal*, one hand and one page. Revisit only if teachers
adopt worksheet mode and ask for it specifically.

**A general-purpose AI assistant mode.** The Companion capability is deliberately
scoped to short, warm notes. Widening it to "ask anything" makes us a worse
version of an app the user already has, and dilutes the one thing we do
uniquely well.

**Fancier fake handwriting variation.** Tempting after every "it looks too
uniform" comment. But BB-01 and BB-02 both trace to systems that moved ink
around for aesthetic reasons and fought each other. Variation must come from
*real captured variation* (more samples, PDM sampling of the true distribution),
never from added noise. This is the resolution of the trust-vs-delight tension:
**delight comes from more of the user's real hand, not from more randomness.**
