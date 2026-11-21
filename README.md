# Penpal

One living handwriting workspace on iOS/iPadOS, backed by a **Cloudflare Python
Worker + Gemini** brain (also runnable locally as a standalone zero-Django Python
server or via Django) for conversation, maths, sketches, languages, debate, and
interactive page blocks. Penpal opens directly on the same persistent page; a
resumable interactive tour lets people try the real controls, gestures, training,
and settings. Skipping keeps a Resume tour action, completing removes it, and the
workspace badge opens the legacy page library only when it is needed.

## Capabilities

Pick who Penpal is from the on-page Penpal control bar:

- **Companion** — conversation, in a mood you choose: warm friend, playful,
  thoughtful, coach, or a custom persona described in your own words.
- **Mathematician** — solves anything step by step, from arithmetic to
  university level (algebra, calculus, linear algebra, differential
  equations, number theory, probability, proofs, olympiad problems…).
  Every answer runs through a three-stage pipeline: a SymPy computer-algebra
  engine computes exact results first where it can, Gemini writes the steps
  around them, then an independent referee pass re-derives the answer and
  triggers a rewrite if anything is off. One step per ruled line, ending in
  `Ans:`. After a solution, tappable chips offer one-tap follow-ups —
  Explain, Another way, Harder — or write "check" above your own work to
  find your first wrong line. Detail level (Answer / Compact / Full / Proof)
  switches from the on-page banner or Settings.
- **Illustrator** — ask for a sketch or diagram and watch Penpal trace it
  stroke by stroke in the same ink as your handwriting. The result is native
  PencilKit ink: erasable, lassoable, saved with the page, and removed by one
  undo. Choose Quick, Balanced, or Detailed quality from the on-page banner;
  Detailed is the default and preserves fine two-pixel features at the cost of
  a slower render. Educational and labelled diagrams are allowed; unsafe
  imagery is refused.
- **Language Partner** — practise English, Spanish, French, German, Italian or
  Portuguese. Penpal replies in that language; when it is highly confident
  about one grammar or vocabulary issue, it gently underlines the untouched
  sentence and adds a small correction beside it. Those misses feed the same
  spaced-practice queue used for maths.
- **Debate Partner** — write a claim or thesis and get the strongest
  good-faith opposing case plus one question that tests your position. It is
  explicitly labelled as another perspective, never a verified verdict or a
  grade on the writer.
- **Interactive** — ask for a live simulation, chart, or interactive widget
  and Penpal generates a sandboxed HTML/CSS/JS block embedded directly under
  your handwriting layer, with per-block domain/capability consent and
  bounded self-healing repair.
- **Arranger** — write a study topic and Penpal plans and executes multiple
  specialist sections in parallel (handwritten explanations, verified math
  examples, traced diagrams, tables, checklists, and interactive widgets),
  then composes them into a multi-column ruled-line page on device.

Always on, in any capability:

- **Instant math** — handwrite `5+5=` (or `sin(30)=`, `sqrt(144)=`, `5!=` …)
  and the answer is computed on device (math.js) and written right after your
  equals sign. Ink is read locally via geometry + your trained Math samples
  (Teach it your hand → Math), with Apple Vision only as a digit fallback.
  No cloud call for plain calculation. Fixing the Solve chip also trains
  those glyphs from your ink automatically.
- **Solve the whole page** — write out a worksheet, then ⋯ → Solve Whole Page.
  Every numbered problem is solved in one pass and each answer is written
  beside its own question, top to bottom, as the pen works down the page.
  Problems that can't be read are named rather than silently skipped.
- **Ask or box** — after writing a question, tap Ask on the Penpal bar, or
  draw a box around the ink. Both send in every mode: Companion replies,
  Language and Debate respond, Interactive builds a block, Illustrator
  sketches, and Mathematician solves from the boxed image (no OCR — it sees
  stacked fractions, exponents, roots and matrices exactly as drawn).
- **Import a photo** — Insert on Page → Import Page, pick a photo of an
  existing worksheet or notebook page, and Penpal rebuilds it: text and math
  come back as real ink in your own hand, top to bottom; anything that can't
  honestly become handwriting (a diagram, a table, a photo) is kept as a real
  image crop instead of a fake redrawing.
- **Ask about a photo** — use the camera button on the Penpal bar for an
  external textbook diagram, whiteboard or handwritten problem. The selected
  capability responds onto your page; visible maths is automatically routed
  through the image-aware solve-and-verify pipeline. This is intentionally
  separate from Import Page, which reconstructs rather than answers.

## Quick start (Cloudflare Python Worker & Local Brain)

### 1. Deploy or run as a Cloudflare Python Worker (Recommended for Production)

The backend is built natively as a **Cloudflare Python Worker** (`src/worker.py` + `wrangler.jsonc` + `pyproject.toml`), with zero Django or C++ OpenCV dependency required at runtime:

```bash
# Local Cloudflare Worker runtime (via uv + pywrangler)
cp .env.example .dev.vars   # put GEMINI_API_KEY in .dev.vars
uv run pywrangler dev

# Production deploy to Cloudflare Workers
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put PENPAL_TOKENS
uv run pywrangler deploy
```

### 2. Zero-Django standalone local server (or Django dev server)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # add GEMINI_API_KEY from https://aistudio.google.com/apikey

# Run the standalone zero-Django worker server directly on :8000
python src/worker.py

# Or run via Django (also used by the test runner)
PENPAL_DEV=1 python manage.py runserver 0.0.0.0:8000
```

The brain is **secure by default**: in production, requests must authenticate with `Authorization: Bearer <token>` or `X-Penpal-Token: <token>` matching `PENPAL_TOKENS`. Put the same token in the iOS app under **Settings → Behavior → Access token** (or bundle it for App Store release via `PENPAL_API_BASE_URL` and `PENPAL_ACCESS_TOKEN` in `penpal/Info.plist`). Rate limits default to 20 requests/minute and 500/day per token (`RATE_LIMIT_PER_MINUTE`, `RATE_LIMIT_PER_DAY`).

Tests: `PENPAL_DEV=1 python manage.py test chat` (302 tests, no network).

Then open the iOS app → write or speak on the page → Penpal replies in your handwriting or clean font.

Details: [backend/README.md](backend/README.md)
# penpal
