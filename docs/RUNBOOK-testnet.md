# Runbook: Lite on Stellar testnet

Lite's backend lives in the DyorHQ Supabase project (`fmnjqrguvopusfufmirs`), next to the Pro app (DECISIONS #17).
Lite writes only its own schema (`lite`), role (`lite_api`), functions, cron job, Vault entries and bucket.

## 1. Accounts and keys

| Key | Role | Where it lives |
|---|---|---|
| Deployer / admin | Deploys contracts, sets launch economics, pays the first TTL extension | The owner's own key, in a password manager (testnet-qa: `.secrets/testnet-qa-deployer.env`, §2) |
| Treasury | Receives protocol fees (fixed per deployment); needs a trustline for every classic quote asset (USDC) | Public key in `deployments/<name>.json`; secret in the password manager |
| Sponsor | Pays account setup where DyorHQ pays it (a sponsored account on mainnet, `--activation sponsored` locally) and, on mainnet, one first swap into XLM; users pay every other network fee in XLM (DESIGN-stellar-parity §4.1) | Supabase secret `SPONSOR_SECRET` only |
| Keeper | Pays protocol upkeep: graduations, TTL extensions and the CCTP relay. It never appears in a user's transaction | Supabase secret `KEEPER_SECRET` only. On testnet, when it is missing, the sponsor pays with a warning; mainnet needs a key of its own |

To create the sponsor, the keeper and the other function secrets without printing any of them:

```bash
deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts
```

