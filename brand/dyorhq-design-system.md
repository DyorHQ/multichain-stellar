# DyorHQ design system

Your All-in-One Crypto App

## Direction

DyorHQ combines an editorial wordmark with a precise, restrained trading interface. The serif logo is the identifying element. Prices, forms, and navigation remain functional rather than decorative.

The sole approved identity is the editorial wordmark and interlocking D/Q monogram selected on 2026-09-09. The visual reference is `dyorhq-identity.png`. Older logos, prompts and palette directions are superseded and must not be restored from git history or build output.

## Sources of truth

- This document and the assets beside it.
- The iOS implementation: `ios/DyorHQ/Design/Theme.swift` (colour tokens) and `ios/DyorHQ/Design/Components.swift`
  (shared components), with the asset catalog in `ios/DyorHQ/Resources/Assets.xcassets`.

DyorHQ is an iPhone app; the web app (and its CSS tokens and components) was removed on 2026-09-27. This document
keeps the brand rules; the Swift files above are where they are implemented.

Do not declare new brand colors or font stacks in feature code. Extend the token source when a genuinely new semantic role is needed.

## Identity

Use `dyorhq-wordmark.png` for the wordmark and `dyorhq-monogram.png` for the D/Q app icon. Both derive from the approved board. The shared component displays the wordmark without redrawing its letters. Black on light, near-white on dark. Do not recolor individual letters, distort proportions or add a glow. iOS mirrors these assets in its asset catalog; the wordmark uses template rendering for theme adaptation.

Keep at least one lowercase letter-height of surrounding clear space. Use the wordmark at 104pt wide or above in the interface. The tagline is separate live text, at least 12pt, and omitted where space is insufficient. Use the D/Q monogram for the app icon and other small sizes. An outlined vector master and optical small-size refinement remain future production assets; the supplied assets are raster artwork. The board's sample watchlist values are illustrative, not live data; its typography specimens are visual approximations.

## Typography

| Role | Family | Weight | Usage |
| --- | --- | --- | --- |
| Editorial | Bodoni Moda | 400, 500 | Brand and editorial headings, never transaction figures |
| Interface | Manrope | 400, 500, 600 | Body, labels, navigation, buttons, screen headings |
| Numeric | IBM Plex Mono | 400, 500 | Prices, balances, amounts, order books, addresses |

The wordmark is original artwork, not Bodoni Moda text. Bodoni Moda complements its thick-thin serif character. Manrope provides open, readable interface lettering. IBM Plex Mono keeps changing figures aligned.

These families describe the brand in marketing and print. The iPhone app follows Apple's system type (SF Pro through
Dynamic Type text styles, with tabular figures for amounts); the only bundled font is the Google Sans subset that
Google's sign-in branding requires for the "Continue with Google" button.

Scale: 12pt metadata, 14pt labels, 16pt body, 18pt lead, 24pt section titles, 40–72pt editorial display. Dense financial rows may use 13–14pt figures. Text should not be less than 12pt. Use sentence case and normal tracking in controls. Financial data uses tabular figures. Never apply a serif to a numeric amount or switch fonts on a single emphasized word.

## Color

| Token role | Light | Dark |
| --- | --- | --- |
| Canvas | #F7F7F5 | #18191B |
| Surface | #FCFCFA | #242528 |
| Inset | #EFEFED | #2D2E32 |
| Primary text | #18191B | #F7F7F5 |
| Secondary text | #606165 | #B0B1B6 |
| Supporting text | #6B6C70 | #A3A4AA |
| Control boundary | #85868B | #878990 |
| Positive | #126A4B | #77D8AC |
| Negative | #AD3047 | #F496AA |
| Attention | #775812 | #E4C67D |

Primary actions invert the text/canvas pair. Do not introduce a decorative accent. Positive and negative always have text or sign information, not color alone. Warnings use attention colors. Asset identifiers (token logos and colors) are independent of action colors. Token colors are illustrative identifiers, not certified company brand assets.

The whole app shares one theme. The system appearance is the default; an explicit light or dark choice persists on the device. No screen-level theme flips.

## Shape, spacing and layers

Spacing uses a 4pt base with 8, 12, 16, 20, 24, 32, 40, 48, 64pt steps. Exceptions are limited to optical type adjustments and icon geometry.

Radii: 6pt badges, 8pt compact controls, 12pt fields/buttons, 16pt cards, 24pt sheets. Circular identity avatars and pill-shaped floating navigation are documented exceptions.

Layer order: chrome, then menus, sheets and toasts. Cards use a border and minimal shadow. Never put blur behind prices, order books, or forms.

## Components and states

### Buttons

Variants: primary (the inverted text/canvas pair), secondary, ghost, and tone-up / tone-down for trade direction only. Sizes: regular, small, big.

- Default: solid fill, a one-line label, minimum 44pt target.
- Pressed: slight scale feedback, no outer glow.
- Disabled: subdued solid surface, actually disabled.
- Busy: disabled plus a progress indicator, with the status text kept meaningful.

### Segmented choices

A labeled group of toggles whose selected state is exposed to VoiceOver, not a tab widget without panels. Use buy/sell variants only for trade-direction decisions.

### Inputs

Visible label above every input. Helper text or error below. An invalid input has a contrasting boundary and a specific error message. A placeholder is not a label. Error example: "Enter 2 to 10 letters, with no spaces or numbers." This reference example does not change the launchpad contract's ticker rules.

### Toggles and sliders

System toggles and sliders with a descriptive name and the current value shown next to them (the leverage ruler shows its value while dragging).

### Feedback

Empty states explain what will populate the surface. Loading placeholders reserve dimensions. Success, errors, and action results use specific language. Never show a simulated quote as live or imply that a demonstration submitted a transaction. Every write ends in a confirmation sheet that shows exactly what will be sent.

## Motion and materials

140ms for tactile feedback, 220ms for selection, 320ms for panels. Transitions use opacity and transform where possible. Loading may animate while a task is pending, but decorative loops are removed. Reduce Motion removes animation.

Translucent material is restricted to floating navigation. Order details and inputs remain opaque. Reduce Transparency replaces the material with an opaque surface.

## Layout

The app uses the full screen with safe-area insets and every surface stays scrollable. Labels are not hidden to make financial values fit. Charts and order books may use compact labels, but form values stay readable. Gains and losses carry a sign or a word, never color alone.

## Verification

Check both appearances, Dynamic Type at the larger sizes, VoiceOver order, and input error and success states on a device or the Simulator, in every shipped language. The token pairs above were chosen for WCAG AA contrast; composite surfaces and interaction flows still need review. Wallet, launchpad, swap, and contract behavior are outside this document.

## Migration

The prior Signal palette and Geist/Inter font selection are retired. Do not restore them from git history.

Font sources: https://github.com/google/fonts/tree/main/ofl/bodonimoda, https://github.com/google/fonts/tree/main/ofl/manrope, https://github.com/google/fonts/tree/main/ofl/ibmplexmono
