# Penpal

Handwriting mimicry on iOS, plus a Django + Gemini brain for text conversation.

## Capabilities

Pick who Penpal is in Settings → Penpal (or one tap from the banner):

- **Companion** — conversation, in a mood you choose: warm friend, playful,
  thoughtful, coach, or a custom persona described in your own words.
- **Mathematician** — solves anything step by step (algebra, calculus, trig,
  word problems…), verified before it's written, one step per ruled line,
  ending in `Ans:`. Write "explain" after a solution for a deeper walkthrough.

Always on, in any capability:

- **Instant math** — handwrite `5+5=` (or `sin(30)=`, `sqrt(144)=`, `5!=` …)
  and the answer is computed on device (math.js) and written right after your
  equals sign. Ink is read locally via geometry + your trained Math samples
  (Teach it your hand → Math), with Apple Vision only as a digit fallback.
  No cloud call for plain calculation. Fixing the Solve chip also trains
  those glyphs from your ink automatically.
- **Box a problem** — draw a box or circle around any written problem and
  Penpal reads exactly what's inside, shows where it looked, and writes the
  answer below the box. Math inside a box goes to the Mathematician even in
  Companion mode.

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
