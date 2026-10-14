// Every 10 minutes: indexed launch-token balances against a live balance() (docs/DESIGN-stellar-parity.md §6.11).
// Not written yet: the indexer skips a job that is null.
export const reconcile: (() => Promise<unknown>) | null = null;
