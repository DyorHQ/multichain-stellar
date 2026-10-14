# DyorHQ backend (Supabase)

Backs the parts of DyorHQ that are not on chain: wallet sign-in sessions (`wallet-auth`), email-and-password
accounts (`email-pepper`, `email-rebind`, `delete-account`), profiles, follows, feed, comments, leaderboards and
referrals, price and push alerts with their devices, a launch-discovery index, activity and cross-device sync,
Moment media pinning (`pin-media`), the bridge quote proxy (`aurora-proxy`) and a cache of the wallet history the app
reads from the chain (`history-indexer`, migration 32: see "Wallet history cache" below). The core app stays
self-custodial and on-chain; **no private keys or the Perpl Ed25519 secret are ever stored here.**

- **Project:** `DyorHQ` · ref `fmnjqrguvopusfufmirs` · region eu-west-1 · Postgres 17
- **URL:** `https://fmnjqrguvopusfufmirs.supabase.co`
- **App keys (safe to embed):** publishable key `sb_publishable_s1G3ns-jmzTfnFs7rTvdbQ_8FJYODhT` (RLS protects data).
  Embedded in the iOS app (`ios/DyorHQ/Config/AppConfig.swift`).

## Auth (login stays in Privy)

The app has the Privy wallet `personal_sign` a sign-in message around a fresh server nonce (EIP-4361 bound to
dyorhq.fun and chain 143, or the legacy template until `WALLET_AUTH_LEGACY_SIGNIN=off`); the **`wallet-auth`** Edge
Function (`functions/wallet-auth/`) recovers the signer, checks freshness, consumes the nonce, and mints a Supabase JWT
with a `wallet_address` claim, valid for 12 hours (`WALLET_AUTH_SESSION_S` can shorten it; it cannot be revoked
earlier). A wallet's first sign-in (no profile row yet) is limited per client network, because wallets cost nothing.
Every RLS policy keys off `public.app_wallet()` = that claim (lowercased). Public data is world-readable with the
publishable key; writes require the wallet's session.

**Signing key:** `APP_JWT_SECRET`, the project's legacy **JWT Secret** (HS256), until the owner moves sessions to a
dedicated ES256 key, `APP_JWT_SIGNING_JWK` (see "Session signing key" below), which then takes precedence. Either way
PostgREST accepts the tokens. pin-media and aurora-proxy verify sessions in code with the same keys: `APP_JWT_SECRET`
for HS256 and the project's JWKS for ES256.

## Schema (applied as migrations 01–07, RLS on every table, security advisor clean)

