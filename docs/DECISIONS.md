# Decisions

Each entry is short: the decision, why, and what would change it.

1. **Lite is a mode of the same app, not a second app** (owner, 2026-10-11). One account, one secret, a pill that
   swaps Pro (Monad) for Lite (Stellar). Lite = save, earn, swap, launch, collect, cash in/out. Pro keeps perps,
   memecoins and Moments coins.
2. **Perps become Earn (Blend v2).** Stellar has no perps venue with Perpl's depth. Lending gives Lite a yield
   product with no leverage or liquidation for the user.
3. **Moments on Stellar are in-app SEP-50 editions without coins.** OpenSea does not support Stellar, and no
   marketplace indexes Soroban NFTs. The split is 95% to the creator and 5% to the platform (capped at 10%), plus a
   5% royalty recorded for future marketplaces. Moments coins stay on Monad.
4. **Launchpad economics mirror Monad.** 1B supply, 1% fee split 50/50, creator fee up to 10%, anti-snipe tax by
   ledger (98/25/3/0.3%), threshold = phantom · (√10 − 1).
5. **Launch tokens are curve-only until graduation** (the transfer lock). This prevents pre-seeded pools.
   Graduation deposits straight into the Soroswap pair, not through the router, so a dust or `sync` griefer can't
   block it. LP stays in the launchpad forever.
6. **The server builds, the phone verifies and signs, the sponsor fee-bumps.** Users hold 0 XLM for fees. The
   sponsor pays only for transactions whose hash the API built, within a daily budget per user.
7. **Two limits on the phone.**
   - Each transaction is checked against its intent: pinned contracts, function names, op types, source-account auth,
     outflow from the authorized invocation tree.
   - The whole plan is checked against the amounts the user typed. A compromised API can't widen either.
8. **StellarKit is pure Swift + swift-crypto, not the Soneso SDK** (changed during the build). Lite signs only a small
   subset of XDR, and a strict decoder that rejects anything else is safer than a full SDK. It also runs on Linux CI,
   where it is held to the server verifier by 39 shared vectors. Soneso remains an option for OZ smart accounts later.
9. **soroban-sdk 26.1 + OpenZeppelin stellar-tokens 0.7.2.** OZ requires SDK 26, and SDK-26 contracts run unchanged on
   protocol 29. Spec shaking v2 is applied by `tools/spec-shake`, so builds don't need the full stellar-cli. That
   install OOMs on small CI machines.
10. **Contracts never extend their own instance in a user's call.** Extending an instance also extends its WASM, and
    measured on testnet that costs about 70 XLM a month per 50 KB. The keeper (sponsor) does it.
11. **Simulation headroom +25% instructions, +20% bytes, +30% resource fee.** A Blend withdraw failed on-chain without
    it (interest accrues between simulation and execution). The sponsor pays the margin.
12. **Canonical testnet USDC = Circle's (`GBBD47IF…`).** It is the one used by testanchor, CCTP, SDEX and Soroswap.
    Blend's testnet USDC is labeled as a test asset. Mainnet has one USDC.
13. **Testnet accounts are created by Friendbot (10,000 test XLM).** Mainnet accounts are created with sponsored
    reserves (both are implemented). Trustlines are always sponsored.
14. **Bridge.** Testnet uses CCTP v2: Monad testnet (15) ↔ Stellar testnet (27), verified registered both ways.
    Mainnet uses NEAR Intents 1Click. For Stellar → Monad, the burn needs an `approve` first, and Iris indexes the
    fee-bump hash. Claims run through the Pro wallet.
15. **A separate Supabase project with RLS deny-all.** The client talks only to the `lite` function, so PostgREST
    exposes nothing.
16. **Invite-only.**
    - Three gates: the build flag, the server flag (default off) and the tester allowlist.
    - Revocation is immediate.
