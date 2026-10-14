# DyorHQ contracts

Foundry project for the two on-chain products of the app, deployed on Monad mainnet (chain id 143):

- **Launchpad** (`src/`): `LaunchpadFactory` is the entry point for launches and graduation; it creates a
  `LaunchToken` with its `BondingCurve` through `LaunchDeployer` (which holds the creation code so the factory stays
  small). `LaunchAndBuyRouter` creates a launch and makes the creator's first buy in one transaction. `FeeEscrow`
  delivers fees to their recipients (pushed, else claimable) and `HolderFeeSharing` routes a launch's creator fees to
  its holders pro rata. When a curve completes, `GraduationExecutor` turns it into a Uniswap v4 pool (with `MemeHook`
  on the pool and the position held forever by `LaunchLocker`) or `MondayGraduationExecutor` into a Monday Trade spot
  pool (its liquidity held by `MondayFeeVault`).
- **Moments** (`src/moments/`): `MomentsFactory` mints a `MomentNFT` with its own `MomentCoin`; `MomentCollect` sells
  editions, `MomentVesting` vests the collector and creator shares, `MomentGraduation` opens the pool, `MomentFeeHook`
  collects the pool fee and `MomentBuyback` spends it; `MomentLocker` holds the liquidity.
- `src/interfaces/` and `src/libraries/` are shared; `src/mocks/` holds the test doubles the tests deploy.

The app reads the live addresses from DyorKit (`LaunchpadAddresses.monadMainnet`, `MomentsAddresses.monadMainnet`),
which the release gate checks against the records here before any archive (`ios/README.md`, "Contract addresses and the
release gate").

## Layout

| Path | What it is |
|---|---|
| `src/` | The contracts (Solidity 0.8.26, `via_ir`, Cancun). |
| `test/` | Forge tests: the launchpad suites at the root, `moments/` (unit, fuzz, invariant and fork tests with their expected economics in `EXPECTED.md`), `audit/` (proofs of concept and regression tests written during the security reviews; the `Z_` prefix runs them last) and `sec2/`. |
| `script/` | Deploy and verification scripts; `script/README.md` explains the dry run. Live deploys follow the owner procedure in DyorHQ/internal (private). |
| `deployments/` | One JSON record per deployed stack: `143.json` and `moments-143.json` are live; the `143-retired-*.json` and `moments-143-cohort*.json` records are the stacks they replaced, kept because the app still serves their coins, claims and links. |
| `keepers/` | The dry-run-by-default jobs for the deployed contracts (launch and Moment graduations, buybacks, fee sweeps, governance checks), their tests, and the Fly.io kit in `ops/`. See `keepers/README.md`. |
| `lib/` | Git submodules: `forge-std` and Uniswap `v4-core` (pinned; `foundry.toml` keeps v4-core's own optimizer profile). |
| `foundry.toml`, `remappings.txt` | Build settings. `code_size_limit` is 128 KiB because Monad allows contracts larger than Ethereum's 24 KiB. |

## Build and test

```bash
git submodule update --init
forge build
forge test --offline --code-size-limit 100000000
```

`--offline` makes Foundry use the installed compiler instead of downloading one; the size flag disables Foundry's
Ethereum-sized contract lint, which `LaunchpadFactory` exceeds by design (Monad's limit is 128 KiB). The fork tests
(`test/moments/fork`, parts of `test/audit`, the Monday suites) select the `monad` endpoint from `foundry.toml`, so
they need network access to Monad mainnet; `forge test --no-match-path 'test/**/*Fork*'` is not enough to skip them
all, use `--match-path` to pick the suites you want.

The keepers:

```bash
node keepers/keeper.mjs --help
npm run keepers:test        # from the repository root
```

## Addresses

The live records are the source of truth; the public docs list every address the app uses at
https://dyorhq.gitbook.io/docs/resources/contracts-and-addresses. Deployments sign as the contract owner through a
Foundry keystore or a hardware wallet, never with a private key on the command line or in a file in this repository.
