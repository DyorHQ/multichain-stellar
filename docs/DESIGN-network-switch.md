# Network switch: Monad ⇄ Stellar

Design spec for the DyorHQ iPhone app · 2026-10-13 · for SwiftUI implementation

- **Base:** build 23, branch `release/23`, commit `d387a64`. App code is cited as `file:line` at d387a64.
- **Stellar side:** `DyorHQ/multichain-stellar` @ 6733959 (iOS unchanged since 4792050): the `DyorLite` package and the
  integration drop-ins (`ios/Integration/*.swift`, already copied to `ios/DyorHQ/Lite/` on branch `lite/network-switch`).
- **Owner direction (2026-10-13):** no "Pro", "Lite" or "mode" anywhere the user can see. The app shows its network,
  Monad. The user taps it, picks Stellar, and the screens change with the network. Header and side menu stay the same.
- **Reference:** the Miracle recording (scratchpad `miracle-video/`), venue switch only. Its mode card is not used.

### Decisions at a glance

1. One control: a **network chip** ("◉ Monad ⌄") as the first row of Home's balance card, on both networks' Homes.
2. Profile › Network shows the same chip and opens the same sheet. The side menu has no switcher. Its footer names the
   network, and its rows follow the network.
3. **Network sheet:** Select → Confirm (first switch to Stellar on this iPhone only) → Setup. Setup is a checklist
   that does the real work (unlock, sign in, invite, account setup) and stops when it needs the user.
4. **Switching back to Monad is instant:** tap Monad, then "Switch to Monad". No Confirm step, no Setup.
5. **One unlock per setup:** one passkey or Face ID prompt for the whole first switch (today's code would ask up to four
   times).
6. **Stellar Home** reuses Monad's header, card, tile and figure styles, and the tab bar is Home · Earn · Launch ·
   Moments. Teal and the ModePill are gone. Brand purple is the only accent. "Testnet" is always labelled.
7. **Motion:** the new Home pushes in from the trailing edge (to Stellar) or the leading edge (to Monad) in 320 ms.
   Under Profile the swap is instant and Profile closes on top of it. Reduce Motion cuts.
8. **No surprise prompts:** a cold launch on Stellar never asks for a passkey. A link or alert that opens a Monad screen
   switches to Monad first.

### Implementation rulings (2026-10-13, these override the sections below)

1. **The App Store build stays build 23 exactly.** No unflagged edit to any existing app file. Everything new lives in
   `ios/DyorHQ/Lite/` (whole files inside `#if STELLAR_LITE`), and every hook in an existing file sits inside
   `#if STELLAR_LITE`. So instead of §8.1's two unflagged refactors:
   - `SheetHeader` is a new view in `ios/DyorHQ/Lite/` with the same metrics as Perps' `sheetHeader`; Perps is untouched.
   - Stellar Home uses `HomeHeader` as it is: the host passes a `Binding` whose setter calls the Stellar search.
   The only shared, unflagged changes are the two already on the branch: `RemoteFlags.stellarLite` in DyorKit (default
   off) and `AppEnvironment.stellarLiteEnabled`.
2. **Owner questions (§9), decided on the designer's recommendations; the owner can still change them:** Confirm only on
   the first switch to Stellar (1); one unlock per setup run (2), with the signer also dropped when the app goes to the
   background; the chip shows for accounts that can't use Stellar, with the reason (3); Profile's Wallet section
   follows the network (5); network labels come from the server's network name (7). Deferred: re-entering a password
   or phrase in the sheet (4) and the app-wide white-on-Brand contrast pass (6).
3. **`logo-XLM.png`: approved by the owner and added** (2026-10-13): Stellar's official white mark, cropped unaltered from
   the official logo pack (stellar.org/brand-resources, "Logo Press Kit 2026"), on a black 256 × 256 disc. It lives in
   the app repo at `ios/Internal/Resources/logo-XLM.png`, which only the internal project ships (`generate.py` adds the
   folder), not in `Resources/TokenLogos/` — that folder is shared with the App Store app. `MarketLogo(symbol: "XLM")`
   finds it as `UIImage(named: "logo-XLM")`.

---

## 1. Principles

### 1.1 Taken from Miracle

| Miracle (recording) | DyorHQ |
|---|---|
| Venue chip next to the balance: logo, "HyperLiquid", chevron, under Total Volume (sheet_03) | Network chip with mark, name and chevron in Home's balance card. It is a filled capsule, so it reads as a control (§3.1) |
| Same header (☰ · search · avatar) and side menu in every venue and mode | Same `HomeHeader` (☰ · search · bell · avatar) and `SideMenuView` on both networks |
| Profile "DEX" section with a row for the current venue (sheet_07) | Profile "Network" section, whose first row carries the same chip |
| Bottom sheet "Select DEX": ✕, rows with logo and ✓, full-width "Next" (sheet_08) | "Select network": same anatomy, minus the search field (§3.6.1) |
| "You're Switching DEX's": ‹, ✕, icon, "own balance and positions… not lost… switch back" | "You're switching networks": from → to marks and three true statements (§3.6.2) |
| "Processing… Switching DEX…" for about 3 s, then the sheet closes | Setup checklist with real steps. It closes by itself when done (§3.6.3) |
| Lands on the new venue's Home, which reloads with fewer modules (venue_land) | Lands on the other network's Home, with its own layout and tab bar |
| New Home slides in from the trailing edge over the old one (mode_switch rows 2–3) | Push transition, direction set by network order (§5) |

### 1.2 Changed for DyorHQ, and why

1. **A network, not a mode.** The owner removed Pro/Lite/mode copy and the side-menu mode card. The words on screen
   are what the user is actually choosing: Monad or Stellar.
2. **One primary control.** The chip sits on the screen the user is already looking at. A second switcher in the menu
   would add a choice but no new reach (§3.4).
3. **Setup does real work, so it shows real steps.** Miracle's spinner hides about 3 s of nothing. DyorHQ may need a
   passkey or Face ID, an invite code and an account setup, so each step is visible, can be retried, and says why it
   stopped.
4. **Confirm only when it tells the user something new.** The first switch to Stellar explains separate balances, the
   shared secret and testnet. After that the user knows. Going back to Monad needs no explanation, so it has no Confirm
   step.
5. **DyorHQ branding, not Miracle's.**
   - Monochrome surfaces (`Color(.systemGroupedBackground)` / `secondarySystemGroupedBackground`).
   - Brand purple (`Color.brand`, Colors.swift:15) only for selection and primary actions.
   - Status hues only next to a word.
   - Serif balance figure as on Monad Home.
   - No new illustration: network marks and SF Symbols only.
6. **Fewer prompts.** The Stellar key is unlocked once per setup run and held in memory only for that run (§2.6, §8.3).
7. **Testnet is never implicit.** Stellar always shows a "Testnet" badge, and copy says balances have no value.
8. **Monad stays build 23.** Apart from the chip row, Monad screens are untouched. Stellar gets its own tree, so
   nothing on Monad changes when Stellar does.

### 1.3 Words

- **On screen:** network · Monad · Stellar · Testnet · "Switch to Stellar" · "Switch to Monad" ·
  "You're switching networks".
- **Never on screen:** Pro, Lite, mode, DyorHQ Pro, DyorHQ Lite, venue, DEX, "audited", exclamation marks.
- **Internal names that may stay in code:** `DyorLite`, `LiteStore`, `LiteSession`, `LiteTab`, `STELLAR_LITE`,
  `stellarLite` (remote flag), `lite.*` defaults keys.
- **Names:** "Monad" and "Stellar" are network names. They are never translated and are drawn with
  `Text(verbatim:)`. "Testnet" is translated (§3.7).
- **Style:** sentence case, short sentences, no hype. Multi-line copy goes through `Paragraph` (Paragraph.swift), so
  Korean wraps between words.

---

## 2. Entry points and flows

### 2.1 When the network control exists

| Condition | Chip on Home and network row in Profile | Stellar in the sheet |
|---|---|---|
| App Store project `DyorHQ.xcodeproj` (no `STELLAR_LITE`) | No. Build 23 exactly. | — |
| Internal project (`ios/Internal/generate.py` → `DyorHQInternal.xcodeproj`) with `LITE_API_URL` empty | No | — |
| Internal project, remote flag `stellarLite` not JSON `true` (`env.stellarLiteEnabled`) | No | — |
| Internal, flag on, passkey (Mera) account | Yes | Selectable. The first switch asks for the passkey once. |
| Internal, flag on, email & password (v2) or imported phrase/key | Yes | Selectable if this iPhone holds the Stellar key (derived at sign-in or import, `LiteKeyBootstrap`). Otherwise disabled: "Sign in again…" / "Import this wallet again…" |
| Internal, flag on, Apple, Google, email code, Privy passkey | Yes | Disabled: "Not available for %@ sign-in yet." |
| Internal, flag on, watch-only | Yes | Disabled: "Not available while watching an address." |
| Not on the tester list | Yes | Selectable. Setup asks for the invite code. |
| Server config: paused, needs a newer build, or wrong sponsor | Yes | Selectable. Setup stops at its first silent check, before any prompt. |

Accounts that can't use Stellar still see the chip in the internal build. The sheet tells them why (open question 3).

### 2.2 Entry points

| | Where | Opens |
|---|---|---|
| A | Network chip in the balance card on **Monad Home** and on **Stellar Home** | Network sheet at Select (origin `.home`) |
| B | **Profile › Network** row, which shows the same chip | Network sheet at Select, presented from Profile (origin `.profile`) |
| C | Stellar Home, **locked** card: "Unlock with Face ID" | Runs Setup inline. If Setup pauses or fails, opens the sheet at Setup. |
| D | Stellar Home, **paused / update needed** card: "Switch to Monad" | Swaps to Monad at once |
| — | Side menu | No switcher. The footer reads "DyorHQ 1.x · Monad mainnet" or "· Stellar testnet", and the rows follow the network. |

