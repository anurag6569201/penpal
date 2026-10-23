# Penpal — Ink Studio brand kit

**Your thoughts. Room to grow.**

Penpal is a notebook with a companion on the page. The identity combines the
personal character of handwriting with quiet, dependable tools. It should feel
warm, thoughtful, and capable.

## Start here

Open `brand-book.html` for the visual guide. `tokens.json` is the portable token
reference; `brand.css` supplies web tokens and the signature styling.

- `assets/penpal-mark.png`: transparent 1254 × 1254 raster master.
- `assets/penpal-icon-master.png`: opaque 1254 × 1254 icon master.
- `assets/penpal-icon-1024.png`: opaque 1024 × 1024 iOS icon.
- `generation-prompts.json`: exact prompts and generation method.

The symbol is a lowercase p with a fountain-pen nib as its descender. Its open
bowl gives the mark a friendly, handwritten character. This is a raster logo,
not an editable vector master. Generated with the built-in image_gen tool;
the app icon was resized for asset-catalog packaging.

## Logo and wordmark

Use the mark with the lowercase **penpal** wordmark at brand moments. The native
wordmark uses system serif semibold with slightly tightened spacing. The web
kit uses Georgia as its fallback, so it is not an exact font match to iOS.
Keep the wordmark as live text for accessibility and sharp rendering.

Use the mark alone for app icons and compact identity. Do not replace standard
functional icons such as Search, Back, Undo, or Settings with the brand mark.
Do not stretch, rotate, add shadows, outline, or put the symbol inside a chat
bubble. Preserve the supplied optical padding. Maintain at least a quarter of
the symbol's visible width as clear space in standalone placements.

The full nib detail is intended for 40-point and larger image frames. At small
app-icon sizes the outer p/nib silhouette carries recognition; do not rely on
the fine slit for meaning. A smaller UI mark should never be the only label on
an unfamiliar action.

For light surfaces render the transparent master as solid teal; on dark
surfaces use mint or ivory. In SwiftUI the template image adopts the adaptive
accent. In the web kit the CSS mask uses the same master silhouette. The app
icon is ivory on teal with no baked-in corner mask; iOS applies the outer shape.
The base icon is supplied; separate hand-designed dark/tinted icon variants are
not part of v1.

## Palette and type

| Role | Light | Dark |
|---|---|---|
| Paper | #F7F4ED | #000000 |
| Raised surface | #FFFDF9 | #0E0D10 |
| Primary ink | #1A2B2A | #ECEAE4 |
| Brand accent | #1B5D56 | #7ECEB9 |
| On accent | #FFFFFF | #0A241F |

Use teal for actions and identity, never every label. Mint is the dark-mode
accent. Secondary text is primary ink at 68% opacity. Success and caution
retain their semantic app colors; they are not additional decorative accents.

Editorial headings: system serif. Reading text and controls: system sans.
Use native Dynamic Type styles. Use a large serif headline with short, direct
supporting text; avoid decorative script in navigation and long paragraphs.

## Voice

Calm, encouraging, specific. Address the person, not their productivity score.

- Welcome: “Your thoughts. Room to grow.”
- Entry: “Open my notebook.”
- Library: “Space for every side of you.”
- Empty notebook: “A little room to think.”
- Assistant action: “Ask Penpal.”
- Search recovery: “No matching thoughts. Try a different title or tag.”

Do not claim every answer is correct, that all processing is on-device, or that
notes are backed up unless that behavior is actually implemented. Keep errors
plain and actionable. Do not shame the user for mistakes or missed practice.

## Motion and interaction

Spring response 0.35, damping 0.86. A press can scale to 0.98; Reduce Motion
removes that transform. Keep entrances short (0.4 seconds) and never delay a
primary action. No looping brand animation while the user writes. Use 48-point
primary targets and at least 44 points for compact controls.

## Applied in the app

- `AppIcon.appiconset`: home-screen icon.
- `PenpalMark.imageset`: reusable template mark.
- `AccentColor.colorset`: matching native light and dark accents.
- `DesignSystem.swift`: exact palette plus `PenBrandMark` and `PenBrandSignature`.
- `WelcomeView.swift`: full signature.
- `FoldersSidebarView.swift`: library signature. The notes list keeps a compact navigation header with its title aligned right.
- `PenpalSettingsView.swift`: brand introduction.

Existing note content and user data are unchanged. The logo assets and native
code should be validated at small sizes, both appearances, and larger text on
hardware before final store submission.

## Writing companion

Settings → Behavior → Replies → Writing indicator offers Penpal / Dot / None.
Penpal is the default: a native fountain-nib silhouette, derived from the logo,
with its contact point anchored to the ink animation's exact positions and
clock. The nib is 24 points tall before rotation, keeps a restrained writing
angle, glides between strokes, and lifts six points while fading out over
0.22 seconds. The final lift does not delay ink completion. It is transient
renderer chrome and is not part of saved note ink.

Reduce Motion keeps the nib stationary at the first point of the reply and
removes its travel, tilt, and final lift. Instant replies show no indicator.
Cancellation removes all indicator animations immediately. “None” affects the
writing companion; progress messages remain available in the assistant dock.
