# Runbook: Lite on Stellar testnet

Everything below runs against `dyorhq-stellar-testnet`, a separate Supabase project. Never point any of it at
production (`fmnjqrguvopusfufmirs`).

## 1. Accounts and keys

| Key | Role | Where it lives |
|---|---|---|
| Deployer / admin | Deploys contracts, sets launch economics, pays the first TTL extension | `.secrets/testnet-deployer.env` (created by the deploy script), then a password manager |
| Treasury | Receives protocol fees (fixed per deployment) | Public key in `deployments/testnet.json`; secret in the password manager |
| Sponsor | Pays fees (fee-bump) and reserves; runs the keeper | Supabase secret `SPONSOR_SECRET` only |

To create the sponsor: `node -e "const {Keypair}=require('@stellar/stellar-sdk');const k=Keypair.random();console.log(k.publicKey(),k.secret())"`.
Then fund it with `curl "https://friendbot.stellar.org?addr=G…"`.

The sponsor spends testnet XLM on fees and on keeping contracts alive. Expect about 70 XLM a month for each 50 KB
contract, and 1–3 XLM for each launch. Top it up through Friendbot: create a fresh account, then merge it into the
sponsor, the same way the in-app faucet does.

## 2. Contracts

```bash
cd contracts && ./build.sh && cargo test          # dist/*.wasm, spec-shaken, with SHA256SUMS
cd .. && deno run -A --config backend/supabase/functions/deno.json backend/scripts/deploy-contracts.ts
SPONSOR_PUBLIC=G… deno run -A --config backend/supabase/functions/deno.json backend/scripts/gen-pinned.ts
```

The deploy script does six things:

1. Uploads the three WASMs.
2. Deploys the launchpad and Moments.
3. Sets the economics: XLM phantom 2,000 / threshold 4,324.55; USDC phantom 200 / threshold 432.46; Moments min price 0.1.
4. Extends the instances and code to 30 days.
5. Writes `backend/supabase/functions/_shared/deployments/testnet.json`.
6. Smoke-tests a launch, a publish and a collect.

`gen-pinned.ts` then regenerates the contract allowlist the app pins. Commit both files: an app build refuses any
contract that isn't pinned.

## 3. Supabase project

1. Create the project `dyorhq-stellar-testnet`. It costs money, so the owner creates it.
2. Apply the migrations: `supabase link --project-ref <ref> && supabase db push`. This creates the schema, the cron
   job and the `lite-media` bucket.
3. Set the function secrets:
   ```bash
   supabase secrets set LITE_NETWORK=testnet SPONSOR_SECRET=S… LITE_JWT_SECRET=$(openssl rand -base64 36) \
     LITE_CRON_SECRET=$(openssl rand -base64 24) LITE_MIN_BUILD=1
   # optional: SOROSWAP_API_KEY=sk_…  (without it, Soroswap is quoted through its router directly)
   ```
4. Create the cron Vault entries. The value of `lite_cron_secret` must equal `LITE_CRON_SECRET`:
   ```sql
   select vault.create_secret('https://<ref>.supabase.co/functions/v1/lite-indexer', 'lite_indexer_url');
   select vault.create_secret('<same as LITE_CRON_SECRET>', 'lite_cron_secret');
   ```
5. Deploy: `supabase functions deploy lite lite-indexer` (`verify_jwt = false` comes from `config.toml`).
6. Check: `curl https://<ref>.supabase.co/functions/v1/lite/v1/config` should return the network, the pinned
   contracts and the sponsor.

## 4. Testers

```bash
LITE_DB_URL=<testnet project DB URL> deno run -A --config backend/supabase/functions/deno.json backend/scripts/invite-tester.ts "Ama iPhone" 1 14
```

This prints a single-use code that expires in 14 days. The tester enters it once; it binds to their Stellar
address.

- Revoke a tester: `update lite.testers set revoked_at = now() where address = 'G…';`. It takes effect on their next request.
- Pause Lite for everyone: `update lite.app_config set value = jsonb_set(value, '{enabled}', 'false') where key = 'lite';`.

## 5. TestFlight

- **LiteHarness:** set `LITE_API_URL` in `ios/Config/Lite.local.xcconfig`, then archive. Upload to the **internal**
  group only (no Beta App Review, App Store Connect users only).
- **The DyorHQ app** (after Oct 13): build the Internal configuration with `STELLAR_LITE`
  (see INTEGRATION-ios.md). External groups get builds without the flag, so the Lite code isn't in their binary at all.

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