### 2.3 Resolving a switch (local: no network, no prompt)

```
plan(to: .monad)   → .instant
plan(to: .stellar) → .unavailable(reason)   the account can't use Stellar here (2.1)
                   → .instant               Stellar address known
                                            AND Stellar session valid for ≥ 5 more minutes
                                            AND account set up (cached)
                   → .setup(steps)          otherwise; steps ⊆ [unlock, signIn, setUp].
                                            The invite step is discovered during signIn.

showConfirm = (to == .stellar) && plan != .instant && !stellarIntroSeen(account)
```

### 2.4 State diagram

```
 ENTRY              NETWORK SHEET                                                       RESULT
 ─────              ─────────────                                                       ──────
 Home chip ──┐
 Profile row ┴─► SELECT ─┬─ Monad picked ──────────── [Switch to Monad] ─────────────► SWAP → Monad Home
                  │ ✕    ├─ Stellar picked, unavailable ─ row disabled + reason; no button
                  ▼      ├─ Stellar picked, instant ──── [Switch to Stellar] ────────► SWAP → Stellar Home
               (closed)  ├─ Stellar picked, setup,
                         │   first time ───────────────── [Next] ─► CONFIRM ─┬─ ‹ ─► SELECT
                         │                                                   ├─ ✕ ─► (closed)
                         │                                                   └─ [Switch to Stellar] ─► SETUP
                         └─ Stellar picked, setup ──────── [Switch to Stellar] ──────────────────────► SETUP

 SETUP starts on entry. ✕ cancels between steps; it is disabled while a transaction is being sent.

   check ─► unlock ─► sign in ─┬───────────────────────────────┬─► set up? ─► DONE ─(0.6 s)─► SWAP → Stellar Home
     │         │         │     └─► INVITE ─[Join]─► sign in ───┘     │
     └─────────┴─────────┴──────────────┴────────────────────────────┴─► FAILED(step, reason)
                                                [Try again]: resumes at that step
                                                [Close]: shown when retrying can't help

 Stellar Home, locked ── [Unlock with Face ID] ─► SETUP inline (no sheet) ─ pauses or fails ─► sheet at SETUP
 Stellar Home, paused ── [Switch to Monad] ─────► SWAP → Monad Home
```

### 2.5 Landing

| Origin | Sequence after the switch commits |
|---|---|
| Home chip (either Home) | 1. The sheet slides down (system). 2. `onDismiss`: swap with a push (§5). 3. The other network's Home, Home tab selected. |
| Profile row | 1. The sheet slides down. 2. The swap happens under Profile at once, without animation. 3. The Network row shows the new chip for 0.4 s. 4. Profile closes (system cover dismissal) onto the new Home. |
| Stellar Home locked card | In place: the card fills in and the tiles enable. Nothing moves. |
| Stellar Home paused card | Push back to Monad Home. |

### 2.6 Lifecycle rules

1. **Remembered per account.** The network is stored in `network.<address>` and replaces `lite.mode.<address>`, which
   is migrated once. A new account starts on Monad.
2. **Cold launch on Stellar** calls `LiteSession.resumeAtLaunch()`, which restores the Stellar session silently.
   - Session valid: Stellar Home loads.
   - Session expired (12 h, auth.ts:11): Stellar Home shows the **locked** card.
   - It never prompts. This is the same rule as `canSignWithoutPrompt` (Session.swift:99).
3. **Monad-only destinations switch to Monad first** (instant, no sheet): Moment links (`deliverPendingLink`,
   Router.swift:127), notification taps (`deliverPendingNotificationRoute` :111, `open(route:)` :203), Portfolio,
   `openSwap` :139, `openPerp` :146, `openLaunch` :153, `openMoment` :183/:190.
4. **Remote flag off, or API URL missing, while on Stellar:** go back to Monad Home and show the existing notice capsule
   (`router.linkNotice`, RootView.swift:52–63): "Stellar is off for now. You're back on Monad."
5. **Sign-out or erase** removes the Stellar key and session, `network.<address>`, `network.stellarIntroSeen.<address>`
   and `lite.activated.*`. Extend `LiteKeyBootstrap.forget` (drop-in `DyorHQLiteKeys.swift:94–98`).
6. **The Stellar session belongs to the account, not to a screen.** Going back and forth keeps Stellar's last figures in
   memory. A return to Stellar shows them at once and refreshes.
7. **Monad keeps running while on Stellar.** Alerts, history and bridge tracking are account-level
   (RootView.swift:135–170) and are untouched. The bell shows the same notification center on both networks.
8. **Return to Monad looks instant.** Monad's tree is rebuilt, and Home shows saved figures in its first frame
   (`HomeModel.showSaved`, HomeView.swift:86–91).
9. **The signer** unlocked for a setup run lives only in memory, until the run ends, is cancelled, or sits idle for
   120 s while waiting on the user. After that, the next step asks again ("Unlock again to continue.").

---

## 3. Screen-by-screen specs

Sizes are points at the default text size, on a 393 pt wide phone unless a width is named. Tokens are DyorHQ's
(§7).

### 3.1 Shared pieces (new file `ios/DyorHQ/Lite/NetworkChip.swift`)

**NetworkMark(network, size)**

- Built on `MarketLogo(symbol:url:size:)` (Components.swift:44–60), so it gets `LogoDisc`'s plate and the `logoRing`
  hairline (Components.swift:65–78, Theme.swift:250) in both appearances.
- Monad uses symbol `"MON"`: the bundled `logo-MON.png`, a purple disc.
- Stellar uses symbol `"XLM"`: add `Resources/TokenLogos/logo-XLM.png`. It is the official Stellar mark as a full disc,
  rasterized with the same `qlmanage` pipeline as the other token logos. A near-black disc gets its edge from the ring
  in dark mode.
- Sizes: 18 (chip), 36 (sheet rows), 40 (route marks).

**TestnetBadge**

- Exactly `UnverifiedBadge` (Components.swift:156–164): `Text("Testnet")`, `.caption2.weight(.semibold)`,
  `Color.attention` text on a `Color.attention.opacity(0.14)` Capsule, padding 6 h / 1 v.
- Replaces DyorLite's orange all-caps "TESTNET" (`LiteTheme.swift:86–95`).
- Shown after the name "Stellar" wherever the network is named: chip, sheet row, Profile row (inside the chip), and the
  `ConfirmSheet` header in DyorLite.

**NetworkChip(network, interactive: Bool = true)**

```
( ◉ Monad ⌄ )                     ( ✦ Stellar  Testnet  ⌄ )
```

- Matches the Total Volume period chip (HomeView.swift:234–241) so the two read as siblings.
- `HStack(spacing: 6)`:
  - `NetworkMark` 18 pt (`@ScaledMetric(relativeTo: .subheadline)`).
  - The name in `.subheadline.weight(.medium)`, `.primary`.
  - `TestnetBadge` (Stellar only).
  - `Image(systemName: "chevron.down")` in `.caption2.weight(.semibold)`.
- Padding: leading 6 (the disc sits optically inside the capsule), trailing 10, vertical 6. That gives a 32 pt capsule.
- Fill: `Color(.tertiarySystemFill)`, `Capsule()`.
- Pressed state: scale 0.97 and opacity 0.85 (140 ms).
- Tap: `Haptics.tap()`, then present the network sheet.
- `interactive: false` draws the same look without a button, for use inside the Profile row.
- At accessibility sizes, `ViewThatFits` moves the badge out of the capsule onto its own line just below it.
- **Hit target:** 44 pt. The row that holds the chip is 44 pt tall (§3.2).

**NetworkRoute(from, to, done: Bool)**, used in Confirm and Setup

```
      (◉)   →   (✦)
```

- `HStack(spacing: 16)`: mark 40, `Image(systemName: "arrow.right")` in `.title3.weight(.semibold)` `.secondary`,
  mark 40.
- When `done`, the destination mark gets an 18 pt `checkmark.circle.fill` in `Color.positive` on a 2 pt
  `systemBackground` ring at bottom-trailing.
- One accessibility element: "From Monad to Stellar".

**SheetHeader(title:onBack:onClose:)**: promote the existing helper

- Today it is `private func sheetHeader` in Perps/PerpTradeView.swift:2212–2226: title in `.title2.weight(.bold)` on
  the left, ✕ (`xmark`, `.subheadline.weight(.semibold)`, `.secondary`) in a 32 pt `tertiarySystemFill` circle inside a
  44 pt target, padding top 20 / horizontal 20 / bottom 8.
- Move it to Components.swift as `struct SheetHeader`, with an optional leading back button (`chevron.left`, same
  circle) and an optional title. PerpTradeView calls the struct, so Perps looks the same.

### 3.2 Monad Home (build 23 plus the chip row)

**The only change is a chip row as the first row of the balance card** (`HomeView.heroCard`, HomeView.swift:134–179):

- Insert `NetworkChipRow(network: .monad)` as the first child of the `VStack(alignment: .leading, spacing: 14)` at
  :135. Wrap it in `#if STELLAR_LITE` and show it only when the network control exists (§2.1).
- The row is `HStack { NetworkChip(.monad); Spacer(minLength: 0) }`, with `.frame(minHeight: 44)` and
  `.padding(.bottom, -6)`.
- The card's `.padding(16)` (:177) becomes horizontal 16 / bottom 16 / **top 10** when the row is shown.
- Result: the capsule's top edge is 16 pt from the card edge and 14 pt above the balance's line box. At the default
  size the card grows by 46 pt.
- **Untouched:** the balance column, the Total Volume column, the period chip and both saved lines. Their height rule
  (:260–265, "the card keeps its height when the line goes") still holds, because the new row has a fixed height above
  the block.

