# Penpal brain (Django + Gemini)

## Setup

```bash
cd /Users/anuragsingh/Documents/GitHub/penpal
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Put your Gemini API key in .env
python manage.py migrate
python manage.py runserver 0.0.0.0:8000
```

Get a key: https://aistudio.google.com/apikey

## API

### `GET /api/health/`
`{"ok": true, "service": "penpal-brain"}`

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