| Area | Tables |
|---|---|
| Foundation/sync | `profiles`, `follows`, `watchlist`, `user_settings` |
| Social | `posts`, `comments`, `reactions`, `referral_codes`, `referrals`, `leaderboard` |
| Alerts/push | `device_tokens`, `alerts` |
| Launch index | `launches` |
| App sync (mig. 11) | `activity` (every action: kind, section, USD size + fee, tx hash), `notifications` |
| Sessions (mig. 14) | `sessions` (one row per sign-in — `signed_in_at`, `signed_out_at`) |
| Journey (mig. 12–14) | `user_journey` (view — one row per user: handle, wallet, `joined_at`, sign-in/out times, per-domain spot/perps/launchpad/moments/bridge/deposits/withdrawals rollup; **internal analytics only**, not granted to anon/authenticated), `platform_journey()` (platform totals by domain) |
| Hardening 2026-09-26 (mig. 24–29) | `app_config` (public, read-only: `ios.min_build`), `waitlist`, `upload_blocklist`, `storage_upload_events` (launch-media's overall budget), `edge_rate_events` / `edge_rate_salt` (owner-only rate ledger); triggers `dyorhq_storage_upload_gate` and `dyorhq_launch_media_write_once` on `storage.objects` |
| Wallet history cache (mig. 32) | `history_scans`, `history_wallets`, `history_wallet_scans`, `history_logs`, `history_subject_caps`, `history_indexer_state`, `history_indexer_runs` (no API role may read or write any of them; the app reads through `history_read()`); triggers `profiles_history_enrol` / `profiles_history_forget` on `profiles` |

`activity.kind` ∈ swap, buy, sell, launch, perp, moment, **bridge**, **deposit**, **withdraw**, send; `activity.section`
∈ spot, perps, launch(pad), moments, bridge, wallet. The whole user journey — username (`profiles.handle`), wallet,
per-domain volume, deposits/withdrawals, notifications and activities — is stitched by the `user_journey` view.

`migrations/` holds every migration applied to the live project, 01–28 (23–28 are the 2026-09-26 hardening); 29
(`waitlist`) is written but not applied, and its Edge Function is not deployed, because the website keeps its own
signups; 32 (`wallet_history`) is written and tested but not applied yet. `migrations-deferred/` holds two that must
wait for an app build AND for every older build to be expired in App Store Connect / TestFlight (each header says
which build; each refuses to run until armed): `30_activity_primary_key_wallet_id.sql` (the build that upserts
activity with `on_conflict=wallet,id`) and `31_launch_media_strict_write_once.sql` (the build that uploads launch-media
with `x-upsert: false`); and one that needs the platform (pg_cron, pg_net, Vault) and a deployed function:
`33_history_indexer_schedule.sql` (it refuses until armed, on any database without pg_cron and pg_net, and without
32's `history_cron_digest`; it creates the Vault secrets it needs when they are missing — the cron secret from
random bytes generated inside Postgres — and refuses an existing cron secret that is not 32–512 visible ASCII
characters; once applied it moves into `migrations/`, where `tests/migrations_test.ts`
lists it as platform-only). 01–07 and 11 were
restored on 2026-09-26 from the project's own migration history (`supabase_migrations.schema_migrations.statements`),
byte-for-byte — each file's md5 equals the recorded statements' md5. Two out-of-band changes are NOT in any
migration: the Strategies tables below were dropped directly (2026-09-18), and 18's revokes supersede 11's
`grant execute … platform_volume … to anon`.
Record every future schema change as a numbered migration here, so the backend can be rebuilt and audited from source.

> The Strategies feature (copy-trading, market-making, delta-neutral) was removed from the app on 2026-09-18; its
> tables (`strategies`, `leaders`, `copy_relationships`, `copy_grants`, `copy_events`) were dropped from the project.

## Edge Functions

`config.toml` pins each function's gateway JWT check; deploy with `supabase functions deploy <name>` from the repository
root (the CLI bundles `functions/_shared/`). Never run `supabase config push` from this repository.

| Function | verify_jwt | Caller proves | Limits |
|---|---|---|---|
| `wallet-auth` | false | a wallet signature over a server nonce (EIP-4361, or the legacy template until switched off) | single-use nonce; a first sign-in: `edge_rate_gate` per network (IPv6 /48) |
| `email-pepper` | false | nothing, or a Privy email token for the verified budget | per email, per network, per Privy user |
| `email-rebind` | false | a Privy email token (≤ 15 min old) + the new wallet's signature; `replace` to move a binding once `REBIND_REQUIRE_REPLACE=on` | per Privy user |
| `delete-account` | false | a Privy token (≤ 1 h old unless `DELETE_ACCOUNT_TOKEN_MAX_AGE_S` tightens it), or the wallet session with `{"method":"email-password"}` | per Privy user / wallet |
| `pin-media` | true | a wallet session, verified in code too | `edge_rate_gate` per wallet, network and overall; 20 s budget |
| `aurora-proxy` | true | a wallet session, verified in code too; quotes only to and from that wallet | `edge_rate_gate` per wallet and network |
| `waitlist` (not deployed) | false | nothing (CORS: dyorhq.fun, www.dyorhq.fun; honeypot) | `edge_rate_gate` per network (IPv6 /48) and overall |
| `history-indexer` (not deployed) | false | the `x-history-cron` header equal to the Vault secret `history_cron_secret` (its SHA-256 compared in constant time with `history_cron_digest()`, fetched at most once a minute per isolate; or the optional `HISTORY_CRON_SECRET`); called only by pg_cron → pg_net | one run at a time (a database lease); ≤ 240 s per run and ≤ 1,000 ms of estimated CPU per isolate (half the platform's 2,000 ms); per RPC endpoint ≤ 4 requests/s (`rpc2` 2 at launch); a header never reaches the database, so callers without it cost no query |

Secrets (names only): `APP_JWT_SECRET` or `APP_JWT_SIGNING_JWK` (wallet-auth; pin-media and aurora-proxy read
`APP_JWT_SECRET` to verify HS256 sessions — secrets are project-wide), `PRIVY_APP_SECRET` (+ optional `PRIVY_APP_ID`),
`PINATA_JWT` (+ optional `PINATA_GATEWAY`), `AURORA_API_KEY` (+ optional `AURORA_FEE_RECIPIENT`, `AURORA_FEE_BPS`),
history-indexer's, all optional: `ALCHEMY_MONAD_RPC` (a keyed Alchemy Monad URL: adds the endpoint `alchemy`),
`MONAD_LOGS_ENDPOINTS` (JSON tuning the endpoints), `HISTORY_CRON_SECRET` (a second accepted header value). Vault (read
by migration 33's cron job, created by 33 when missing): `history_cron_secret` (generated inside Postgres; nobody holds
it), `history_indexer_url`, and optional `history_indexer_region` (created by hand).
`SUPABASE_URL`, the service-role key and the publishable key are injected by the platform.

Switches (unset = the behaviour the builds in use need; each header says when to flip it):
`WALLET_AUTH_LEGACY_SIGNIN=off`, `WALLET_AUTH_SESSION_S`, `REBIND_REQUIRE_REPLACE=on`,
`DELETE_ACCOUNT_TOKEN_MAX_AGE_S=900`. "Once build N is out" always means: build N has shipped AND every older build
is expired in App Store Connect / TestFlight, or is below `app_config` `min_build` (see below).

Owner procedures (the deploy order of the hardening changes, takedowns in the public buckets, the session signing
key rotation) are in DyorHQ/internal (private): `ios-app/supabase/owner-procedures.md`.

## Wallet history cache

The app's history screens (Portfolio, activity feeds, My Launchpad, My Moments, the Send sheet) are built from five log
scans (`WalletHistoryScans`, `ios/DyorKit/Sources/DyorKit/Services/WalletHistory.swift`). Monad's public endpoints cap
`eth_getLogs` at 100–10,000 blocks per request, so reading them on the device takes minutes. Migration 32 adds a server
cache of exactly those scans, filled by the `history-indexer` Edge Function, so the app can read a wallet's history with
one PostgREST call. The app's Swift decoders stay the single source of truth: the cache stores **raw logs** (the
`eth_getLogs` fields plus `blockTimestamp`) and the **exact block ranges they cover**, never totals.

**Scans.** Defined once in `functions/_shared/history-scans.json` (generated into `history_scans.ts` by
`gen_history_scans.ts`; seeded into `history_scans` by migration 32). DyorKit's `HistoryScanParityTests`,
`tests/history_cache_test.ts` and the indexer's run-start check (`defsDrift`) fail or report when the Swift scans, the
JSON and the database differ. Global scans are indexed once for every address and served per wallet by the wallet
topic: `launchpad` (six curve and escrow events, any contract, wallet = topic1), `fee-sharing` (`Claimed` on every
stack's `holderFeeSharing`, wallet = topic2), `moments` (five events on every cohort's contracts, wallet = topic2).
Wallet scans are read only for **enrolled** wallets — a `profiles` row, i.e. a signed-in DyorHQ user; watch-only
addresses are not enrolled — from genesis: `transfers-in` (`Transfer`, wallet = topic2) and `transfers-out` (wallet =
topic1). The 30-day window is read first for every wallet; below it only for wallets with on-chain activity (a first
transaction or a stored transfer). A change to a scan (a new cohort or stack, an event) is one PR touching the Swift
source, the JSON (then regenerate), and a new migration calling `history_redefine_scan(id, addresses, topic0s,
floor, valid_below)`.

**The invariant** (HistoryStore's): a block range is covered only when every log the endpoint returned for it is
stored, in the same transaction (`history_commit`, the only write path), under the scan definition version
(`def_version`) the filter was built from. A range the indexer could not read — a block too dense, or one that never
answered — is a **hole**: never covered, served as `holes` (the app reads it itself), retried after 6 hours (a new hole
never postpones the retry of older ones on the same row). A log
with more than 16 KiB of data is stored without it and listed as `omitted`. The 20,000-logs-per-wallet-and-scan cap
(`HistoryStore.logCap`) keeps the newest 20,000 and records `capFloor`; global subjects are capped at write time.

| Table | Holds |
|---|---|
| `history_scans` | each scan's definition (`kind`, `wallet_topic`, `floor_block`, `addresses`, `topic0s`, `def_version`) and, for a global scan, `covered`, `holes` and head |
| `history_wallets` | enrolled wallets: `requested_at` (every profile write), `enrolled_at`, the first-transaction result |
| `history_wallet_scans` | per wallet and wallet scan: `covered`, `holes`, `cap_floor`, head, `log_count` |
| `history_logs` | the raw logs, keyed `(scan, subject, block_number, log_index)`; `subject` = the address at the wallet topic |
| `history_subject_caps` | global scans: where a subject's kept 20,000 logs start |
| `history_indexer_state` | the indexer's lease, the owner's switches `paused` and `serving`, the last head, the endpoint memory (by label, never a URL) |
| `history_indexer_runs` | one row per run (started, released, version, stop, summary of counts — never an address); kept 7 days |

Every table has RLS on, no policies, and no privileges for anon, authenticated or service_role.

| Function | Who | What |
|---|---|---|
| `history_read(p_wallet, p_cursor, p_from_block, p_to_block, p_meta_only)` | anon, authenticated, service_role | one wallet's cached history as one JSON document, paged (below) |
| `history_lease` | service_role (the indexer) | takes or renews the lease; answers `{"ok": false, "paused": …}` (HTTP 200, not an error) while the indexer is paused or another run holds a live lease |
| `history_release` | service_role (the indexer) | ends a run (its stop and summary); idempotent, and releases the lease (head, endpoint memory) only for its holder |
| `history_state`, `history_commit`, `history_mark_hole`, `history_set_first_tx` | service_role (the indexer) | refuse with `PT409` (HTTP 409) unless the caller holds the lease and the indexer is not paused; `history_commit` and `history_mark_hole` also refuse a stale definition with `PT412`; bad arguments or answers `22023` |
| `history_cron_digest()` | service_role (the indexer) | the SHA-256 (64 hex characters) of the Vault secret `history_cron_secret`, which the indexer compares each cron header's SHA-256 with; never the secret; null when the secret is missing, not 32–512 visible ASCII characters, or Vault is unreadable |
| `history_health()`, `history_reset(scan, first_tx)`, `history_redefine_scan(…)`, `history_housekeeping()` | postgres only (SQL editor, migrations) | the dashboard, the repair after bad data, a scan change, the daily prune |

**Reading** (`POST /rest/v1/rpc/history_read` with `{"p_wallet": "0x…"}`, the publishable key or the wallet session):
the first page carries, per served scan (three global scans; the two wallet scans too when `tracked`), its `query`
(the app's filter, sorted) and `fingerprint`, `defVersion`, `floor`, `capFloor`, the bounds `from`/`to`, `covered` and
`holes` (inclusive `[from, to]` pairs), `head`/`headTimestamp`, `complete`, `omitted`, then logs newest first in
`eth_getLogs` JSON (parsed by the app's `Log(json:)`), scan by scan, at most 2,000 logs or about 1.5 MB per page; call
again with `p_cursor = next` until `next` is null. The cursor carries page 1's bounds, so later pages never serve
beyond what page 1 promised. `p_from_block`/`p_to_block` bound a read (a top-up); `p_meta_only` answers page 1's
metadata alone. `serving: false` (the owner's switch) means: discard the read and read the chain. A client adopts a
scan's coverage only up to `head − 1,200` (a clamping node's margin), never across `holes` or `omitted` blocks, and
aborts the whole read when `tracked` or a `defVersion` changes between pages. The app side is a later milestone.

**Enrolment and deletion.** `profiles_history_enrol` (after insert or update on `profiles`; ensureProfile upserts on
every launch and sign-in) enrols the wallet and moves `requested_at`; a failure never fails the profile write, and it
never waits on a lock for more than 200 ms (while `history_reset` or a scan redefinition holds the rows, enrolment
degrades to a warning: `requested_at` stays, a new wallet is enrolled at its next profile write).
Wallets not requested for 30 days are no longer followed (their data stays). `profiles_history_forget` (after delete)
removes the wallet's per-wallet cache. Global-scan rows naming a deleted wallet are public chain data indexed for every
address and are kept on purpose; run summaries hold counts only.

**The indexer** (`functions/history-indexer/`): pg_cron → pg_net calls it every 30 s (migration 33) with the
`x-history-cron` header. The header's value exists only in Vault: migration 33 generates it (32 random bytes, 64 hex
characters) and the job reads it at each tick; the function refuses an absent or implausible header itself (403: not
32–512 visible ASCII characters), then compares the header's SHA-256 in constant time with the secret's
(`history_cron_digest()`, fetched at most once a minute per isolate, one fetch at a time; a header never reaches the
database, so a flood of wrong headers costs no query and cannot lock the tick out), and answers 503 while it cannot
fetch the digest (retried every 5 s). A rotated secret (migration 33's header) takes effect within a minute. It answers 202 at once and works ≤ 240 s in `EdgeRuntime.waitUntil` under the lease: reads the
finalized head, self-tests that each `refuses` endpoint refuses a range past its head, follows the head (overlap 1,200
blocks), then backfills newest first — global gaps, wallets' 30-day windows (new wallets first), then deep history —
in aligned 10,000-block pieces shared by up to 100 wallets per filter, and finds each wallet's first transaction by
nonce bisection confirmed on a second archive endpoint. Endpoints: the public `rpc2` (10,000 blocks × 6 per request,
refuses straddling ranges; 2 requests/s and 4 in flight at launch), `rpc4`, `rpc3` (1,000 × 1) and `rpc1` (100, bare
objects: it refuses any JSON-RPC array), ≤ 4 requests/s each with AIMD pacing, Retry-After and back-off; a clamping
endpoint only reads pieces ending at least 600 blocks below the head. With `ALCHEMY_MONAD_RPC` set (an `https` URL;
otherwise one log line and the public endpoints only), `alchemy` joins them: first for backfill (global gaps, windows,
deep history), last for the follow and the head read (which keep preferring `rpc2`), clamping (the lag rule), archive
(nonce reads), bare objects at 4 requests/s and 2 in flight, at most 12,000 requests a UTC day, answers up to 8 MiB, and
an initial span of 5,000,000 blocks — so each run plans its backfill in pieces as wide as the widest span on hand (up
to 5,000,000 blocks; `rpc2` still cuts them to 10,000), Alchemy's 10,000-log cap answers with a range that fits and
the piece is split there, and a key capped at fewer blocks halves its span to the cap (remembered for a day). Its Free
tier's 10-block refusal turns its log reads off for a day, a spent month turns it off until 00:00 UTC, and an HTTP
401/403 sidelines it at once; its own error texts are never stored. No keyed URL is ever logged, stored or put in an
error: log lines, error lines and run summaries pass through `redact.ts`, and no Error object reaches `console.*`. Work waiting for a busy or resting endpoint is parked while the others go on (the follow
continues on the clamping endpoints while `rpc2` rests); a sidelined endpoint, one off for the day or one without log
reads rests the same way, until its time is up (a refusing one is self-tested again once back). Work none of its
endpoints can start before the run's read deadline (deep history while `rpc2` rests or is sidelined past it) stays
parked too — the run stops `deadline`, not `done`, and the next run plans that work again (`counts.leftParked`). Work of
a priority no endpoint may take at all (every span too narrow for it, as when `rpc2` teaches a span below 10,000 blocks
for a day, or every daily budget too full) stays in the planner, held (`counts.held`): the run reads everything else and
stops `blocked`, not `done`. `rpc2`'s HTTP 429 is a JSON-RPC error; its Retry-After is honoured (up to 60 s). An
endpoint that refuses every request (a revoked key, a spent quota, a firewall) is sidelined for 15 minutes without
turning its pieces into holes. `MONAD_LOGS_ENDPOINTS`
(optional JSON) replaces them (an array) or adds to them (`{"mode": "append", "endpoints": [...], "overrides":
{"rpc2": {"rps": 4, "inFlight": 8}, "alchemy": {"span": 10000}}}`; an override of `alchemy` without
`ALCHEMY_MONAD_RPC` is ignored); an invalid value falls back to the defaults (with `alchemy`) and a log line naming the
field, never the URL. Too dense is split (range, then
wallets, then single blocks) and finally a hole — never a cap. Adjacent answered pieces of a scan (and wallet list) are
joined into one commit, up to 40 pieces or 2,000 logs, in whatever order they answer. **CPU:** the platform stops an
isolate at 2,000 ms of CPU, counting everything it did — its start, the cron ticks it answered, every run in it — and
an RPC request costs ~1.5 ms of it, a database call ~0.4 ms (fitted to two runs on 2026-10-09), while a run can time
only its own parsing. So each isolate keeps one estimate (its start, its requests, and each run's parsing + 1.6 ms per
RPC request + 0.5 ms per database call + the bytes it streamed, cut-off answers included); a run starts only with
≥ 300 ms of 1,000 left, and stops new reads (stop `cpu`) once the estimate plus what finishing still costs reaches
1,000 ms — it then commits what it read and releases as usual. First-transaction lookups take at most a quarter of it,
and one in progress finishes its reads (`run.ts` D21, `cpu.ts`; the summary's `cpuEstimateMs`, `cpuIsolateMs`,
`counts.db` and `counts.bytes` sit next to the platform's `cpu_time_used`). Each run writes one summary line (counts only) and a
`history_indexer_runs` row. `index.ts` is the only file touching the runtime; `run.ts` is the loop; every other module
is pure, with a `*_test.ts` beside it. `print_scans.ts` prints the bundled definitions in the format of migration 32's
"Verify after apply" query. `version.ts` holds a placeholder that the deployed copy replaces with the commit's short SHA
(every run row records it).

Owner procedures (applying 32 and 33, the secrets, the deploy, the 24-hour watch, the repair runbook and the switches)
are in DyorHQ/internal: `ios-app/supabase/owner-procedures.md`.

## Tests

    deno test -A --no-config --node-modules-dir=none supabase/functions/        # unit tests, next to each function
    deno test -A --no-config --node-modules-dir=none supabase/tests/            # every migration, on a throwaway PGlite database

`--no-config` keeps the repository's Node `package.json`/`tsconfig.json` out of Deno's way. `tests/supabase_stub.sql`
stands in for the platform (roles, auth/storage/vault stubs, default privileges); nothing touches the live project.
`tests/history_cache_test.ts` covers migration 32 role by role (about 3 minutes); `tests/history_indexer_run_test.ts`
runs the whole indexer loop on a virtual clock against fake endpoints (broken ones and a fake keyed Alchemy included)
and a PGlite database (10–15 minutes); `tests/migrations_test.ts` also applies migration 33 to a stand-in for pg_cron
and pg_net (the guards, the generated cron secret, the header the job sends). Two
opt-in suites are skipped unless asked for:

    HISTORY_LIVE=1 deno test -A --no-config --node-modules-dir=none supabase/tests/history_live_test.ts
        # public Monad RPC only (≤ 4 requests/s): straddle and node-lag probes, then the indexer end to end over the
        # last 500,000 blocks, checked against an independent reader; HISTORY_LIVE=full: the real global floors and a
        # 30-day window with 100 enrolled wallets (5–8 minutes); HISTORY_LIVE=deep: also one wallet back to genesis
    HISTORY_PG=1 deno test -A --no-config --node-modules-dir=none supabase/tests/history_pg_perf_test.ts
        # Postgres 17 in docker: commit, read and lock timings over 1,000,000 synthetic logs, profile upserts while
        # history rows are held, and the generic plans

## Minimum iOS build

`app_config` row `ios` = `{"min_build", "message", "url"}` is a server switch. A build that reads it (build 14 and
later, `ios/DyorHQ/App/UpdateGate.swift`) shows a blocking "Update required" screen (balances and key export still
work; nothing can be signed) when its CFBundleVersion is below `min_build`, and fails open on any error (migration 28
has the contract). Older builds ignore it, including the ones that hard-code retired contracts: retire those by
expiring them in App Store Connect / TestFlight. Raise it in the SQL editor:
`update public.app_config set value = jsonb_set(value, '{min_build}', '<build>') where key = 'ios';` — the CHECK
constraint refuses a row the app could not parse.

## Upload budgets (public buckets)

Migration 26: launch-media is write-once (a trigger refuses any upload over an existing object, move or rename, even
from the service role; interim exception for the same bytes under a `moment-<hash>` name until deferred 31), upload
names are pinned, and uploads are limited per wallet (40 objects and 500 MiB per 24 h) and overall (1,000 uploads and
5 GiB per 24 h, a circuit breaker). Storage checks permissions before it reads the bytes and writes the row later as
the service role, so the limits are enforced by triggers on `storage.objects` when the row is written. When the
overall budget is spent every launch-media upload fails (403) until older uploads age out; the day's total is
`select count(*), sum(bytes) from public.storage_upload_events where created_at > now() - interval '1 day';`.

## Not built yet

Server-side push delivery (a watcher with an APNs auth key), a launch indexer job, and leaderboard/stats Edge
Functions. The app computes alerts and the social views itself from the tables above.