```
┌───────────────────────────────────────────────┐
│ (≡)  ( 🔍 Search tokens…           2m )  (🔔)(●) │ HomeHeader, unchanged
│ ┌───────────────────────────────────────────┐ │
│ │ ( ◉ Monad ⌄ )                             │ │ NEW: chip row, 44 pt
│ │ $12,480.22                  Total Volume  │ │ serif 40 · subheadline/headline
│ │ +$84.10  ( +0.68% )               $3,912  │ │
│ │ Updated 2 min ago            ( 🕐 All ⌄ ) │ │ period chip, unchanged
│ │ ───────────────────────────────────────── │ │
│ │ Avail. Balance                     In Use │ │
│ │ ───────────────────────────────────────── │ │
│ │ ● Spot    ● Perps    ● Launch   ● Moments │ │
│ └───────────────────────────────────────────┘ │
│ [ Bridge ] [ Deposit ] [ Withdraw ] [Transfer]│
│ …Allocation, Top Tokens, My Holdings          │
├───────────────────────────────────────────────┤
│  ⌂ Home    🔥 Launch    ⇄ Trade    ◎ Moments   │ Monad tab bar, unchanged
└───────────────────────────────────────────────┘
```

**Why this spot**

- It is the first thing under the header, at the top-left where reading starts.
- It reads as the balance's title: "Monad · $12,480.22".
- It is the same spot on Stellar Home.

**Rejected placements**

- Miracle's exact spot under Total Volume: the period chip is already there, and a second capsule would make the right
  column taller than the balance column, which breaks the saved-line rule.
- The header: it is shared chrome the owner wants unchanged.
- A row above the card: it floats free of the balance and collides with the passkey `SessionPill` row (:36–38).

Other Monad tabs (Launch, Trade, Moments) don't get a chip. The network is a Home control, as in Miracle.

### 3.3 Stellar Home (re-skinned `LiteHomeView`)

```
┌───────────────────────────────────────────────┐
│ (≡)  ( 🔍 Search tokens…           1m )  (🔔)(●) │ the host's HomeHeader
│ ┌───────────────────────────────────────────┐ │
│ │ ( ✦ Stellar  Testnet  ⌄ )                 │ │ chip row (3.2 metrics)
│ │ $10,512.40                                │ │ serif 40, monospacedDigit
│ │ Valued at reference prices. Testnet       │ │ .caption, secondary
│ │ assets have no value.                     │ │
│ └───────────────────────────────────────────┘ │
│ [Bridge][Deposit][Withdraw][ Swap ][Add cash] │ 5 HomeAction tiles
│ ┌ My Holdings ──────────────────────────────┐ │
│ │ (✦) XLM                         10,000.00 │ │
│ │     Stellar Lumens              $1,190.00 │ │
│ │ ───────────────────────────────────────── │ │
│ │ (◎) USDC                         9,322.40 │ │
│ │ (✦) XLM · Earning on Blend         500.00 │ │
│ └───────────────────────────────────────────┘ │
│ ┌ Activity ─────────────────────────────────┐ │
│ │ Swapped 100 XLM for 11.9 USDC    ✓ Done   │ │
│ │ 2026-10-13 09:41                          │ │
│ └───────────────────────────────────────────┘ │
├───────────────────────────────────────────────┤
│  ⌂ Home    ❦ Earn    🔥 Launch    ◎ Moments    │ Stellar tab bar
└───────────────────────────────────────────────┘
```

**Frame.** Same as Monad Home (HomeView.swift:32–64):

- `NavigationStack` → `ScrollView` → `VStack(spacing: 16)`, padding horizontal 16 / vertical 12.
- Background `Color(.systemGroupedBackground)`, scroll indicators hidden, navigation bar hidden.
- `.safeAreaInset(edge: .top, spacing: 0) { chrome.header(context) }`.
- `.refreshable { await store.refreshAll() }`.
- Remove the ModePill (`LiteHomeView.swift:20`), the title "Lite" (:30), the gear toolbar (:31–36) and its settings
  sheet (:44).

**Header.** The host's `HomeHeader` (HomeView.swift:1516–1605), unchanged in look, through a new
`init(onSearch:error:updatedAt:)`:

- ☰ opens the same side menu, with Stellar rows (§3.4).
- 🔔 opens the same notification center.
- The avatar opens the same Profile.
- Search opens the Stellar search (below).
- The capsule's trailing status shows `store.lastError` as `wifi.exclamationmark` in attention colour; otherwise the
  last refresh as a relative time.

**Balance card**

- `cardBackground()` (HomeView.swift:756), with the chip row exactly as in §3.2.
- Balance = `store.totalUSD`, in the Monad hero's style (:140–146): `.system(size: 40, weight: .semibold, design: .serif)`,
  `.monospacedDigit()`, `.lineLimit(1)`, `.minimumScaleFactor(0.6)`, `.contentTransition(.numericText(value:))`.
- Until the account and prices are read: the `unreadFigure` placeholder (HomeView.swift:763–771), never "$0.00". Today
  `LiteHomeView.swift:57` shows $0.00 before data arrives.
- Caption: a local string, "Valued at reference prices. Testnet assets have no value." It replaces the server's
  `prices.reference`.
- This card replaces `balanceCard` (`LiteHomeView.swift:50–62`). Its "Balance" label and TESTNET badge go, because the
  chip carries both.

**Actions.** Five tiles with `HomeAction` metrics (HomeView.swift:544–564): `HStack(spacing: 10)`; symbol in
`.body.weight(.semibold)` at a scaled 24 pt height; label in `.caption` medium; 12 pt vertical padding; card colour;
radius 14; foreground `.primary`.

| Tile | Symbol | Opens (DyorLite) |
|---|---|---|
| Bridge | `point.3.connected.trianglepath.dotted` | `BridgeSheet`: USDC between Monad and Stellar |
| Deposit | `creditcard` | `ReceiveSheet`: Stellar address and QR |
| Withdraw | `arrow.up` | `SendSheet` |
| Swap | `arrow.left.arrow.right` | `SwapSheet` |
| Add cash | `banknote` | `CashSheet` (anchors) |

- The first three use Monad's labels and symbols (HomeView.swift:296–304) for the same jobs, so habits carry across
  networks.
- At accessibility sizes, `ViewThatFits` turns the row into a 3 + 2 `Grid`.
- The tiles are disabled while the account is locked or paused.

**My Holdings** replaces "Assets" (`LiteHomeView.swift:87–118`):

- Title in `.headline`.
- Rows:
  - A 36 pt disc in the LogoDisc look. Bundled `logo-XLM` / `logo-USDC` come from the main bundle; other coins show
    letters.
  - Code in `.subheadline.weight(.semibold)`, name in `.caption` secondary.
  - Trailing amount in `.subheadline.weight(.medium).monospacedDigit()`, value in `.caption` secondary.
  - Dividers inset 44 (HomeView.swift:377).
- Earn positions use the same row with the name "Earning on Blend".
- Before the read: "Reading your balances…" with a small spinner (the `holdingsUnreadRow` pattern, HomeView.swift:485–496).

**Activity** (`LiteHomeView.swift:120–139`):

- Title in `.headline`.
- Row: summary in `.subheadline`, time in `.caption2` secondary.
- Trailing status word with a symbol:
  - "Done", `checkmark`, secondary.
  - "Pending", `clock`, secondary.
  - "Failed", `exclamationmark.triangle.fill`, `Color.negative`.
- Empty: "Nothing yet. Add cash or swap to get started."

**Tab bar**

- `TabView` with Home `house`, Earn `leaf`, Launch `flame`, Moments `camera.aperture` (`LiteRootView.swift:48–57`).
- Selection is bound to `router.stellarTab`.
- Tint: inherit the app tint (Brand). Remove `.tint(LiteTheme.accent)` (:39).
- `.sensoryFeedback(.selection, trigger:)` as on Monad (RootView.swift:321).
- Earn, Launch and Moments keep their screens. They get only the token changes in §7.

**Locked state** (session expired, cold launch). The card holds the unlock; tiles are disabled; holdings and activity
are hidden.

```
│ ┌───────────────────────────────────────────┐ │
│ │ ( ✦ Stellar  Testnet  ⌄ )                 │ │
│ │ ▒▒▒▒▒▒▒▒▒▒                                │ │ unreadFigure placeholder
│ │ 🔒 Unlock to see your Stellar balance.     │ │ .footnote, secondary; lock.fill
│ │ ╭───────────────────────────────────────╮ │ │
│ │ │          Unlock with Face ID          │ │ │ PrimaryButton
│ │ ╰───────────────────────────────────────╯ │ │
│ └───────────────────────────────────────────┘ │
```

The button calls `chrome.unlock()`. The host runs Setup inline, and the button shows busy. If Setup pauses or fails,
the sheet opens at Setup.

**Paused / update needed.** Same card. In place of the figure: `InlineError("DyorHQ on Stellar is paused for
maintenance. Monad is unaffected.")` or "Update DyorHQ to use Stellar.", then a `PrimaryButton` "Switch to Monad"
(`chrome.switchToMonad()`).

**Stellar search** (new `LiteSearchSheet`) mirrors Monad's `TokenPickerSheet` (Swap/SwapView.swift:798, :904–905):

- `NavigationStack` + `List`, title "Choose a Token".
- `.searchable(text:, prompt: "Symbol, name or address")`.
- Sections "My Holdings" and "Launches", filtered on the device by code, name, symbol or contract.
- Tap a launch: push its launch page in Stellar Home's stack.
- Tap a holding: open `SwapSheet` with that asset preset as the one to receive.
- No match: "No Stellar tokens match “%@”." with a footnote, "Monad tokens show when you switch to Monad."

### 3.4 Side menu (SideMenuView.swift)

Unchanged chrome: the gradient (:16), the ✕ and serif "DyorHQ" header (:36–54), the profile row (:56–83), and the
`MenuRow` style (:144–178). **No network control and no card.**

