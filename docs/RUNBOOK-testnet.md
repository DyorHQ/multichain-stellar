# Runbook: Lite on Stellar testnet

Lite's backend lives in the DyorHQ Supabase project (`fmnjqrguvopusfufmirs`), next to the Pro app (DECISIONS #17).
Lite writes only its own schema (`lite`), role (`lite_api`), functions, cron job, Vault entries and bucket.

## 1. Accounts and keys

| Key | Role | Where it lives |
|---|---|---|
| Deployer / admin | Deploys contracts, sets launch economics, pays the first TTL extension | `.secrets/testnet-deployer.env` (created by the deploy script), then a password manager |
| Treasury | Receives protocol fees (fixed per deployment) | Public key in `deployments/testnet.json`; secret in the password manager |
| Sponsor | Pays fees (fee-bump) and reserves; runs the keeper | Supabase secret `SPONSOR_SECRET` only |

To create the sponsor and the other function secrets without printing any of them:

```bash
deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts
```

It writes `.secrets/testnet-functions.env` (git-ignored, mode 600) with `LITE_NETWORK`, `LITE_MIN_BUILD`,
`SPONSOR_SECRET`, `LITE_JWT_SECRET` and `LITE_CRON_SECRET`, funds the sponsor through Friendbot and prints only the
sponsor's public key (for `gen-pinned.ts`). Once the secrets are in Supabase (§3), move the file to the password
manager and delete it.

The sponsor spends testnet XLM on fees and on keeping contracts alive. Expect about 70 XLM a month for each 50 KB
contract, and 1–3 XLM for each launch. Top it up through Friendbot: create a fresh account, then merge it into the
sponsor, the same way the in-app faucet does.

## 2. Contracts

DyorHQ's own contracts are the launchpad and Moments, plus the launch-token code the launchpad deploys for each launch.
The deployer becomes the admin of both. The other pinned contracts (the Soroswap and Aquarius routers, the Blend pool,
Circle's CCTP messenger, the XLM and USDC token contracts) are third-party.

What the admin can do: set the economics, fees and snipe schedule of launches created from then on, pause new
launches, set Moments' minimum prices and platform fee (capped at 10%), and hand admin over with `set_admin` (both
keys sign). It can't touch a live curve, user funds, creator fees or the locked LP. There is no upgrade function: the
code is immutable. The treasury is fixed at deployment.

Needs Rust 1.91+ with the `wasm32v1-none` target (`rustup target add wasm32v1-none`) and Deno 2. No Stellar CLI:
`build.sh` does its spec shaking, and the deploy script talks to testnet RPC itself. From the repository root:

1. **Build and test.** The build is reproducible: `dist/SHA256SUMS` matches the hashes in `testnet.json` for the same
   sources.
   ```bash
   (cd contracts && ./build.sh && cargo test)
   ```
2. **Keys.** Either let the script create them, or bring your own.
   - Fresh keys: move the old key file aside (`mv .secrets/testnet-deployer.env .secrets/testnet-deployer.<date>.env`).
     The script then creates an admin and a treasury key, funds both through Friendbot, writes them to
     `.secrets/testnet-deployer.env` (mode 600) and prints only their public keys.
   - Your own: `read -rs DEPLOYER_SECRET && export DEPLOYER_SECRET` (the admin's `S…`, not echoed, not in the shell
     history) and `export TREASURY_PUBLIC=G…`. Set both, or the script reads the old file.
3. **Deploy.** Add `SKIP_SMOKE=1` to skip the smoke test.
   ```bash
   deno run -A --config backend/supabase/functions/deno.json backend/scripts/deploy-contracts.ts
   ```
   It uploads the three WASMs, deploys the launchpad and Moments, and sets the economics: XLM phantom 2,000 /
   threshold 4,324.55; USDC phantom 200 / threshold 432.46; Moments minimum price 0.1. It then extends the instances and
   code to 30 days, writes `backend/supabase/functions/_shared/deployments/testnet.json`, and smoke-tests a launch
   ("CHECK"), a publish and a collect.
4. **Pin them in the app.** The sponsor is the backend's fee payer (§1); it doesn't change with the contracts.
   ```bash
   SPONSOR_PUBLIC=G… deno run -A --config backend/supabase/functions/deno.json backend/scripts/gen-pinned.ts
   ```
5. **Commit** `testnet.json` and `PinnedContracts+Testnet.swift`: an app build refuses any contract that isn't pinned.
6. **Restart the backend** on the new `testnet.json`: `backend/scripts/local-stack.sh stop` and `start`, or for the
   hosted project `supabase functions deploy lite lite-indexer` (§3, step 4). On its next run the indexer sees the new
   contracts, clears the launches and Moments it indexed for the old ones, and indexes from the new deployment's
   ledger.
7. **Ship a new internal build.** It pins the new contracts; older builds refuse them.
8. **Keep the keys:** move `.secrets/testnet-deployer.env` (or your own key) to the password manager.

## 3. Supabase (the DyorHQ project, schema `lite`)

Every step writes to the DyorHQ project, so the owner approves the run first, and an agent session also needs the
owner to open its 30-minute production-write window. Keep this order: the cron job comes last, because it calls the
indexer every minute and fails until the function and the Vault entries exist. Status on 2026-10-13: every file below
is ready, and none of these steps has run yet.

1. **Schema, role, bucket.** Apply migrations 1, 4 and 3 (`lite_schema`, `lite_api_role`, `lite_storage`) the way the
   DyorHQ project's other migrations are applied (the Supabase MCP's `apply_migration`, or the SQL editor). Don't run
   `supabase db push` from `backend/`: the project's migration history belongs to the app.
