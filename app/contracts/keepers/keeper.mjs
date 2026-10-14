#!/usr/bin/env node
// DyorHQ keepers for the deployed (immutable) Launchpad and Moments contracts on Monad. Dry run by default: reads
// chain state, simulates each permissionless call and prints the exact `cast send` it would run. `--send` executes
// them through Foundry `cast` with a keystore / Foundry account / Ledger — never a raw private key.
//
//   node contracts/keepers/keeper.mjs <job...> [options]
//   jobs: moments-graduation (MO-1) | buybacks (MO-2) | sweeps (LP-2) | launchpad-graduation (LP-1) | governance | all
//
// Exit codes: 0 = nothing needs a human, 2 = alert(s) raised, 1 = the keeper failed. See keepers/README.md.
// The run itself is lib/run.mjs; the options are lib/options.mjs.
import { parseKeeperArgs, USAGE } from "./lib/options.mjs";
import { runKeeper } from "./lib/run.mjs";
import { EXIT } from "./lib/report.mjs";
import { redact } from "./lib/redact.mjs";

let opts;
try {
  opts = parseKeeperArgs(process.argv.slice(2), process.env);
} catch (e) {
  // A usage error can quote an argument: never a URL beyond its origin.
  console.error(`keeper: ${redact(e?.message ?? e)}\n${USAGE}`);
  process.exit(EXIT.ERROR);
}
if (opts.help) {
  console.log(USAGE);
  process.exit(opts.ok ? EXIT.OK : EXIT.ERROR);
}

runKeeper(opts).then(
  (code) => process.exit(code),
  (e) => {
    console.error(`keeper failed: ${redact(e?.stack || e, [opts.rpcUrl, opts.webhook])}`);
    process.exit(EXIT.ERROR);
  },
);
