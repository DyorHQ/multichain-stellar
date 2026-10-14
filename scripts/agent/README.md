# scripts/agent

Tooling for the work packages of the Stellar parity program ([docs/DESIGN-stellar-parity.md](../../docs/DESIGN-stellar-parity.md)
§12.3, §13.4 and §9). Each script prints its usage when run without arguments. None of them opens a secret file:
`.env*`, `Secrets.xcconfig` and `.secrets/` are never read or printed. Tools that need a secret read it themselves.

| Script | What it does |
|---|---|
| `worktree.sh WP-xx [--base <branch>]` | A package's worktree of this repository, `~/Hackathon-b17/wt/WP-xx/multichain-stellar`, on branch `stellar/WP-xx` |
| `lock.sh acquire\|release <xcode\|sim\|stack\|cargo> WP-xx` | Xcode, the agent simulator, the default local stack and the Rust build slots, shared between packages |
| `verify-app.sh <S> WP-xx [--clean]` | V-APP, V-STR and V-DYORKIT for a package that changes the app copy, under the `xcode` lock |
| `verify-backend.sh <S> NN` | V-BE for a package that changes the backend, as CI runs it |
| `scan-placeholders.sh <S>` | V-SCAN: placeholder text in the new app code and the backend |
| `backend/scripts/schema-test.sh <port>` | The migrations and SQL tests on a throwaway Postgres 16 (V-BE runs it) |
| `scripts/app-subtree-pull.sh <public app> <branch>` | A newer public app into `app/`, then the build-23 guard |

## Worktrees

```sh
scripts/agent/worktree.sh WP-21 --base integrate/m1
export S=~/Hackathon-b17/wt/WP-21/multichain-stellar A=~/Hackathon-b17/wt/WP-21/multichain-stellar/app   # the line it prints
```

- **S** is this repository on `stellar/WP-21`, from `--base`: the current integration branch when there is one,
  otherwise `main` (the default).
- **A** is S's `app/`, the copy of the public app (owner decision 2026-10-14). App and package changes of one package
  land on one branch. `app/ios/Internal/generate.py` finds the packages in S's `ios/Packages` by default.
- `app/ios/project.local.yml` (untracked) is copied from `~/Hackathon-b17/netswitch/ios`, or, when that is missing,
  written as the same include of `project.yml` with `Secrets.example.xcconfig` for Debug and Release.
- `S/.secrets` links to the main checkout's `.secrets`, so `backend/scripts/local-stack.sh` can start. `/.secrets` and
  the local spec are in `.git/info/exclude`.
- This repository has no git hooks: before each commit, run the public app checkout's secret scan with
  `--repo $S` (`~/Hackathon/scripts/dev/secret-scan.sh --repo $S`), and don't commit on a finding.

It refuses when the folder or the branch exists, and removes what it made when a later step fails.

## Locks

```sh
scripts/agent/lock.sh acquire xcode WP-21   # exit 1 while another package holds it (LOCK_WAIT=<s> waits for it)
xcodebuild … build
scripts/agent/lock.sh release xcode WP-21
scripts/agent/lock.sh status
```

- `xcode` has **one holder at a time**. Hold it for **every `xcodebuild`** (build or test) and **every simulator run**:
  this Mac has 11 cores, 18 GB of memory and little disk, so builds run one after another.
- `sim` guards the agent simulator (`3672E24D-0458-4181-B351-94A3D1FCDB01`): every `xcodebuild test` and simulator run.
  Take `xcode` first, then `sim`. The owner's simulator is the lead's only.
- `stack` guards the default local stack (ports 8000, 8001 and 54329). Package stacks use `PORT_BASE` and need no lock.
- `cargo` has two slots, `cargo-1` and `cargo-2`: `acquire cargo` takes a free one (or says which one the package
  already holds) and `release cargo` gives back the package's own.
- A lock is the folder `~/Hackathon-b17/wt/.locks/<name>`, holding `owner`, `pid` and `since`.
- The recorded process is the one that started the calling shell: the Claude Code session, or the terminal window. The
  lock stays held between an agent's commands. Once that process has exited, the next `acquire` takes the lock over.
- `pid` also holds that process's start time, in the C locale and UTC: a reused PID doesn't keep a lock alive, and a
  lock reads the same from a terminal with `LANG` or `TZ` set as from an agent without them.