2. **The `lite_api` credential.** It adds `LITE_DB_URL` to `.secrets/testnet-functions.env` and writes the password as
   a SCRAM verifier, because `log_statement = ddl` would log a plain `ALTER ROLE … PASSWORD`. Link a scratch
   directory, so nothing in this repo is linked to the project:
   ```bash
   deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts --db-role fmnjqrguvopusfufmirs aws-1-eu-west-1.pooler.supabase.com
   supabase link --project-ref fmnjqrguvopusfufmirs --workdir "$SCRATCH"
   supabase db query --linked --workdir "$SCRATCH" --file .secrets/lite-api-role.sql && rm .secrets/lite-api-role.sql
   ```
3. **Function secrets** (six: `LITE_NETWORK`, `LITE_MIN_BUILD`, `SPONSOR_SECRET`, `LITE_JWT_SECRET`,
   `LITE_CRON_SECRET`, `LITE_DB_URL`), from the file, so no value goes through the shell history:
   ```bash
   supabase secrets set --project-ref fmnjqrguvopusfufmirs --env-file .secrets/testnet-functions.env
   # optional: add SOROSWAP_API_KEY=sk_… to that file first (without it, Soroswap is quoted through its router)
   ```
4. **Functions.** `verify_jwt = false` comes from `backend/supabase/config.toml`. Never run `supabase config push`
   from `backend/`: it would overwrite the DyorHQ project's API and storage settings with Lite's file.
   ```bash
   supabase functions deploy lite lite-indexer --project-ref fmnjqrguvopusfufmirs --workdir backend --use-api
   ```
5. **Vault entries** for the cron job (`lite_indexer_url`, and `lite_cron_secret` equal to `LITE_CRON_SECRET`):
   ```bash
   deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts --vault-sql fmnjqrguvopusfufmirs
   supabase db query --linked --workdir "$SCRATCH" --file .secrets/testnet-vault.sql && rm .secrets/testnet-vault.sql
   ```
6. **The cron job:** migration 2 (`lite_cron`).
7. **Check.**
   - `curl https://fmnjqrguvopusfufmirs.supabase.co/functions/v1/lite/v1/config` returns the network, the pinned
     contracts and the sponsor.
   - `select status, return_message from cron.job_run_details where jobid = (select jobid from cron.job where
     jobname = 'lite-indexer') order by start_time desc limit 5;` shows succeeded runs.
   - The `lite-indexer` logs report each run.

Then move `.secrets/testnet-functions.env` to the password manager and delete it.

## 4. Testers

```bash
deno run -A --env-file=.secrets/testnet-functions.env --config backend/supabase/functions/deno.json \
  backend/scripts/invite-tester.ts "Ama iPhone" 1 14
```

This prints a single-use code that expires in 14 days. The tester enters it once; it binds to their Stellar
address.

- Revoke a tester: `update lite.testers set revoked_at = now() where address = 'G…';`. It takes effect on their next request.
- Pause Lite for everyone: `update lite.app_config set value = jsonb_set(value, '{enabled}', 'false') where key = 'lite';`.

## 5. TestFlight

- **LiteHarness:** set `LITE_API_URL` in `ios/Config/Lite.local.xcconfig`, then archive. Upload to the **internal**
  group only (no Beta App Review, App Store Connect users only).
- **The DyorHQ app** (after Oct 13): archive the `DyorHQ Internal` target, which links Lite and sets `STELLAR_LITE`
  (INTEGRATION-ios.md §1). External groups and the App Store get the `DyorHQ` target, which doesn't link the Lite
  packages, so the Lite code isn't in their binary at all. The flag alone wouldn't keep it out.

## 6. Testnet reset (next: 2026-12-16)

A reset erases every account and contract. The indexer detects that the ledger went backwards and clears the indexed
tables. Then:

1. Re-fund the sponsor and the deployer through Friendbot.
2. Run `deploy-contracts.ts` and `gen-pinned.ts`, commit, and ship a new internal build. The pinned contracts changed.
3. Testers sign in again. Their invite binding survives, but their accounts must be re-activated.

## 7. Monitoring

- `select status, count(*) from lite.tx_log where created_at > now() - interval '1 day' group by 1;`
- `select * from lite.sponsor_usage order by fee_stroops desc limit 20;`
- Function logs: Supabase dashboard → Edge Functions → `lite-indexer` → Logs. Each run reports events indexed,
  transactions settled, launches graduated, bridges advanced and TTL entries extended.

## 8. Local stack (the iOS Simulator and the journey test)

`backend/scripts/local-stack.sh` runs Lite's backend on this Mac against Stellar testnet, with no hosted project: Postgres
16 (Homebrew) on 127.0.0.1:54329, the `lite` API on 127.0.0.1:8000 and `lite-indexer` on 127.0.0.1:8001, plus a loop that
calls the indexer every minute in place of the cron job.

```bash
backend/scripts/local-stack.sh start        # first run: initdb, migrations and the schema tests
backend/scripts/local-stack.sh status
backend/scripts/local-stack.sh invite "Jay simulator"   # the code goes to .secrets/local-invites.txt, never the terminal
backend/scripts/local-stack.sh stop
```

- The app's Debug internal build (DyorHQ repo, `ios/Internal/generate.py`) uses `http://127.0.0.1:8000/lite`; the
  simulator shares the Mac's loopback.
- Secrets reach the processes only through `.secrets/local-functions.env`, which `backend/scripts/local/make-local-env.ts`
  derives from `.secrets/testnet-functions.env` without its hosted `LITE_DB_URL`. Every process starts from an empty
  environment.
- Not available locally: media uploads and Moment metadata (they need Supabase Storage, so those routes answer 503). Coins
  launch without an image; Moments can't be published from the app.
- The local keepers spend the shared testnet sponsor's XLM, like the hosted indexer does.