- **Rows follow the network:** `MenuItem.items(for: router.network)` replaces `MenuItem.allCases` at :24.
  - Monad, unchanged (Router.swift:282–326): Home, Spot, Perps, Launch, Moments, News, Portfolio, Get Help.
  - Stellar:
    - Home: "Balance and activity", `house`.
    - Earn: "Lend XLM and USDC on Blend", `leaf`.
    - Launch: "Launch and trade coins on Stellar", `flame`.
    - Moments: "Collect editions on Stellar", `camera.aperture`.
    - News and Get Help as on Monad.
  - On Stellar the "Now" badge (:162–166) follows `router.stellarTab`.
- **Footer** (:85–90): "DyorHQ 1.x · Monad mainnet" as today, or "DyorHQ 1.x · Stellar testnet". This is the menu's
  only network mention.

```
 (✕)               DyorHQ
 (AB)  Jay Walker                              ›
       Signed in with passkey
 ┌───────────────────────────────────────────┐
 │ [⌂]  Home                          Now   › │
 │      Balance and activity                  │
 ├───────────────────────────────────────────┤
 │ [❦]  Earn                                › │
 │      Lend XLM and USDC on Blend            │
 └─ Launch · Moments · News · Get Help ──────┘
 DyorHQ 1.1 · Stellar testnet
```

### 3.5 Profile (ProfileView.swift)

The **Network section** (:98–101) becomes:

```
 NETWORK                                          (Monad current)
 ┌───────────────────────────────────────────────┐
 │ 🌐 Network                       ( ◉ Monad ⌄ ) │ Button: the whole row opens the sheet
 │    Chain                         Monad mainnet │ existing row (:99)
 │    RPC                            rpc.monad.xyz │ existing row (:100)
 └───────────────────────────────────────────────┘

 NETWORK                                          (Stellar current)
 ┌───────────────────────────────────────────────┐
 │ 🌐 Network          ( ✦ Stellar  Testnet  ⌄ ) │
 │    Chain                       Stellar testnet │
 │ 👤 Stellar account               GBQ4…7ZKD  ›  │ NavigationLink
 └───────────────────────────────────────────────┘
 Testnet balances have no value. DyorHQ pays the Stellar network fees.
```

- **Row 1** is a `Button` with label
  `HStack { SettingsRow("Network", symbol: "network", tint: .accent); Spacer(); NetworkChip(current, interactive: false) }`.
  It presents the sheet from Profile, with origin `.profile`. It is the same chip and the same sheet as on Home.
- **Monad:** the Chain and RPC rows stay as they are.
- **Stellar:**
  - Chain reads "Stellar testnet", with no RPC row.
  - "Stellar account" (`person.text.rectangle`) shows the short G-address, monospaced, and pushes `LiteAccountView`
    (re-skinned `LiteSettingsView`) inside Profile's stack.
  - `LiteAccountView` holds:
    - Stellar address (copy, `speechSpellsOutCharacters`).
    - Secured by.
    - Network.
    - Reserves paid by DyorHQ.
    - Show Stellar secret key (email & password and imported accounts only).
    - Get 10,000 test XLM.
    - Sign out of Stellar: destructive, with a confirmation dialog.
  - "Switch to Pro (Monad)" (`LiteSettingsView.swift:45`) is deleted.
- **Footer:** Stellar only.

**Wallet section on Stellar** (:47–57). Recommended (open question 5): without it, a user on Stellar can be shown the
wrong address to receive on.

- Receive and Send open Stellar's Deposit and Withdraw sheets instead of Monad's (:48–50).
- Recent Activity is hidden, because Stellar Home has Activity.
- Footer: "On the Stellar testnet."
- Without it, Profile › Receive on Stellar would show the Monad address.
- The account header (address row) stays the account's Monad address.

### 3.6 The network sheet (new `ios/DyorHQ/Lite/NetworkSheet.swift`)

**Presentation**

- One `.sheet` whose content moves between steps in place, as Miracle's does. Sheets stack only where they must.
- Detents: `.presentationDetents([.height(fitted)])`, where `fitted` is the content's measured height
  (`onGeometryChange`). Use `.large` when that exceeds 85 % of the screen, or while the invite field has focus.
- `.presentationDragIndicator(.visible)`.
- `.presentationBackground(Color(.systemBackground))`. The sheet must be opaque: it holds an input ("inputs remain
  opaque", design system), and iOS 26 sheets are otherwise translucent.
- `.interactiveDismissDisabled(isSendingTransaction)`.
- Step changes animate with `.snappy(duration: 0.22)`.

#### 3.6.1 Select network

```
┌───────────────────────────────────────────────┐
│ Select network                           (✕) │ SheetHeader
│ ╭───────────────────────────────────────────╮ │
│ │ (◉)  Monad                            ✓   │ │ selected: Brand 1.5 pt stroke
│ │      Spot, perps, launches and Moments    │ │
│ ╰───────────────────────────────────────────╯ │
│ ╭───────────────────────────────────────────╮ │
│ │ (✦)  Stellar  Testnet                     │ │
│ │      Earn, swap, launch and collect       │ │
│ ╰───────────────────────────────────────────╯ │
│ ╭───────────────────────────────────────────╮ │
│ │              Switch network               │ │ PrimaryButton, unavailable style
│ ╰───────────────────────────────────────────╯ │
└───────────────────────────────────────────────┘
```

- **No search field.** There are two networks. Miracle's field searches three venues; here it would be the tallest
  thing on the sheet and could never filter anything. Add one past six networks.
- **Rows** use `UnitPreferenceSheet.optionRow` (PerpTradeView.swift:2083–2102):
  - `HStack(spacing: 14)`.
  - Mark 36.
  - `VStack(alignment: .leading, spacing: 3)`: name in `.body.weight(.semibold)` (+ TestnetBadge); subtitle in
    `.caption` secondary with vertical `fixedSize`.
  - `Spacer(minLength: 8)`.
  - `checkmark` in `.headline.weight(.semibold)`, Brand.
  - Padding 14; `tertiarySystemFill` `RoundedRectangle(16)`; Brand 1.5 pt stroke when selected.
  - Rows sit in `VStack(spacing: 12)`, padding horizontal 20, top 8.
  - Unlike Perps, tapping a row selects it (`Haptics.selection()`) and does not close the sheet.
- **Initial selection** is the current network.
- **Unavailable Stellar row:**
  - Disabled; mark and name at 50 % opacity.
  - The subtitle becomes the reason (§2.1), in `.caption` secondary.
  - Trailing `lock.fill`, secondary.
  - It can never be selected.
- **Primary button**: `PrimaryButton` (Components.swift:478–556), padding top 24 / horizontal 20 / bottom 16.

  | Selection | Label | Action |
  |---|---|---|
  | Current network | "Switch network" (unavailable style) | — |
  | Monad, while on Stellar | "Switch to Monad" | Swap at once |
  | Stellar, setup needed, first time | "Next" | Go to Confirm |
  | Stellar, otherwise | "Switch to Stellar" | Swap at once if `.instant`, otherwise Setup |

- Reference height: about 350 pt on Face ID phones, about 330 on iPhone SE.

#### 3.6.2 Confirm (first switch to Stellar on this iPhone only)

```
┌───────────────────────────────────────────────┐
│ (‹)                                      (✕) │ SheetHeader, no title
│                 (◉)  →  (✦)                   │ NetworkRoute 40
│           You're switching networks           │ .title2.bold, centred
│                                               │
│  ▣  Stellar has its own balance and activity. │ .subheadline, secondary;
│     Your Monad funds stay on Monad.           │ symbols .body, secondary
│  🔑 Same account: your Stellar key comes from  │
│     the secret you already use.               │
│  ⚗︎  This is Stellar's testnet. Balances there │
│     have no value.                            │
│                                               │
│          You can switch back anytime.         │ .footnote, tertiary, centred
│ ╭───────────────────────────────────────────╮ │
│ │             Switch to Stellar             │ │ PrimaryButton
│ ╰───────────────────────────────────────────╯ │
└───────────────────────────────────────────────┘
```

- Rows are `Label { Paragraph(…) } icon: { Image(systemName:) }`, aligned on the first baseline, in
  `VStack(alignment: .leading, spacing: 14)`, padding horizontal 24.
- Symbols: `square.split.2x1`, `key`, `testtube.2`.
- Tapping "Switch to Stellar" marks `network.stellarIntroSeen.<address>` and moves to Setup. The Setup run is the
  consent; there is no third tap.
- ‹ goes back to Select and keeps the selection. ✕ closes the sheet; nothing changes and the intro isn't marked seen.
- Reference height: about 450 pt.

#### 3.6.3 Setup (whenever the switch needs work)

```
┌───────────────────────────────────────────────┐
│                                          (✕) │
│                 (◉)  →  (✦)                   │
│             Switching to Stellar              │ .title2.bold
│                                               │
│  ✓  Unlock your Stellar key                   │ checkmark.circle.fill, positive
│     Unlocked                                  │
│  ◌  Sign in                                   │ ProgressView(.small)
│     Checking your access…                     │
│  ○  Set up your Stellar account               │ circle, tertiary
│                                               │
└───────────────────────────────────────────────┘
```

**Steps listed**

- The run starts on entry. The steps listed are `plan.steps`:
  - First time: Unlock, Sign in, Set up your Stellar account.
  - After the 12-hour session ends: Unlock, Sign in.
- A silent first check reads the server config and isn't listed. It shows only if it fails, so a paused service fails
  before any passkey prompt.

**Row anatomy**

- `HStack(alignment: .firstTextBaseline, spacing: 12)`.
- A 24 pt status column (`@ScaledMetric`).
- `VStack(alignment: .leading, spacing: 2)`:
  - Title in `.subheadline.weight(.semibold)` (`.tertiary` while pending).
  - Detail in `.footnote` (`.secondary`; `Color.attention` when failed), through `Paragraph`.
- Rows sit in `VStack(spacing: 16)`, padding horizontal 24.
- The vocabulary follows `TransactionProgress` (Components.swift:610).

**Status column**

| Status | Symbol |
|---|---|
| Pending | `circle`, tertiary |
| Running | `ProgressView().controlSize(.small)` |
| Needs you | `circle.inset.filled`, Brand |
| Done | `checkmark.circle.fill`, `Color.positive`, with a word in the detail |
| Failed | `exclamationmark.triangle.fill`, `Color.attention` |

Symbol changes use `.contentTransition(.symbolEffect(.replace))`.

**Unlock.** One prompt for the whole run.

- While running: "Confirm with Face ID" (the existing key `Confirm with %@`, with `BiometricGate.promptName`). The
  system passkey sheet or Face ID prompt opens over the sheet.
- Done: "Unlocked".
- The unlocked key signs the sign-in, the second sign-in after an invite, and the setup transaction. No other prompt
  is shown. The nonce is consumed on every sign-in attempt (auth.ts:79), so the invite retry needs a new signature.

**Invite.** The Sign in row expands when the server answers `not_invited`:

```
│  ●  Enter your invite code                     │
│     DyorHQ on Stellar is invite-only while we  │
│     test it.                                   │
│     Invite code                                │ .footnote.weight(.semibold): visible label
│     ┌────────────────────────────────────────┐ │ TextField .body.monospaced(), r12,
│     │ K7Q2XM9P                       Paste   │ │ tertiarySystemFill, 48 pt
│     └────────────────────────────────────────┘ │
│     You need it only once.                     │ helper; replaced by InlineError on error
│  ○  Set up your Stellar account                │
│ ╭────────────────────────────────────────────╮ │
│ │                   Join                     │ │ PrimaryButton; unavailable under 8 characters
│ ╰────────────────────────────────────────────╯ │
```

- Field behaviour:
  - Capitalization `.characters`; autocorrection off; spaces stripped; `.submitLabel(.join)`.
  - A system `PasteButton(payloadType: String.self)` sits inside the field's trailing edge (no paste-permission
    prompt).
  - Focus moves to the field when it appears.
  - The sheet goes to `.large`, and Join is pinned above the keyboard (`safeAreaInset(edge: .bottom)`).
