// The hand-written keeper ABIs must match the contracts. When `forge build` artifacts exist (contracts/out), every
// function and event the keepers use is checked against them by name, input types and output types. The v2 source
// only ADDS functions, so everything the keepers call on v1 must still be present, unchanged. Skipped without out/.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as abis from "../lib/abis.mjs";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "out");

const MAP = {
  momentsFactoryAbi: "MomentsFactory",
  momentsFactoryV2Abi: "MomentsFactory",
  momentCollectAbi: "MomentCollect",
  momentGraduationAbi: "MomentGraduation",
  momentFeeHookAbi: "MomentFeeHook",
  momentBuybackAbi: "MomentBuyback",
  momentLockerV2Abi: "MomentLocker",
  launchpadFactoryAbi: "LaunchpadFactory",
  bondingCurveAbi: "BondingCurve",
  mondayExecutorAbi: "MondayGraduationExecutor",
  memeHookAbi: "MemeHook",
  memeHookV2Abi: "MemeHook",
  launchpadFactoryV2Abi: "LaunchpadFactory",
  mondayFeeVaultAbi: "MondayFeeVault",
};

// Flatten a param list to canonical types (tuples expanded) so struct/field names don't matter.
function sig(params = []) {
  return params.map((p) => (p.type.startsWith("tuple") ? `(${sig(p.components)})${p.type.slice(5)}` : p.type === "address" && p.internalType?.startsWith("Currency") ? "address" : p.type)).join(",");
}

function artifact(name) {
  const f = join(OUT, `${name}.sol`, `${name}.json`);
  return existsSync(f) ? JSON.parse(readFileSync(f, "utf8")).abi : null;
}

for (const [exportName, contract] of Object.entries(MAP)) {
  const real = artifact(contract);
  test(`${exportName} matches ${contract}`, { skip: real ? false : "no forge artifacts (run forge build)" }, () => {
    for (const item of abis[exportName]) {
      const match = real.find((r) => r.type === item.type && r.name === item.name && sig(r.inputs) === sig(item.inputs));
      assert.ok(match, `${contract}.${item.name}(${sig(item.inputs)}) not found`);
      if (item.type === "function") assert.equal(sig(match.outputs), sig(item.outputs), `${contract}.${item.name} outputs`);
    }
  });
}
