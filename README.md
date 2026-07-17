# Penpal

Handwriting mimicry on iOS, plus a Django + Gemini brain for text conversation.

## Quick start (brain)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # add GEMINI_API_KEY from https://aistudio.google.com/apikey
python manage.py migrate
python manage.py runserver 0.0.0.0:8000
```

Then open the iOS app → type in the bottom bar → Penpal replies on the page (hand or font).

Details: [backend/README.md](backend/README.md)
# penpal