- **Join** signs in again with the code, using the same unlocked key and no prompt.
- **`bad_invite`** (auth.ts:106 covers invalid, used and expired):
  - The error shows under the field: "That code isn't valid, has expired or was already used."
  - The text and focus stay; `Haptics.error()`.
- **`access_revoked`** (auth.ts:96): the row fails and can't be retried.

**Account setup.** The Set up row expands when the account isn't active or lacks USDC:

```
│  ●  Set up your Stellar account                │
│     Creates your account and adds USDC. DyorHQ │
│     pays the network fees and the reserve, so  │
│     you spend nothing.                         │
│     On testnet you also get 10,000 test XLM.   │
│ ╭────────────────────────────────────────────╮ │
│ │                  Set up                    │ │
│ ╰────────────────────────────────────────────╯ │
```

- One tap. This row is the confirmation for a write ("every write shows what will be sent", design system): what
  happens, who pays, and what the user spends.
- On testnet the server funds the account through Friendbot and returns an "Enable USDC" plan, which the unlocked key
  signs (`lite/index.ts:71–87`).
- While running: "Setting up… This can take a few seconds." ✕ and swipe-down are disabled while the plan is sent.
- If the account is already set up (for example, from another iPhone), the step completes without asking.

**Done**

- The title becomes "You're on Stellar" and the route shows its ✓.
- `Haptics.success()`, a 0.6 s hold, then the sheet closes and the swap runs.

**Failed** (example: offline at Sign in)

```
│  ✓  Unlock your Stellar key                    │
│  ⚠︎  Sign in                                    │
│     No connection. Check your network and try  │ attention colour
│     again.                                     │
│  ○  Set up your Stellar account                │
│ ╭────────────────────────────────────────────╮ │
│ │                 Try again                  │ │
│ ╰────────────────────────────────────────────╯ │
```

- **Try again** resumes at the failed step, and unlocks first if the key was dropped.
- **Close** replaces Try again when retrying can't help (§4).
- `Haptics.error()` on every failure.

**Cancel (✕)**

- Allowed between steps, and during a read (check, sign-in). The task is cancelled and the key dropped.
- Work that finished is kept: the Stellar address, a saved session, the intro flag.
- The next attempt resumes at the first unfinished step and never shows Confirm again.
- Disabled while the setup transaction is being sent.

Reference heights: about 430 pt; about 540 with the invite field (`.large` while typing); about 500 with setup expanded.

### 3.7 Copy

Network names are `Text(verbatim:)`. `%@` with a network name is never translated. Notes go into the catalog as
comments; `[tight]` marks narrow places, as in the existing catalog.

**App catalog** (`ios/DyorHQ/Resources/Localizable.xcstrings`). The key is the English text unless a key is given.

| Key / English | Where | Note for translators |
|---|---|---|
| `Testnet` | Badge after "Stellar" | [tight] Stellar's test network, where balances have no value. One short word if possible. |
| `Test network` | VoiceOver for the badge | Spoken form of "Testnet". |
| `Network: %@` | VoiceOver label for the chip and the Profile row | %@ is a network's name (Monad, Stellar), not translated. |
| `Changes the network.` | VoiceOver hint | |
| `Select network` | Sheet title | |
| `Spot, perps, launches and Moments` | Monad row | "Moments" is a feature name. At most 2 lines. |
| `Earn, swap, launch and collect` | Stellar row | What you can do on Stellar in DyorHQ. At most 2 lines. |
| `Current network` | VoiceOver value | |
| `Switch network` | Button before a choice | |
| `Next` | Button | |
| `Switch to %@` | Buttons and Stellar Home | %@ is a network's name. |
| `Not available for %@ sign-in yet.` | Unavailable reason | %@ is the sign-in method as written in a sentence (`signInMethod.*`, Session.swift:39). |
| `Not available while watching an address.` | Unavailable reason | |
| `Sign in again with your email and password to use Stellar on this iPhone.` | Unavailable reason | |
| `Import this wallet again on this iPhone to use Stellar.` | Unavailable reason | |
| `You're switching networks` | Confirm title | |
| `Stellar has its own balance and activity. Your Monad funds stay on Monad.` | Confirm | |
| `Same account: your Stellar key comes from the secret you already use.` | Confirm | "Secret": the passkey, recovery phrase or password the account uses. |
| `This is Stellar's testnet. Balances there have no value.` | Confirm | |
| `You can switch back anytime.` | Confirm | |
| `From %1$@ to %2$@` | VoiceOver for the route marks | Two network names. |
| `Switching to %@` · `You're on %@` | Setup titles | |
| `Unlock your Stellar key` | Step, and the Face ID / passkey prompt's reason | |
| `Confirm with %@` (exists) · `Unlocked` | Step details | `Unlocked` is [tight]. |
| `networkSetup.signIn` = "Sign in" | Step | [tight] DyorHQ checks this account owns its Stellar key. |
| `Checking your access…` · `Signed in` | Step details | |
| `Enter your invite code` | Step | |
| `DyorHQ on Stellar is invite-only while we test it.` | Step detail | |
| `Invite code` · `You need it only once.` | Field label and helper | |
| `That code isn't valid, has expired or was already used.` | Field error | |
| `networkSetup.join` = "Join" | Button | [tight] Verb: join the test with the code. |
| `Set up your Stellar account` | Step | |
| `Creates your account and adds USDC. DyorHQ pays the network fees and the reserve, so you spend nothing.` | Step detail | "Reserve": the XLM every Stellar account must hold. DyorHQ pays it. |
| `On testnet you also get %@ test XLM.` | Step detail | %@ is a number formatted for the locale (10,000). |
| `networkSetup.setUp` = "Set up" · `Setting up… This can take a few seconds.` · `Ready` | Button and details | |
| `Unlock was cancelled.` | Error | |
| `That passkey is for a different account. Use this account's passkey.` | Error | |
| `DyorHQ on Stellar is paused for maintenance. Monad is unaffected.` | Error | |
| `Update DyorHQ to use Stellar.` | Error | |
| `Access to Stellar was turned off for this account.` | Error | |
| `Too many tries. Wait a moment and try again.` | Error | |
| `Couldn't set up your Stellar account. Nothing was spent.` | Error | |
| `Unlock again to continue.` | Step detail after the key was dropped | |
| `Stellar testnet` · `Stellar account` | Profile | |
| `Testnet balances have no value. DyorHQ pays the Stellar network fees.` | Profile footer | |
| `On the Stellar testnet.` | Profile Wallet footer | |
| `DyorHQ %@ · Stellar testnet` | Menu footer | %@ is the app version. |
| `stellarTab.earn` = "Earn" | Menu row and tab | [tight] The Stellar section for lending to earn interest. |
| `Balance and activity` · `Lend XLM and USDC on Blend` · `Launch and trade coins on Stellar` · `Collect editions on Stellar` | Menu subtitles (Stellar) | "Blend" is a lending protocol's name. |
| `Stellar is off for now. You're back on Monad.` | Notice | |

Reused keys: `Try again`, `Close`, `Back`, `Network`, `Chain`, `Monad mainnet`, `Search tokens…`,
`No connection. Check your network and try again.`, `Unlock with %@`.

**DyorLite catalog.** New `Resources/Localizable.xcstrings` in the package (§8.2):

