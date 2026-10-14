# scripts/agent

Tooling for the work packages of the Stellar parity program ([docs/DESIGN-stellar-parity.md](../../docs/DESIGN-stellar-parity.md)
§12.3, §13.4 and §9). Each script prints its usage when run without arguments. None of them opens a secret file:
`.env*`, `Secrets.xcconfig` and `.secrets/` are never read or printed. Tools that need a secret read it themselves.

| Script | What it does |
|---|---|
| `worktree.sh WP-xx` | A package's two worktrees, side by side under `~/Hackathon-b17/wt/WP-xx/`, both on branch `stellar/WP-xx` |
| `lock.sh acquire\|release <sim\|stack> WP-xx` | The shared agent simulator and default local stack, one package at a time |
| `verify-app.sh <A> <S> WP-xx` | V-APP, V-STR and V-DYORKIT for a netswitch package |
| `verify-backend.sh <S> NN` | V-BE for a multichain-stellar package |
| `scan-placeholders.sh <A> <S>` | V-SCAN: placeholder text in the new app code and the backend |
| `backend/scripts/schema-test.sh <port>` | The migrations and SQL tests on a throwaway Postgres 16 (V-BE runs it) |

## Worktrees

```sh
scripts/agent/worktree.sh WP-21
export A=~/Hackathon-b17/wt/WP-21/IOS-app S=~/Hackathon-b17/wt/WP-21/multichain-stellar   # the line it prints
```

- **A** is IOS-app on `stellar/WP-21`, from `lite/network-switch` in `~/Hackathon-b17/netswitch`.
- **S** is multichain-stellar on `stellar/WP-21`, from this repository's `main`.
- Side by side, `ios/Internal/generate.py` finds the packages with its default `--lite`.
- `ios/project.local.yml` (untracked) is copied from the netswitch checkout.
- `S/.secrets` links to the main checkout's `.secrets`, so `backend/scripts/local-stack.sh` can start. `/.secrets` is
  in `.git/info/exclude`.

It refuses when either folder or either branch exists, and removes what it made when a later step fails.

## Locks

```sh
scripts/agent/lock.sh acquire sim WP-21     # exit 1 while another package holds it
xcodebuild … test
scripts/agent/lock.sh release sim WP-21
scripts/agent/lock.sh status
```

- `sim` guards the agent simulator (`3672E24D-0458-4181-B351-94A3D1FCDB01`): every `xcodebuild test` and simulator run.
- `stack` guards the default local stack (ports 8000, 8001 and 54329). Package stacks use `PORT_BASE` and need no lock.
- A lock is the folder `~/Hackathon-b17/wt/.locks/<name>`, holding `owner`, `pid` and `since`.
- The recorded process is the one that started the calling shell: the Claude Code session, or the terminal window. The
  lock stays held between an agent's commands. Once that process has exited, the next `acquire` takes the lock over.
- `pid` also holds that process's start time, in the C locale and UTC: a reused PID doesn't keep a lock alive, and a
  lock reads the same from a terminal with `LANG` or `TZ` set as from an agent without them.
- `LOCK_WAIT=<seconds>` makes `acquire` retry every 5 seconds before giving up. `LOCK_PID=<pid>` ties the lock to
  another process.
- A lock folder without a `pid` file was taken by hand (`mkdir`). It is never taken over; its holder removes it.

## Verification

```sh
scripts/agent/verify-app.sh $A $S WP-21     # netswitch packages
scripts/agent/verify-backend.sh $S 02       # multichain-stellar packages; Postgres on port 5502
scripts/agent/scan-placeholders.sh $A $S
```

- Both verify scripts stop at the first failure and keep each command's output in a log in a temporary folder.
  A failure prints the log's errors and its last lines.
- `verify-app.sh` builds into `$A/ios/DerivedData-WP-xx` and `DerivedData-WP-xx-as`. It restores
  `ios/DyorKit/Package.resolved` on every exit, since `swift test` rewrites it and DyorKit never changes (I2).
- The V-INT, V-KIT, V-LITE and V-LIVE blocks run as written in §12.3, with the `sim` lock where the block says so.

## Placeholder scan

`scan-placeholders.sh [--allow FILE] <A> <S>` greps A's `ios/DyorHQ/Lite` and `ios/Internal`, the `#if STELLAR_LITE`
blocks of A's other Swift files (the network switch's hooks in build-23 files), and S's `backend` and `ios/Packages`.
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

The path is relative to its repository, and `*` matches across folders. The pattern is written exactly as above, and
the reason is required. The scan names allow-list lines that matched nothing. A placeholder gets fixed; only text that
is right where it is goes on the list, such as the sponsored row of the review sheet.

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
