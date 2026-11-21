# Penpal Brain (Cloudflare Python Worker + Gemini)

Penpal's backend runs natively as a **Cloudflare Python Worker** (`src/worker.py`, configured by `wrangler.jsonc` and `pyproject.toml`), as a standalone zero-Django Python HTTP server (`python src/worker.py`), or via Django (`manage.py`).

## Cloudflare Python Worker Deployment

```bash
cd /Users/anuragsingh/Documents/GitHub/penpal

# 1. Local Cloudflare Worker dev server
cp .env.example .dev.vars   # set GEMINI_API_KEY=...
uv run pywrangler dev

# 2. Set production secrets on Cloudflare
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put PENPAL_TOKENS

# 3. Deploy to Cloudflare Workers
uv run pywrangler deploy
```

## Standalone Local Setup (Zero-Django or Django)

```bash
cd /Users/anuragsingh/Documents/GitHub/penpal
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Put your Gemini API key in .env

# Option A: Standalone zero-Django Worker server on 0.0.0.0:8000
python src/worker.py

# Option B: Django development server
PENPAL_DEV=1 python manage.py runserver 0.0.0.0:8000
```

Get a Gemini API key: https://aistudio.google.com/apikey

## API

### `GET /api/health/`
`{"ok": true, "service": "penpal-brain"}`

### Other Endpoints
- `POST /api/chat/` — conversational turn or text math solving (`companion`, `mathematician`, `language`, `debate`)
- `POST /api/solve-image/` — boxed handwritten math image → verified step-by-step solution
- `POST /api/solve-image/stream/` — SSE streaming math solver (`draft` → `final`/`corrected`)
- `POST /api/solve-worksheet/` — whole-page worksheet solver
- `POST /api/check-work/` — handwritten working grader
- `POST /api/practice/` — spaced-repetition practice problem generator
- `POST /api/import-page/` — physical notebook page importer
- `POST /api/illustrate/` — ink illustration planner & reference tracer
- `POST /api/trace/` — pure-CV centerline image tracer
- `POST /api/language-turn/` — target-language reply + confidence-gated correction
- `POST /api/debate-turn/` — steelmanned counterargument + testing question
- `POST /api/vision-turn/` — external photo turn across capabilities
- `POST /api/interactive/` — sandboxed interactive block generator + manifest
- `POST /api/interactive/repair/` — bounded self-healing repair for interactive blocks
- `POST /api/arrange/` — multi-specialist parallel page composition

### `POST /api/chat/`
```json
{
  "message": "I had a long day",
  "conversation_id": "optional",
  "history": [
    {"role": "user", "content": "hi"},
    {"role": "assistant", "content": "hey — what's on your mind?"}
  ]
}
```

Response:
```json
{
  "reply": "Long days leave a quiet kind of ache. What part weighed on you most?",
  "conversation_id": "optional",
  "model": "gemini-2.5-flash"
}
```

## iOS

In the app Settings → Behavior, set **API base URL** to:

- Simulator: `http://127.0.0.1:8000`
- Physical device: `http://<your-mac-lan-ip>:8000`
