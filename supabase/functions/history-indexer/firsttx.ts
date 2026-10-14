// A wallet's first transaction: the first block at which its nonce is ≥ 1 (the app's RPCClient.firstTransactionBlock
// rule), by binary search over eth_getTransactionCount — about 28 sequential reads. The app uses it only to lower its
// own fallback floor for the transfer scans (the server reads those from genesis, D1), so a result is stored only when
// a second endpoint confirms it (D2): load-balanced pools mix archive and pruned nodes, and a pruned node answering 0
// would move the bisection later without an error. A stored block only ever moves earlier (history_set_first_tx).

export type NonceAt = (block: number) => Promise<bigint>;

// The first block whose nonce is ≥ 1, searching (zeroAt, head] when a block with nonce 0 is known, else [0, head];
// null when the nonce at `head` is 0 (no transaction yet).
export async function firstTransactionBlock(nonceAt: NonceAt, head: number, zeroAt?: number): Promise<number | null> {
  if ((await nonceAt(head)) === 0n) return null;
  let low = zeroAt === undefined ? 0 : zeroAt + 1;
  let high = head;
  while (low < high) {
    const mid = low + Math.floor((high - low) / 2);
    if ((await nonceAt(mid)) > 0n) high = mid;
    else low = mid + 1;
  }
  return high;
}

// Whether `block` is the first: nonce(block) ≥ 1 and nonce(block − 1) = 0 (block 0: nonce(0) ≥ 1).
export async function confirmFirstTx(nonceAt: NonceAt, block: number): Promise<boolean> {
  if ((await nonceAt(block)) === 0n) return false;
  return block === 0 || (await nonceAt(block - 1)) === 0n;
}

// ── Over several endpoints ───────────────────────────────────────────────────────────────────────────────────────

// An archive endpoint's nonce read, by label (rpc4 → rpc1 → rpc2 by default: the wide logs endpoint last).
export type NonceSource = { label: string; nonceAt: NonceAt };
export type FirstTxResult =
  | { state: "found"; block: number; source: string; movedEarlier?: boolean }
  | { state: "none" }
  | { state: "same" }            // re-verification: the stored block still holds
  | { state: "unconfirmed" }     // the second endpoint disagreed: nothing is stored
  | { state: "failed" };         // no endpoint answered a read

class NoAnswer extends Error {}

// Reads with fail-over: each read tries the sources in order and moves on after any error (including "historical
// state that is not available" from a pruned node). Remembers which source answered each block.
function failover(sources: readonly NonceSource[], answeredBy: Map<number, string>, except?: string): NonceAt {
  return async (block: number) => {
    for (const s of sources) {
      if (s.label === except) continue;
      try {
        const n = await s.nonceAt(block);
        answeredBy.set(block, s.label);
        return n;
      } catch { /* the next source */ }
    }
    throw new NoAnswer();
  };
}

// Re-reads `block` on a source other than `not`; when no other source answers, on `not` itself after `pauseMs`.
async function reread(sources: readonly NonceSource[], block: number, not: string | undefined, sleep: (ms: number) => Promise<void>,
                      pauseMs: number): Promise<{ nonce: bigint; label: string }> {
  const seen = new Map<number, string>();
  try {
    const nonce = await failover(sources, seen, not)(block);
    return { nonce, label: seen.get(block)! };
  } catch (err) {
    if (!(err instanceof NoAnswer) || not === undefined) throw err;
  }
  const same = sources.find((s) => s.label === not);
  if (!same) throw new NoAnswer();
  await sleep(pauseMs);
  try {
    return { nonce: await same.nonceAt(block), label: same.label };
  } catch {
    throw new NoAnswer();
  }
}

// Bisects, then confirms nonce(b) ≥ 1 and nonce(b − 1) = 0 on a source other than the one that answered each of those
// blocks. `zeroAt`: a block known to have nonce 0 (a `none` result's head), to search only above it.
export async function locateFirstTx(sources: readonly NonceSource[], head: number,
                                    opts: { zeroAt?: number; sleep: (ms: number) => Promise<void>; pauseMs?: number }): Promise<FirstTxResult> {
  const answeredBy = new Map<number, string>();
  let block: number | null;
  try {
    block = await firstTransactionBlock(failover(sources, answeredBy), head, opts.zeroAt);
  } catch (err) {
    if (err instanceof NoAnswer) return { state: "failed" };
    throw err;
  }
  if (block === null) return { state: "none" };
  return await confirmed(sources, block, answeredBy, opts.sleep, opts.pauseMs ?? 2_000);
}

async function confirmed(sources: readonly NonceSource[], block: number, answeredBy: Map<number, string>,
                         sleep: (ms: number) => Promise<void>, pauseMs: number): Promise<FirstTxResult> {
  try {
    const at = await reread(sources, block, answeredBy.get(block), sleep, pauseMs);
    if (at.nonce === 0n) return { state: "unconfirmed" };
    if (block > 0) {
      const before = await reread(sources, block - 1, answeredBy.get(block - 1), sleep, pauseMs);
      if (before.nonce !== 0n) return { state: "unconfirmed" };
    }
    return { state: "found", block, source: `${answeredBy.get(block) ?? at.label}+${at.label}` };
  } catch (err) {
    if (err instanceof NoAnswer) return { state: "failed" };
    throw err;
  }
}

// A found block checked over 7 days ago: one read of nonce(b − 1) on a source other than the one that found it. 0 →
// still the first (`same`: refresh its check time). ≥ 1 → an earlier transaction exists: bisect [0, b − 1] again and
// confirm (the database accepts only an earlier block).
export async function reverifyFirstTx(sources: readonly NonceSource[], stored: { block: number; source: string | null },
                                      opts: { sleep: (ms: number) => Promise<void>; pauseMs?: number }): Promise<FirstTxResult> {
  if (stored.block === 0) return { state: "same" };
  const finder = stored.source?.split("+")[0];
  let before: { nonce: bigint; label: string };
  try {
    before = await reread(sources, stored.block - 1, finder, opts.sleep, opts.pauseMs ?? 2_000);
  } catch (err) {
    if (err instanceof NoAnswer) return { state: "failed" };
    throw err;
  }
  if (before.nonce === 0n) return { state: "same" };
  const found = await locateFirstTx(sources, stored.block - 1, opts);
  return found.state === "found" ? { ...found, movedEarlier: true } : found.state === "none" ? { state: "unconfirmed" } : found;
}
