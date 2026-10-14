// Launch tokens' and graduated pairs' events, a cursor per watch group (docs/DESIGN-stellar-parity.md §6.11). Not
// written yet: the indexer skips a job that is null.
export const watch: (() => Promise<unknown>) | null = null;
