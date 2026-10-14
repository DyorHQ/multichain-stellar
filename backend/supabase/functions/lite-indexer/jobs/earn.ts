// Every 10 minutes: a snapshot of each Earn market's rates (docs/DESIGN-stellar-parity.md §6.10). Not written yet:
// the indexer skips a job that is null.
export const earn: (() => Promise<unknown>) | null = null;
