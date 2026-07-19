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

**Milestone 4 — Ship it.** PEN-25 … PEN-28, PEN-32, PEN-33.
Release blockers, cost control, accessibility, onboarding.

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