- "Valued at reference prices. Testnet assets have no value."
- "Unlock to see your Stellar balance."
- "Unlock with %@"
- "Switch to Monad"
- Bridge · Deposit · Withdraw · Swap (noun) · Add cash
- My Holdings · Activity · Reading your balances… · Reading your activity… · Earning on Blend
- Nothing yet. Add cash or swap to get started.
- Done · Pending · Failed
- Choose a Token · Symbol, name or address · No Stellar tokens match “%@”. · Monad tokens show when you switch to Monad.
- Stellar address · Secured by · Reserves paid by DyorHQ · Show Stellar secret key · Get %@ test XLM ·
  Sign out of Stellar · "Sign out of Stellar on this iPhone?" · "You'll unlock and sign in again to use Stellar.
  Your Stellar funds stay in your account."

**Lite strings that change or go**

| File:line (multichain-stellar) | Today | New |
|---|---|---|
| `LiteStore.swift:50 / :54 / :58` | "DyorHQ Lite is paused… Pro is unaffected." · "Update DyorHQ to use Lite." · "…match the Lite network…" | "DyorHQ on Stellar is paused for maintenance. Monad is unaffected." · "Update DyorHQ to use Stellar." (both) |
| `LiteStore.swift:78` (prompt reason) | "Sign in to DyorHQ Lite" | "Unlock your Stellar key" |
| `LiteStore.swift:213` | "Open Lite from DyorHQ to move funds from Monad." | "Move funds from Monad inside DyorHQ." |
| `LiteRootView.swift:20, 27, 32, 74–75, 86, 93, 120, 127` | Opening Lite…, Lite isn't available, Back to Pro, DyorHQ Lite, Join Lite, Set up Lite | Deleted (the host sheet and Stellar Home states replace them) |
| `LiteHomeView.swift:30, 34` | "Lite", "Lite settings" | Deleted |
| `LiteHomeView.swift:66–70` | Add cash · Send · Receive · Swap · Monad | Bridge · Deposit · Withdraw · Swap · Add cash |
| `LiteHomeView.swift:299` | "…use Monad on the Home screen." | "…use Bridge on Home." |
| `LiteSettingsView.swift:45–46, 50` | Switch to Pro (Monad) · Sign out of Lite · Lite settings | Deleted · Sign out of Stellar · Stellar account |
| `CashAndBridge.swift:152` | "Your Pro wallet sends USDC on Monad; it arrives in Lite…" / "USDC leaves Lite now…" | "Your Monad wallet sends the USDC. It arrives on Stellar in about a minute." / "The USDC leaves Stellar now. You claim it on Monad with your Monad wallet once Circle confirms, in a few minutes." |
| `CashAndBridge.swift:166, 168` | "Move to Lite" · title "Monad" | "Move to Stellar" · "Bridge" |
| `LiteTheme.swift:88, 110–117` | "TESTNET" · ModePill strings | "Testnet" · deleted |
| StellarKit `LiteAPI.swift:17–18, 266` | "…DyorHQ Lite…" | "Sign in on Stellar to continue." · "DyorHQ on Stellar isn't reachable right now. Check your connection and try again." · "DyorHQ on Stellar answered %d." |
| Backend `auth.ts:96, 99, 106, 154` | "DyorHQ Lite …" | The app never shows these: it maps `not_invited`, `bad_invite` and `access_revoked` to its own copy. Reword them in the same pass. |
| `LiteAPI.swift:58` | "DyorHQ Lite sign-in\nNetwork: " | Leave. It is a protocol string inside the signed challenge, not UI, and changing it needs a backend change. |

---

## 4. States and errors

| State | Where | Copy | Actions | Haptic |
|---|---|---|---|---|
| Stellar unavailable for this sign-in | Select row | "Not available for %@ sign-in yet." / "…while watching an address." | Row disabled; button stays "Switch network" | — |
| Stellar key not on this iPhone (email & password or imported, signed in before Stellar support) | Select row | "Sign in again with your email and password…" / "Import this wallet again…" | Row disabled | — |
| Server paused (`config.flags.enabled == false`) | Setup (silent check) or Stellar Home | "DyorHQ on Stellar is paused for maintenance. Monad is unaffected." | Close · on Stellar Home: Switch to Monad | error |
| Build too old, or sponsor mismatch | Same | "Update DyorHQ to use Stellar." | Same | error |
| Offline or timeout (10 s) at any step | Failed row | "No connection. Check your network and try again." | Try again (same step) | error |
| Passkey or Face ID cancelled | Unlock row | "Unlock was cancelled." | Try again | error |
| Passkey of another account (`badMnemonic`, address mismatch) | Unlock row | "That passkey is for a different account. Use this account's passkey." | Try again | error |
| No Stellar key on the device (`badSeed`, `notPrepared`) | Unlock row | Key-not-on-this-iPhone copy | Close | error |
| Key dropped (120 s idle) | Unlock row returns to pending | "Unlock again to continue." | Next Join / Set up unlocks first | — |
| Not invited | Sign in row → invite | "DyorHQ on Stellar is invite-only while we test it." | Join | — |
| Invite rejected | Under the field | "That code isn't valid, has expired or was already used." | Edit, Join | error |
| Access revoked | Sign in row | "Access to Stellar was turned off for this account." | Close | error |
| Rate limited (`rate_limited`) | Failed row | "Too many tries. Wait a moment and try again." | Try again | error |
| Setup transaction failed | Set up row | "Couldn't set up your Stellar account. Nothing was spent." | Try again | error |
| Server message with no mapping | Failed row | The server's text, through `describe(error)` | Try again | error |
| Session expired at cold launch | Stellar Home | "Unlock to see your Stellar balance." | Unlock with Face ID | — |
| Flag turned off while on Stellar | Notice capsule | "Stellar is off for now. You're back on Monad." | — | warning |
| Loading after a switch | Stellar Home | Placeholders; "Reading your balances…" | Pull to refresh | — |
| Read failed on Stellar Home | Header capsule icon; row with Retry | `store.lastError` | Retry | — |

**Return to Monad.** It can't fail: there is no work to do. Errors on Stellar never block "Switch to Monad".

---

## 5. Motion and haptics

The spatial model is Monad first (leading) and Stellar second (trailing), the same order as the sheet rows. Durations
follow the design system: 140 ms tactile, 220 ms selection, 320 ms panels.

| Moment | Motion | Timing | Reduce Motion |
|---|---|---|---|
| Chip press | scale 0.97, opacity 0.85 | 140 ms ease-out | opacity only |
| Sheet open / close | system sheet | system | system (reduced by iOS) |
| Select → Confirm → Setup | content crossfade + height change | 220 ms `.snappy` | content cuts; height stays system |
| Step status icon | `.symbolEffect(.replace)` | 220 ms | instant |
| Done ✓ on the route | scale 0.6 → 1 + fade | 220 ms spring | fade only |
| Swap seen from Home | `.transition(.push(from: .trailing))` into Stellar, `.push(from: .leading)` into Monad. The tab bar moves with its Home. | 320 ms `.smooth` | instant cut |
| Swap under Profile | none (`disablesAnimations`), then a 0.4 s hold and the system cover dismissal | — | hold 0 s |
| Figures arriving | existing `numericText`; saved figures never animate (HomeView.swift:56–59, :82–91) | — | — |

| Event | Haptic |
|---|---|
| Chip tap, Profile row tap | `Haptics.tap()` |
| Row selected in Select | `Haptics.selection()` |
| Switch to…, Next, Join, Set up, Try again | `Haptics.commit()` (built into `PrimaryButton`) |
| Instant swap lands | nothing more |
| Setup done | `Haptics.success()` |
| Step failed, invite rejected | `Haptics.error()` |
| Flag off, sent back to Monad | `Haptics.warning()` |
| Stellar tab change | `.sensoryFeedback(.selection, trigger:)` |

---

## 6. Accessibility

**VoiceOver**

| Element | Label | Value / traits | Hint |
|---|---|---|---|
| Network chip (both Homes) | "Network: Monad" / "Network: Stellar, test network" | button | "Changes the network." |
| Profile Network row | same | button | same |
| Select row | "Monad. Spot, perps, launches and Moments" | `.isSelected` on the ✓ row; value "Current network" on the current one | — |
| Unavailable row | "Stellar, test network. Not available for Apple sign-in yet." | not enabled | — |
| ✕ / ‹ | "Close" / "Back" (existing keys) | button | — |
| NetworkRoute | "From Monad to Stellar" | image | — |
| Setup row | "{title}. {Done / In progress / Needs you / Failed}. {detail}" | combined element | — |
| Invite field | "Invite code" (the visible label) | text field | — |
| TestnetBadge | "Test network" | — | — |
| Locked card | "Stellar balance, locked." followed by the button "Unlock with Face ID" | — | — |

**Announcements and focus**

- When a step finishes: `AccessibilityNotification.Announcement`, for example "Unlocked" or "Signed in".
- When the invite field appears: `@AccessibilityFocusState` moves focus to it.
- On failure: focus moves to the failed row.
- On done: "You're on Stellar".
- After a swap: `.screenChanged`, with focus on the chip of the new Home.

**Dynamic Type, up to AX5**

- Chip: the badge drops below the capsule (`ViewThatFits`). The mark grows with `@ScaledMetric`.
- Sheet: the fitted detent grows until it reaches 85 %, then `.large` with a `ScrollView`. The primary button stays
  pinned at the bottom.
- Select rows: subtitles wrap and the mark scales up to 52.
- Setup rows: the icon column scales and the text wraps.
- Stellar tiles: 5 in a row up to xxxLarge, then a 3 + 2 grid.
- Hero: keeps `minimumScaleFactor(0.6)` (existing); the chip row wraps.
- Nothing is truncated to make a figure fit.

**Contrast**

| Pair | Light | Dark |
|---|---|---|
| TestnetBadge (Attention on 14 % Attention) | 5.4:1 | 7.5:1 |
| Failed step detail (Attention on `systemBackground`) | 6.6:1 | 12.7:1 |
| Brand ✓ and stroke (graphics on `tertiarySystemFill`, 3:1 needed) | 3.3:1 | 5.1:1 |
| White on Brand (existing `PrimaryButton` pairing, kept) | 3.8:1 | 3.4:1 |

