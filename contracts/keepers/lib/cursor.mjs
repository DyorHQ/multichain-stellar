// Log-scan cursors (build 17, K2 / E2). A block-count lookback misses blocks whenever runs are further apart than it
// covers (Monad makes a block every ~0.302 s, not 0.4 s: 10,000 blocks is ~50 minutes, so an hourly run skipped ~10
// minutes of governance events every hour). With --logs-cursor each scan remembers the last block it fully scanned
// (`state.cursors[scanId]`) and the next run starts right after it, however late it runs.
//
//  - First run: from --logs-from N, else head - --logs-lookback, else the head itself (nothing old is re-raised).
//    Governance starts at 108,860,011: just after the 13 reviewed setup events of the v2 deploy.
//  - At most --logs-max-blocks per run (200,000, ~17 h); a capped run raises a "scan behind" warning and catches up
//    over the next runs.
//  - The cursor never moves past a block that was not scanned: it advances chunk by chunk, only after a chunk's logs
//    were fetched and alerted, so a failed read or a run that runs out of time resumes where it stopped. A run scans
//    up to LOGS_HEAD_MARGIN blocks short of the head it read (a lagging backend would otherwise answer the last blocks
//    with nothing).
//
// Without --logs-cursor, --logs-lookback keeps its meaning for ad hoc runs: [head - lookback, head], all or nothing.

export const DEFAULT_LOGS_CHUNK = 1000n; // rpc3 accepts 1,000 blocks (an inclusive span) and refuses 1,001; rpc4 takes 1,001
/** A cursor scan stops this many blocks (~3 s) short of the head it read. The public RPCs are load-balanced: the head
    can come from a backend a few blocks ahead of the one that answers eth_getLogs, which returns logs only up to its
    own head, with no error. Moving the cursor to the head read would then skip the blocks in between for good. */
export const LOGS_HEAD_MARGIN = 10n;
export const DEFAULT_LOGS_MAX_BLOCKS = 200_000n;

export function readCursor(state, scanId) {
  const v = state?.cursors?.[scanId];
  return v === undefined || v === null ? undefined : BigInt(v);
}

export function writeCursor(state, scanId, block) {
  state.cursors ??= {};
  state.cursors[scanId] = BigInt(block).toString();
}

/**
 * The block range one run scans, or null when scanning is off.
 *   useCursor=false: [from ?? head - lookback, head] (null when neither is given).
 *   useCursor=true:  [cursor + 1 | from | head - lookback | head, min(head, start + maxBlocks - 1)];
 *                    `empty` when there is nothing new (the head is at or below the cursor, e.g. a lagging RPC);
 *                    `behind` = blocks left after this run's range.
 */
export function planScan({ cursor, head, from, lookback = 0n, maxBlocks = DEFAULT_LOGS_MAX_BLOCKS, useCursor = false }) {
  const back = lookback > 0n ? (head > lookback ? head - lookback : 0n) : undefined;
  if (!useCursor) {
    const start = from ?? back;
    return start === undefined ? null : { from: start, to: head, behind: 0n, first: true };
  }
  const first = cursor === undefined;
  const start = !first ? cursor + 1n : from ?? back ?? head;
  if (start > head) return { from: start, to: head, behind: 0n, empty: true, first };
  const cap = start + (maxBlocks > 0n ? maxBlocks : 1n) - 1n;
  const to = cap < head ? cap : head;
  return { from: start, to, behind: head - to, first };
}