- `LOCK_WAIT=<seconds>` makes `acquire` retry every 5 seconds before giving up. `LOCK_PID=<pid>` ties the lock to
  another process (`verify-app.sh` ties `xcode` to itself, so a killed run leaves a lock the next acquire reclaims).
- A lock folder without a `pid` file was taken by hand (`mkdir`). It is never taken over; its holder removes it with
  `rmdir`.

**Build output.** Every package builds into folders of its own (`app/ios/DerivedData-WP-xx`, `.build` of the packages
it tests, `contracts/target`) and **deletes them when it finishes**: disk is short. `verify-app.sh --clean` does that
for what it built.

## Verification

```sh
scripts/agent/verify-app.sh $S WP-21          # packages that change app/
scripts/agent/verify-backend.sh $S 02         # packages that change backend/; Postgres on port 5502
scripts/agent/scan-placeholders.sh $S
```

- Both verify scripts stop at the first failure and keep each command's output in a log in a temporary folder.
  A failure prints the log's errors and its last lines.
- `verify-app.sh` takes the `xcode` lock once, before the first build, and gives it back after the last one
  (DyorKit's `swift test`), waiting for it up to `LOCK_WAIT` seconds (default 7200). It builds the internal project
  (Debug and Release) and the App Store project into one folder, `$A/ios/DerivedData-WP-xx`, then runs the checks
  against the app copy's snapshot. It restores `app/ios/DyorKit/Package.resolved` on every exit, since `swift test`
  and the internal build rewrite it and DyorKit never changes (I2). `--clean` deletes the derived data and DyorKit's
  `.build` at the end when the run made them.
- `verify-backend.sh` runs what `.github/workflows/backend.yml` runs: the type check of every entry point, the unit
  tests, the API contract's checks (`backend/tests/fixtures`, `sync.sh --check`) and `schema-test.sh 55NN`.
- The V-INT, V-KIT, V-LITE and V-LIVE blocks run as written in §12.3, under the `xcode` lock (and `sim` where the
  block says so).

## Placeholder scan

`scan-placeholders.sh [--allow FILE] <S>` greps S's `app/ios/DyorHQ/Lite` and `app/ios/Internal`, the
`#if STELLAR_LITE` blocks of the other Swift files under `app/ios` (the network switch's hooks in the public app's
files), and S's `backend` and `ios/Packages`. §12.3's `scan-placeholders.sh $A $S` works too, with `A` = `$S/app`.
It reads tracked files and new ones that aren't added yet, so run it before committing; ignored files and secret files
are left out. It looks for these fixed, case-sensitive strings:

```
"TOKEN"   example.invalid   USDC: 1   BUSDC: 1   Paid by DyorHQ   pays the Stellar network fees
Reserves paid by DyorHQ   10,000 test   10000 test   Lorem
pays the network fees   number(10_000)   10_000.formatted
```

The first two lines are §9's list. The third catches evidence that §9's table says this scan tests and the list
misses: the "DyorHQ pays the network fees and the reserve" copy, and the testnet faucet's 10,000 written in code.

It exits 1 on any hit that isn't allowed. `scan-allow.txt` lists the allowed ones, one per line:

```
<path glob> <pattern> # reason
```

The path is relative to S (`app/…` for the app copy), and `*` matches across folders. The pattern is written exactly
as above, and the reason is required. The scan names allow-list lines that matched nothing. A placeholder gets fixed;
only text that is right where it is goes on the list, such as the sponsored row of the review sheet.

## Schema test

```sh
backend/scripts/schema-test.sh 5502
```

It runs a throwaway Postgres 16 cluster (Homebrew's `postgresql@16`) in a temporary folder, on that port of
127.0.0.1 only. It then:

1. creates the roles `anon`, `authenticated` and `lite_api`;
2. applies every `backend/supabase/migrations/*.sql` in filename order;
3. runs every `backend/tests/sql/*.sql`, each on a fresh copy of the migrated database;
4. stops the cluster and deletes its folder, whatever the outcome.

It refuses the default stack's ports and a port in use. Use `55NN` for package WP-NN.

## The public app

`scripts/app-subtree-pull.sh <public app checkout> <branch>` takes a newer public app into `app/` with
`git subtree pull --prefix=app --squash`, on a clean working tree. It prints only the conflicts, if there are any,
then runs `check-build23.py` against the new snapshot and `check-copies.py` (see `ios/Integration/README.md`).
