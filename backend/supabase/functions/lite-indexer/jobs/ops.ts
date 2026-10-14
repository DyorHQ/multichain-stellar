// Every 10 minutes: the sponsor's and the keeper's XLM, with a warning when low (docs/DESIGN-stellar-parity.md
// §6.11). Not written yet: the indexer skips a job that is null.
export const ops: (() => Promise<unknown>) | null = null;
