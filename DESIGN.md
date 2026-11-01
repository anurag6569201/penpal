# Penpal — Ink Studio

Penpal is one persistent thinking space: write naturally, then get help directly
on that page. Its identity should make the handwritten work feel valuable and
the assistance feel close at hand. The core promise is “One page. Everything
Penpal.”

## Visual language

Use warm ivory paper, a deep teal accent, and dark green-black text. Dark mode
retains a true black canvas, gently raised surfaces, and a mint accent. Semantic
colors live in `penpal/DesignSystem.swift`. Selected rows use an accent wash;
success and caution colors communicate state rather than decoration. Filled
accent buttons use the adaptive `onAccent` foreground for legible dark mode.

Serif headings and the lowercase serif wordmark bring an editorial character.
Body, labels, and actions use native system typography with Dynamic Type styles.
Cards have continuous 20-point corners; the assistant dock has 24-point corners.
Keep the page visually quiet and use whitespace to separate work from controls.

## Primary journeys

- Launch → write. Penpal always opens the same durable workspace; there is no
  welcome gate, notebook browser, folder decision, or new-note decision.
- First launch → interactive tour. The tour spotlights the real controls and
  lets people write, box, strike, calculate, visit handwriting training, and
  inspect settings on the live product. Skip restores a clean workspace and
  leaves a Resume tour button; Finish removes that button permanently and shows
  a brief, non-modal ready confirmation.
- Write → choose an assistant capability → Ask Penpal. The action has the
  strongest emphasis; capability and response preferences are secondary.
- Working status appears above the dock controls. On narrow windows the controls
  scroll horizontally, preserving their labels and touch targets. Tour steps
  automatically reveal the relevant toolbar group. Follow-up overlays use the
  measured dock height to avoid covering its status row.

The legacy note store remains the persistence and backup engine so existing
data is not deleted, but library navigation is no longer part of the primary UI.
The Penpal workspace badge opens it as an optional sidebar for existing pages.
Practice and generated work append to the workspace instead of creating files.

## Interaction

Use one restrained spring for selection and navigation. Button presses can
compress to 98%; Reduce Motion removes that transform and its animation.
Welcome content enters together with a short fade and slight vertical movement,
without delaying the primary action. The dock uses 44-point minimum controls;
primary buttons use 48 points. Avoid motion that competes with handwriting.

## Release validation still required

This is the first implementation of the new identity, not a claim of App Store
readiness. Validate real Pencil latency, long sessions, keyboard and VoiceOver
navigation, large text, split-screen, and the entire import/export journey on
hardware. Deeper tools and store assets need a coordinated follow-through. Compare task completion and user preference with the previous
experience before claiming a competitive advantage.

## Brand kit

The Ink Studio identity is packaged in `brand/penpal/brand-book.html`, with
usage rules in `brand/penpal/README.md`, portable tokens, exact generation
prompts, transparent mark, and an opaque iOS app icon. The app uses the mark as
an adaptive template through `PenBrandMark` and `PenBrandSignature`. The mark
appears in welcome, library, and settings; the asset catalog supplies the icon
and matching system accent.