White on Brand is under 4.5:1. It is the app-wide pairing, not something this feature introduces; see open question 6.

**Dark mode**

- Every token adapts.
- The Monad disc is purple on the dark plate; the XLM disc is edged by `logoRing`.
- The sheet is black `systemBackground` with `tertiarySystemFill` rows.
- The hero and cards keep their grouped colours.

**Widths**

- **iPhone SE (375 × 667):**
  - The Stellar chip is about 163 of 311 pt.
  - Select subtitles take at most 2 lines; Confirm lines take at most 3.
  - Setup is about 470 pt of 667.
  - Tiles are about 60 pt each: labels shrink to 0.8, then the AX grid takes over.
- **Pro Max (440 × 956):** same layouts with shorter line counts. No maximum width is needed on iPhone.

---

## 7. Stellar re-skin tokens (DyorLite → DyorHQ)

The host injects these tokens as `LiteStyle`. DyorLite's defaults mirror the same hex values for LiteHarness.

| Role | DyorLite today | Use | DyorHQ source (d387a64) |
|---|---|---|---|
| Accent and tint | teal `rgb(0.05, 0.62, 0.56)` (`LiteTheme.swift:7`); `.tint` at `LiteRootView.swift:39` | `Color.brand`: #836EF9 light / #8B78FA dark. Inherit the app tint; no override. | Colors.swift:15; `Brand.colorset` |
| Canvas | `systemGroupedBackground` | same | HomeView.swift:61 |
| Card | `secondarySystemGroupedBackground`, radius 20 | same colour, radius **18** continuous, padding 16 | `cardBackground()` HomeView.swift:756 |
| Control fill | — | `Color(.tertiarySystemFill)` | HomeView.swift:241; PerpTradeView.swift:2098 |
| Positive | `Color.green` | `Color.positive` #126A4B / #77D8AC, always with a sign or word | Colors.swift:8 |
| Negative | `Color.red` | `Color.negative` #AD3047 / #F496AA | Colors.swift:9 |
| Attention | `.orange` | `Color.attention` #775812 / #E4C67D | Colors.swift:10 |
| Label on a status fill | white | `Color.onStatus` | Colors.swift:19 |
| Hero figure | 44 pt bold rounded | 40 pt semibold serif, `monospacedDigit`, `minimumScaleFactor(0.6)`, `numericText` | HomeView.swift:140–146 |
| Stat figure / label | — | `.headline.monospacedDigit()` / `.footnote` secondary | HomeView.swift:271–277 |
| Row figures | `.body.monospacedDigit()` | `.subheadline.weight(.medium).monospacedDigit()`; sublabel `.caption` secondary | HomeView.swift:1626–1633 |
| Amount input | 34 pt semibold rounded | `.title2.weight(.medium).monospacedDigit()` | `AmountField`, Components.swift:314 |
| Primary button | `LitePrimaryButton`: `borderedProminent`, teal, radius 16, min height 52, `.headline` | `PrimaryButton` metrics: `.borderedProminent`, `.controlSize(.large)`, capsule on iOS 26 (radius 12 before), semibold label, white on Brand. Busy = spinner + disabled; unavailable = solid `systemGray5`; `Haptics.commit()`. | Components.swift:478–556 |
| Secondary button | `.bordered` | `.bordered` + `.buttonBorderShape(.capsule)` | `AmountField` Max button, Components.swift:314 |
| Action tiles | card colour, radius 16, accent foreground, `.title2` symbol | `HomeAction` (body semibold symbol at 24 pt height, caption medium, 12 v, radius 14, `.primary`) | HomeView.swift:544–564 |
| Badge | "TESTNET", caption2 bold, orange 18 %, 8 h / 3 v | `TestnetBadge` = `UnverifiedBadge` metrics | Components.swift:156–164 |
| Coin discs | `AssetBadge` letters on coloured discs | LogoDisc look (plate + `logoRing` 0.5 pt); bundled logos when present, letters otherwise | Components.swift:44–105; Theme.swift:250 |
| Picker-style sheet header | nav bar + "Close" | `SheetHeader` | PerpTradeView.swift:2212–2226 |
| Form sheets | `Form` + Close | keep, with `.presentationBackground(Color(.systemGroupedBackground))` | Perps/PerpTriggerSheets.swift:146 |
| Errors | `Text(error).foregroundStyle(.red)` | `InlineError` (footnote, attention, triangle, `Paragraph`) | Components.swift:420–458 |
| Loading | `ProgressView("Opening Lite…")` | `unreadFigure` placeholders + "Reading …" rows | HomeView.swift:763–771, 485–496 |
| Change % | — | `ChangeText` / `ChangeBadge` | Components.swift:234–267 |
| Earn APY | `.headline`, positive green | `.headline.monospacedDigit()`, `.primary`. A rate isn't a gain. | design system: status colour only with meaning |
| Charts / curve progress | teal | `Color.brand` line; area Brand 12 % → 0 | — |
| Radii | 20 / 16 | card 18 · option row 16 · tile 14 · field 12 · badge capsule | — |
| Spacing | 16 | screen 16 h / 12 v · cards 16 apart · card padding 16 · tiles 10 apart | HomeView.swift:35, 53–54, 297 |
| Network switch UI | `ModePill` (`LiteTheme.swift:97–128`) | **Deleted.** The host chip replaces it. | — |

---

## 8. Implementation map

### 8.1 DyorHQ app (`ios/DyorHQ/…` at d387a64)

Hooks in existing files go inside `#if STELLAR_LITE`. The App Store project builds exactly as build 23. The new UI
lives in `ios/DyorHQ/Lite/`, which only the internal project compiles.

| File | Change |
|---|---|
| `App/RootView.swift:34–40` | `.signedIn` shows `NetworkRoot()`. This replaces the drop-in `ProLiteRoot()` already wired on `lite/network-switch`. |
| `App/RootView.swift:307–333` (`MainTabView`) | Extract the two `.fullScreenCover`s (:322–331) into an `AppCovers` modifier. `MainTabView(hostsCovers: Bool = true)` applies it only when true. `NetworkRoot` applies it **above** the swap, so the menu and Profile survive a network change. |
| `App/Router.swift:44–233` | Add `var network: AppNetwork = .monad`, `var stellarTab: LiteTab = .home` and `var networkSheet: NetworkSheetRequest?` (origin `.home`). Add `ensureMonad()` and call it first in `deliverPendingLink` :127, `deliverPendingNotificationRoute` :111, `open(route:)` :203, `openSwap` :139, `openPerp` :146, `openLaunch` :153, `openMoment` :183/:190, and `open(_ item:)` :220 for Monad items. |
| `App/Router.swift:282–326` (`MenuItem`) | Add `.earn` (title `stellarTab.earn`, symbol `leaf`), `static func items(for: AppNetwork)`, and Stellar subtitles. Route Stellar items to `stellarTab`. |
| `Home/HomeView.swift:134–179` (`heroCard`) | Add the chip row as the first child and the top padding of 10 (§3.2). |
| `Home/HomeView.swift:1516–1605` (`HomeHeader`) | Add `init(onSearch: @escaping () -> Void, error:, updatedAt:)` that stores a closure. The binding init forwards to it. No visual change; unflagged. |
| `Menu/SideMenuView.swift:24, 85–90, 120–129` | Rows from `MenuItem.items(for:)`, the footer per network, and `isCurrent` for Stellar tabs. No other change. |
| `Profile/ProfileView.swift:98–101` | Network section (§3.5): chip row, per-network rows, footer, and the sheet with origin `.profile`. |
| `Profile/ProfileView.swift:47–57` | Wallet section follows the network on Stellar (§3.5). |
| `Perps/PerpTradeView.swift:2212–2226` → `Design/Components.swift` | Promote `sheetHeader` to `SheetHeader` (back and close variants). Perps calls it. Unflagged, no visual change. |
| `Resources/TokenLogos/logo-XLM.png` | New: the Stellar mark, used through `MarketLogo`. |
| `Resources/Localizable.xcstrings` | New keys (§3.7), with es / fr / zh-Hans / ko. |
| `App/AppEnvironment.swift` | `stellarLiteEnabled`, already added on the branch from `RemoteFlags.stellarLite`. No further change. |

**New files in `ios/DyorHQ/Lite/`** (internal project only)

| File | Contents |
|---|---|
| `NetworkRoot.swift` | Replaces `ProLiteRoot.swift`.<br>• Owns one `LiteSession` per account (keyed by address).<br>• Reads and writes `network.<address>` and migrates `lite.mode.*`.<br>• Shows `MainTabView(hostsCovers: false)` or `LiteRootView(session:selection:style:chrome:)`, with the push transition keyed on direction.<br>• Applies `AppCovers`.<br>• Presents the network sheet for origin `.home`.<br>• Builds `LiteChrome` (header = `HomeHeader(onSearch:…)`, chip = `NetworkChip(.stellar)`, unlock, switchToMonad).<br>• Runs the lifecycle rules (§2.6). |
| `AppNetwork.swift` | `enum AppNetwork { case monad, stellar }`: verbatim name, mark symbol, `isTestnet`, chain label. `NetworkAvailability` (offered / reason) from `LiteGate`. The intro flag. |
| `NetworkChip.swift` | `NetworkMark`, `TestnetBadge`, `NetworkChip`, `NetworkChipRow`, `NetworkRoute` (§3.1). |
| `NetworkSheet.swift` | `NetworkSheet` (Select, Confirm, Setup) driving `LiteSession`. `NetworkSheetRequest { origin; startAt }`. A `.networkSheet(_:)` modifier attached at `NetworkRoot` (home) and `ProfileView` (profile), because a sheet must come from the topmost presenter. |
| `NetworkSwitcher.swift` | `@Observable` coordinator: `plan(to:)` (§2.3), `commit(to:origin:)` (choreography in §2.5), and the inline Setup for the locked card. |
| `LiteMode.swift` (drop-in) | Delete `AppMode` (:9–21). `LiteGate.isAvailable` (:26–34) becomes `availability(session:serverFlag:) -> NetworkAvailability`, returning reasons for unsupported methods, watch-only, and no key on the device. |
| `DyorHQLiteKeys.swift` (drop-in) | Add `unlock(session:reason:) async throws -> LiteSession.UnlockResult`:<br>• Mera: one `session.mera.revealPhrase(expecting:)` → SEP-5 signer, and store the address.<br>• Stored seed: `BiometricGate.authenticate(reason:)` (Theme.swift:133, so the privacy cover stays off behind Face ID; today's `StoredSeedKeyProvider` LAContext doesn't do this), then the Keychain seed.<br>Extend `LiteKeyBootstrap.forget` (:94–98) with the new keys. |
| `ProLiteRoot.swift` | Delete. |

