# Penpal — Design System & UX Strategy

Owner: product/design. This is the reasoning behind every visual decision in
the app. Code lives in `penpal/DesignSystem.swift`; if this document and the
code disagree, fix the code.

---

## Who we're designing for, and what actually hurts

**Primary: the homework student (13–22, iPad + Pencil).**
Their real workflow today is paper *plus* a phone calculator *plus* a chat-AI
tab, with constant context switching. Their pain, in their words:

1. *"AI apps feel like texting a robot."* Chat bubbles, avatars, typing
   indicators — the aesthetics of messaging make schoolwork feel like a
   conversation to manage. **Our answer: there is no chat surface anywhere.
   The page is the product. Chrome recedes; ink advances.**
2. *"I don't trust the answer."* One wrong AI answer costs weeks of trust.
   **Our answer: verification is a visible state ("Solving & verifying…"),
   uncertain ink renders lighter, and the health line in Settings says
   plainly when checking is degraded.**
3. *"Everything interrupts me."* Popups and modals mid-thought are fatal on a
   writing surface. **Our answer: nothing modal while the pen is down. Cues
   are ambient — washes, ghosts, faint guides — and every animation yields to
   Reduce Motion.**
4. *"Apps for school look like dashboards."* Cold grays, data-dense panels.
   **Our answer: warm paper, stationery typography, one confident accent.**

**Secondary: the parent/tutor** on a shared iPad (hence multi-hand profiles)
who needs marking to be kind — a red ✗ makes a child hide their working, so
our marking is a pencil underline and a sentence addressed to the student.

**Tertiary: the journaller** using Companion mode; they need warmth, privacy
cues, and zero "productivity app" energy.

---

## The design language: **Warm Paper**

One metaphor, applied everywhere: *a good notebook and a fountain pen*.
Every colour, surface and motion should answer "would this belong on a desk?"

### Colour

Semantic tokens only — components never reference raw colours.

| Token          | Light                  | Dark                   | Use |
|----------------|------------------------|------------------------|-----|
| `paper`        | warm cream `#FAF7F0`   | warm charcoal `#1C1B20`| canvases, landing |
| `paperRaised`  | `#FFFFFF`              | `#26252B`              | cards, sheets |
| `inkPrimary`   | near-black `#2B2A33`   | warm white `#ECEAE4`   | text, drawn ink |
| `inkAccent`    | ink indigo `#4A4E9E`   | lifted indigo `#8B8FD9`| actions, Penpal's presence |
| `inkFaded`     | 55 % inkPrimary        | 55 % inkPrimary        | secondary text |
| `inkPositive`  | deep green `#2E6E4E`   | `#7FBFA0`              | verified, success washes |
| `inkCaution`   | amber pencil `#B07C2C` | `#D9A85C`              | offline, degraded |
| `rule`         | 12 % inkPrimary        | 14 % inkPrimary        | ruled lines, separators |

Rules: one accent per screen; success/caution appear only as *meaning*, never
decoration; dark mode is **dark paper**, not OLED black — pure black kills the
paper metaphor.

### Typography

Stationery, not software. Headings use the serif family (New York via
`.serif` design) — it reads as print on paper. Body stays SF for legibility.
The wordmark and brand moments use the existing script font
(`SnellRoundhand`), because the product's whole promise is handwriting.

Scale (Dynamic Type ready): `brand` 44 script · `titleSerif` 28 serif
semibold · `headline` 17 semibold · `body` 17 · `sub` 15 · `caption` 13.

### Shape & depth

Continuous-corner rectangles only (paper has soft corners): 10 controls /
16 cards / 22 sheets. Capsules for pill actions. **Shadows are paper
shadows** — large radius, very low opacity (`0.08`), always downward. Never
borders *and* shadows on the same element.

### Motion

Ink-native or not at all. The approved vocabulary: draw-on (strokeEnd),
fade-through (wet ink settling), the standard spring
(`response 0.35, damping 0.86`), and the write-in for text. Banned: bounces,
parallax, confetti, anything looping that isn't a thinking cue. Every
animation has a Reduce Motion branch that preserves meaning.

### Buttons

Three, and only three:
- **Primary** — filled `inkAccent` capsule, white label. One per screen, max.
- **Secondary** — tinted border capsule.
- **Quiet** — text-only, `inkFaded`. For "not now" paths, so declining is
  always visually easy — dark-pattern-free by construction.
All ≥ 48 pt tall, pressed state scales to 0.98 with a soft haptic.

---

## The landing screen

First impressions job: *this is not another AI chat app*. So the landing IS a
page — cream paper, ruled lines, and the brand written on in script as if by
hand. Copy leads with the promise, not features:

> **penpal** — *paper that thinks back.*

Three proof moments (write → box → it's solved *and checked*; replies in
*your* handwriting; mistakes become practice), then auth.

Auth decisions:
- **Google sign-in is present but dummy** (`AuthStub`), styled to spec, so
  the real SDK drops in without layout work.
- **"Use without an account" is a first-class quiet button.** A student in a
  hurry must never be blocked by auth. Position: below Google, always
  visible, never shrunk or greyed — declining auth must cost nothing.
- One privacy line under the buttons, because the audience is minors and
  their parents: "Your notes stay on this iPad."

Shown once (`@AppStorage`), skippable instantly, never re-shown after a
choice. Sign-in state is a stub flag the future SDK replaces.

---

## Applied to existing surfaces

The floating banner, follow-up chips, gesture hint and settings pick up
tokens (`inkAccent`, paper materials, standard spring) so the app reads as
one hand. Deeper settings re-organisation is deliberately deferred — tokens
first, then reflow, so we never restyle the same screen twice.