It writes `.secrets/testnet-functions.env` (git-ignored, mode 600) with `LITE_NETWORK`, `LITE_MIN_BUILD`,
`SPONSOR_SECRET`, `KEEPER_SECRET`, `LITE_JWT_SECRET` and `LITE_CRON_SECRET`, funds the sponsor and the keeper through
Friendbot and prints only their public keys (the sponsor's is for `gen-pinned.ts`). Once the secrets are in Supabase
(§3), move the file to the password manager and delete it.

**Adding the keeper to an older file.** A `testnet-functions.env` made before the keeper existed has no
`KEEPER_SECRET`:

```bash
deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts --add-keeper
```

It appends a new `KEEPER_SECRET` (the file stays mode 600), funds the keeper through Friendbot and prints its public
key and the two follow-ups: the local stack picks it up at its next start (`local-stack.sh stop`, then `start`), and
the hosted project needs `supabase secrets set --env-file .secrets/testnet-functions.env --project-ref
fmnjqrguvopusfufmirs` (an owner action, §3). When the file has a keeper already, it prints that keeper's public key and
changes nothing. It refuses a file whose `LITE_NETWORK` isn't testnet. `--dir <directory>` points either command at
another directory than `.secrets`, which is how to try them safely.

The sponsor and the keeper spend testnet XLM. Expect about 70 XLM a month for each 50 KB contract kept alive, and about
1 XLM for each graduation. Top them up through Friendbot: create a fresh account, then merge it into the sponsor or the
keeper.

## 2. Contracts

DyorHQ's own v1 contracts are the launchpad and Moments, plus the launch-token code the launchpad deploys for each
launch. The deployer becomes the admin of both. The other pinned contracts (the Soroswap and Aquarius routers, the
Blend pool, Circle's CCTP messenger, the XLM and USDC token contracts) are third-party.

**The live testnet v1 contracts stay as they are** (owner decision O5, DESIGN-stellar-contracts-v2 §17): launchpad
`CDZD53…5I6I` and Moments `CCWP4L…2YIR`, recorded in `deployments/testnet.json`. They are never redeployed; the owner
deploys contracts v2 instead (§2.1). That file also records the deploy's own smoke items, the "Deploy Check" (CHECK)
launch and Moment #1, found from the deploy's chain events, so the indexer never lists them.

What the admin can do: set the economics, fees and snipe schedule of launches created from then on, pause new
launches, set Moments' minimum prices and platform fee (capped at 10%), and hand admin over with `set_admin` (both
keys sign). It can't touch a live curve, user funds, creator fees or the locked LP. There is no upgrade function: the
code is immutable. The treasury is fixed at deployment.

**The v1 deploy tooling** remains for local stacks and QA: `deploy-contracts.ts --deployment <name>` deploys a
complete v1 set as a named deployment, and `gen-pinned.ts --deployment <name>` pins the app to it. The names are
`testnet` (the live set's record), `testnet-qa` (a QA set with throwaway keys, made only where the owner allows it,
DESIGN-stellar-parity Q3) and `mainnet` (none yet). It needs Rust 1.91+ with the `wasm32v1-none` target
(`rustup target add wasm32v1-none`) and Deno 2. No Stellar CLI: `build.sh` does its spec shaking, and the deploy
script talks to RPC and Horizon itself. From the repository root:

1. **Build and test.** The build is reproducible: `dist/SHA256SUMS` matches the hashes in `testnet.json` for the same
   sources.
   ```bash
   (cd contracts && ./build.sh && cargo test)
   ```
2. **Economics.** `backend/supabase/functions/_shared/deployments/economics.<name>.json` holds each contract's
   `set_quote` arguments per quote asset (the asset ids of `networks.ts`), in base units as strings:
   `{"launchpad": {"XLM": {"phantom", "threshold", "enabled"}, …}, "moments": {"XLM": {"minPrice", "enabled"}, …}}`.
   `economics.testnet.json` is what the live set was configured with (XLM phantom 2,000 and threshold 4,324.555532;
   USDC 200 and 432.4555532; Moments minimum 0.1 in either). `economics.testnet-qa.json` has launch curves ten times
   smaller (phantom 200 XLM or 20 USDC), so one tester can graduate a launch. The threshold is phantom · (√10 − 1), for
   a graduation FDV ten times the launch FDV.
3. **Keys.**
   - `testnet-qa` makes its own on its first run: an admin and a treasury, in `.secrets/testnet-qa-deployer.env`
     (mode 600), funded by Friendbot, with the treasury's USDC trustline. Nothing is printed but the public keys.
   - Every other deployment makes none. Set the admin's secret without echo, and the treasury's public key:
     ```bash
     read -rs DEPLOYER_SECRET && export DEPLOYER_SECRET
     export TREASURY_PUBLIC=G…   # a funded account with a trustline for every enabled classic quote (USDC)
     ```
     Without both, the script refuses before any network call.
4. **Preflight (dry run).** It checks that the three WASMs are built, that the admin and the treasury exist, and that
   the treasury trusts every enabled classic quote asset (Moments pays its platform share and the launchpad its
   protocol fees in the quote asset, so a missing USDC trustline would break USDC collects and claims). It reports
   every finding and deploys nothing:
   ```bash
   deno run -A --config backend/supabase/functions/deno.json backend/scripts/deploy-contracts.ts --deployment <name> --dry-run
   ```
5. **Deploy.** The same command without `--dry-run` runs the preflight again and stops before uploading when it fails.
   It then uploads the three WASMs, deploys the launchpad and Moments, sets the economics, extends the instances and
   code to 30 days and writes `deployments/<name>.json` with `indexFromLedger`, the first ledger after the
   configuration. A file that exists already is replaced only with `--replace`. `SMOKE=1` adds a smoke test (a
   "CHECK" launch, a publish and a collect) and records its items as `smoke`, which the indexer never lists; it is
   refused on mainnet, and a deployment that real users see runs without it.
6. **Pin them in the app.** The sponsor is the backend's (§1); it doesn't change with the contracts.
   ```bash
   SPONSOR_PUBLIC=G… deno run -A --config backend/supabase/functions/deno.json backend/scripts/gen-pinned.ts --deployment <name>
   ```
   `testnet` writes `PinnedContracts+Testnet.swift`; `testnet-qa` writes `PinnedContracts+TestnetQA.swift`, which
   Debug builds select with `LITE_PINNED=testnet-qa`.
7. **Commit** `deployments/<name>.json` and the pins (neither holds a secret): an app build refuses any contract that
   isn't pinned.
8. **Restart the backend** on the new file: `backend/scripts/local-stack.sh stop` and `start` (with
   `--deployment testnet-qa` for the QA set), or for the hosted project `supabase functions deploy lite lite-indexer`
   (§3, step 4). On its next run the indexer sees the new contracts, clears what it indexed for the old ones, and
   indexes from the new deployment's `indexFromLedger`.
9. **Ship a new internal build** when the pins changed: older builds refuse the new contracts.

### 2.1 Contracts v2: the owner deploy

Filled in by the lead when CT-11a merges.

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
3. **Function secrets** (seven: `LITE_NETWORK`, `LITE_MIN_BUILD`, `SPONSOR_SECRET`, `KEEPER_SECRET`,
   `LITE_JWT_SECRET`, `LITE_CRON_SECRET`, `LITE_DB_URL`), from the file, so no value goes through the shell history:
   ```bash
   supabase secrets set --project-ref fmnjqrguvopusfufmirs --env-file .secrets/testnet-functions.env
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

Testnet needs no invite: a first sign-in registers the address as a tester, who can still be revoked
(`LITE_INVITE_REQUIRED=1` turns invites on, as on mainnet). Where invites are on:

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
tables. The v1 contracts are gone for good then (O5: they are never redeployed). Then:

1. Re-fund the sponsor, the keeper and the deployer through Friendbot.
2. The owner deploys contracts v2 again (§2.1). A QA set, where there is one, is redeployed with
   `deploy-contracts.ts --deployment testnet-qa --replace` (§2). Run `gen-pinned.ts` for each, commit, and ship a new
   internal build: the pinned contracts changed.
3. Testers sign in again. Their tester row survives, but their accounts must be re-activated.

## 7. Monitoring

- `select status, count(*) from lite.tx_log where created_at > now() - interval '1 day' group by 1;`
- `select * from lite.sponsor_usage order by fee_stroops desc limit 20;`
- Function logs: Supabase dashboard → Edge Functions → `lite-indexer` → Logs. Each run reports events indexed,
  transactions settled, launches graduated, bridges advanced and TTL entries extended.

## 8. Local stack (the iOS Simulator, the journey test and work packages)

`backend/scripts/local-stack.sh` runs Lite's backend on this Mac against Stellar testnet, with no hosted project:
Postgres 16 (Homebrew), the `lite` API and `lite-indexer`, plus a loop that calls the indexer every minute in place of
the cron job.

```bash
backend/scripts/local-stack.sh start        # first run: initdb and every migration; later: only the new migrations
backend/scripts/local-stack.sh status
backend/scripts/local-stack.sh invite "Jay simulator"   # the code goes to .secrets/local-invites.txt, never the terminal
backend/scripts/local-stack.sh stop
```

- **Ports.** The default stack: API on 127.0.0.1:8000, indexer on 8001, Postgres on 54329 (agents hold the `stack`
  lock for it). `PORT_BASE=<n>` runs a stack of its own: API on `n`, indexer on `n+1`, Postgres on `n+2`, with `n+3`
  kept free for a storage stand-in. Work package NN uses `PORT_BASE=2NN00`, and every command takes the same
  `PORT_BASE`, so stacks of several worktrees, or several in one worktree, run side by side:
  ```bash
  PORT_BASE=20400 backend/scripts/local-stack.sh start --no-loop
  LITE_API=http://127.0.0.1:20400/lite deno run -A --config backend/supabase/functions/deno.json backend/tests/e2e/lite_e2e.ts auth
  PORT_BASE=20400 backend/scripts/local-stack.sh stop
  ```
- **State.** Each stack keeps its Postgres data, logs, PID files, env file, settings, media and (with `PORT_BASE`)
  invites in a state directory of its checkout: `.local-stack` for the default stack, `.local-stack/<PORT_BASE>` for
  the others (git-ignored, mode 700). `stop` keeps it; `rm -rf .local-stack/<PORT_BASE>` after a stop frees the disk.
- **Start options** (`start` is idempotent; a running stack refuses other options until it is stopped):
  - `--no-loop`: no indexer loop, and `LITE_KEEPER=off`, so the indexer skips every job that signs with the sponsor's
    or the keeper's key (graduation, TTL, the bridge relay). Package stacks use it, so they never race the shared
    keys' sequence numbers. `LITE_KEEPER=off` on its own keeps the loop.
  - `--deployment testnet|testnet-qa`: the contracts the stack serves and indexes (`LITE_DEPLOYMENT`).
  - `--activation sponsored`: `LITE_ACTIVATION=sponsored`, the local rehearsal of mainnet's sponsored setup and
    starter swap. Testnet's default is Friendbot.
  - `--short-sessions`: access tokens last 120 s and refresh tokens 600 s (`LITE_JWT_TTL_S`, `LITE_REFRESH_TTL_S`),
    so the "no prompt after the session ended" checks run in minutes. Testnet only.
  - `--invite-required`: `LITE_INVITE_REQUIRED=1`, for the mainnet-style sign-in with an invite.
- **Commands.** `migrate` applies the migrations this database hasn't had, each in its own transaction with its row in
  `public.local_stack_migrations`, then checks the schema with `backend/tests/sql/lite_schema_test.sql` (rolled back);
  `start` does the same. A database made by an older `local-stack.sh` has no such record and is rebuilt once: indexed
  rows come back from the chain, and testers sign in again. `status` prints what runs, the network and deployment,
  the fee mode, the sponsor's and keeper's XLM from the indexer's last `ops` run, the reference prices' age and the
  watch groups. `e2e [phases…]` runs `backend/tests/e2e/lite_e2e.ts` against the stack with its own settings. `logs
  [lite|indexer|loop|postgres|all]` tails the logs.
- **Secrets** reach the processes only through the stack's `<state>/functions.env` (mode 600), which
  `backend/scripts/local/make-local-env.ts` derives from `.secrets/testnet-functions.env`: the function secrets
  (`KEEPER_SECRET` when it is there) and the stack's settings, never the hosted `LITE_DB_URL`. Every process starts from
  an empty environment. A `PORT_BASE` stack only reads `.secrets`: its invites go to `<state>/invites.txt`. The old
  `.secrets/local-functions.env` isn't used any more and can be deleted.
- **The app.** The Debug internal build (`app/ios/Internal/generate.py`) uses the default stack,
  `http://127.0.0.1:8000/lite`; the simulator shares the Mac's loopback. Its media base is the API's local stand-in for
  Storage (`/v1/local-media/lite-media/`): uploads are kept in the stack's `media` directory (`LITE_LOCAL_STORAGE_DIR`)
  and served under `LITE_PUBLIC_BASE`, the API's own URL. Testnet only.
- With the loop on and `LITE_KEEPER` on, the local keepers spend the shared testnet keeper's (or sponsor's) XLM, like
  the hosted indexer does.