### 8.2 DyorLite package (`multichain-stellar/ios/Packages/DyorLite/Sources/DyorLite/…`)

| File | Change |
|---|---|
| `Core/LiteSession.swift` (new) | The host-owned session, setup run and signer cache (API in §8.3). Moves `start` / `signIn` / `afterSignIn` / `activate` out of `LiteStore` (:46–100). Caches `lite.activated.<G…>`. |
| `Core/LiteStore.swift` | Data and actions only. `Phase` (:9–15) and the session code go. The init becomes internal and is made by `LiteSession`. Renamed strings (§3.7). |
| `Core/LiteHost.swift` | Add `LiteTab`, `LiteStyle` (+ environment key), `LiteHeaderContext` and `LiteChrome`. |
| `LiteRootView.swift` | New init. The states become ready → tabs, locked → Home with the locked card, unavailable → Home with the paused card. `InviteView` / `ActivationView` (:62–132) move to LiteHarness. Remove `.tint` (:39). |
| `Home/LiteHomeView.swift` | Header and chip through the chrome; new hero; tiles; My Holdings; Activity; locked and paused states. Remove the ModePill, title, gear and settings sheet. |
| `Home/LiteSearchSheet.swift` (new) | Stellar search (§3.3). |
| `Settings/LiteSettingsView.swift` | Becomes public `LiteAccountView(session:)`: no `NavigationStack` or Close, no "Switch to Pro", a sign-out confirmation. Also expose `LiteDepositSheet(session:)` and `LiteWithdrawSheet(session:)` for Profile. |
| `Support/LiteTheme.swift` | Read tokens from `LiteStyle` (§7). Delete `ModePill`. Restyle `TestnetBadge`. `LitePrimaryButton` takes `PrimaryButton` metrics; `LiteCard` radius 18; `AssetBadge` takes the disc look. |
| `Confirm/`, `Earn/`, `Launch/`, `Moments/`, `Cash/` | Mechanical token swaps and string renames (§3.7, §7). |
| `Package.swift` + `Support/LiteL10n.swift` + `Resources/Localizable.xcstrings` | `defaultLocalization: "en"` and resources. `LiteL10n` mirrors DyorKit's `L10n` (DyorKit `Core/L10n.swift`): the package catalog and a `locale` the host sets with `L10n.locale`, so in-app language changes reach Stellar screens. |
| LiteHarness | Hosts the moved invite and account-setup views, driven by `LiteSession`. |

### 8.3 Minimal public API DyorLite exposes

```swift
public enum LiteTab: String, CaseIterable, Hashable, Sendable { case home, earn, launch, moments }

public struct LiteStyle: Sendable {                       // DyorHQ tokens, set by the host
    public var accent, positive, negative, attention, onStatus: Color
    public static let `default`: LiteStyle                // mirrors DyorHQ's colorsets (for LiteHarness)
}

public struct LiteHeaderContext {                         // what Stellar Home hands the host's header
    public let openSearch: () -> Void
    public let error: String?
    public let updatedAt: Date?
}

public struct LiteChrome {                                // host-rendered pieces embedded by Stellar screens
    public init(header: @escaping (LiteHeaderContext) -> AnyView,
                networkChip: @escaping () -> AnyView,
                unlock: @escaping () -> Void,             // locked card
                switchToMonad: @escaping () -> Void)      // paused / update-needed card
}

@MainActor @Observable
public final class LiteSession {                          // one per signed-in account; outlives network switches
    public struct UnlockResult: Sendable { public let keys: LiteKeyProvider; public let signer: StellarSigner }
    public enum Step: Hashable, Sendable { case unlock, signIn, invite, setUp }
    public enum StepStatus: Equatable, Sendable { case pending, running, needsYou, done, failed(Failure) }
    public enum Failure: Equatable, Sendable {
        case offline, cancelled, otherAccountsKey, keyNotOnDevice, paused, updateRequired,
             inviteRejected, accessRevoked, rateLimited, setUpFailed, server(String)
    }
    public enum Plan: Equatable, Sendable { case instant, setup([Step]) }
    public enum State: Equatable, Sendable {
        case idle, running, waiting(Step), ready, locked, unavailable(Failure), failed(Step?, Failure)
    }
    public struct StepRow: Identifiable, Equatable, Sendable { public let step: Step; public let status: StepStatus }

    public init(env: LiteEnvironment, stellarAddress: String?, monad: LiteMonadBridge?,
                unlock: @escaping @Sendable (_ reason: String) async throws -> UnlockResult)

    public private(set) var state: State
    public private(set) var steps: [StepRow]
    public var store: LiteStore? { get }                  // non-nil once signed in

    public func plan() -> Plan                            // local: no network, no prompt
    public func run() async                               // check → [unlock] → [sign in] → [set up];
                                                          // pauses at .waiting(.invite / .setUp)
    public func join(invite code: String) async
    public func setUp() async
    public func retry() async
    public func cancel()                                  // drops the signer; keeps what finished
    public func resumeAtLaunch() async                    // restores silently → .ready or .locked; never prompts
    public func signOut() async                           // ends the Stellar session on this iPhone
}

public struct LiteRootView: View {
    public init(session: LiteSession, selection: Binding<LiteTab>, style: LiteStyle, chrome: LiteChrome)
}
public struct LiteAccountView: View   { public init(session: LiteSession) }   // Profile › Network › Stellar account
public struct LiteDepositSheet: View  { public init(session: LiteSession) }   // Profile Wallet on Stellar
public struct LiteWithdrawSheet: View { public init(session: LiteSession) }
public enum LiteL10n { public static var locale: Locale }                      // the host sets it with L10n.locale
```

The signer from `unlock` is used for the sign-in (and its retry with an invite) and for the setup plan. It is dropped
when the run ends, on `cancel()`, or after 120 s idle in `.waiting`. It is never written anywhere.

### 8.4 Build order and checks

**Build order**

1. DyorLite: `LiteSession` and the `LiteHost` types; tokens and strings. Build it with LiteHarness.
2. App: `AppNetwork`, `NetworkChip`, `SheetHeader` promotion, `logo-XLM`.
3. App: `NetworkSheet` against `LiteSession`.
4. App: `NetworkRoot`, `AppCovers` hoist, Router changes.
5. App hooks: Home chip row, `HomeHeader` init, menu, Profile.
6. Stellar Home re-skin; search; `LiteAccountView`.
7. String catalogs and translations.

**Checks**

- First switch, passkey account: exactly one passkey prompt.
- First switch, email & password and imported: one Face ID prompt.
- Invite: a bad code, then a good one.
- Account setup completes and lands on Stellar Home.
- ✕ at each step, then a resume that skips Confirm.
- Offline at each step.
- Server paused: fails before any prompt.
- Return to Monad: instant, and Monad Home matches build 23.
- Cold launch on Stellar with a valid session and with an expired one: no prompt either way.
- Moment link and alert tap while on Stellar.
- Flag turned off while on Stellar.
- Sign-out while on Stellar.
- VoiceOver walk-through; AX5; iPhone SE and Pro Max; light and dark; all five languages.
- `DyorHQ.xcodeproj` Release shows no chip, and `nm` shows no Lite symbols.

---

## 9. Open questions for the owner

1. **Confirm step.** First switch to Stellar only, or every time (as in Miracle)?
   Recommendation: first time only. After that it repeats what the user knows and invites tapping through.
2. **One unlock per setup.** Hold the Stellar signer in memory for one setup run (at most 120 s idle) so the first switch
   asks for the passkey or Face ID once, not up to four times? This changes "words never outlive the call" for that one
   run.
   Recommendation: yes. Nothing is stored, and the run is short and user-started.
3. **Accounts that can't use Stellar** (Apple, Google, email code, Privy passkey, watch-only) in the internal build:
   show the chip with a disabled Stellar row and the reason, or hide the chip?
   Recommendation: show it. Invited testers then see why instead of a missing feature.
4. **Accounts signed in before Stellar support** (email & password, imported): today they must sign in again or
   re-import.
   Recommendation: a follow-up that adds an in-sheet "Enter your password" or "Enter your recovery phrase" step, instead
   of sending people to sign out.
5. **Profile's Wallet section follows the network on Stellar.**
   Recommendation: yes. Otherwise Profile › Receive shows a Monad address while the user is on Stellar.
6. **White on Brand** (3.8:1 light, 3.4:1 dark) on every prominent button.
   Recommendation: review app-wide in a separate pass, for example an `onBrand` label colour like `onStatus`. This
   feature keeps the current pairing.
7. **Mainnet later.** The Testnet badge, the testnet lines and "Stellar testnet" are driven by the server's network
   name.
   Recommendation: keep that, so mainnet needs no copy change.
