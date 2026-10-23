# Penpal — Ink Studio

Penpal is a personal thinking space: write naturally, then get help directly on
that page. Its identity should make the handwritten work feel valuable and the
assistance feel close at hand. The core promise is “Your thoughts. Room to grow.”

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

- Welcome → Open my notebook → write. No placeholder authentication step.
  The welcome scrolls on smaller screens and with larger text.
- Library → find a thought → open it, or choose the persistent New note action.
  Empty search results offer Clear search; an empty folder invites a first note.
- Write → choose an assistant capability → Ask Penpal. The action has the
  strongest emphasis; capability and response preferences are secondary.
- Working status appears above the dock controls. On narrow windows the controls
  scroll horizontally, preserving their labels and touch targets. Follow-up
  overlays use the measured dock height to avoid covering its status row.

Library actions retain pinning, tags, folders, multi-selection, recovery, and
existing destructive-action behavior. This redesign does not migrate note data.

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
