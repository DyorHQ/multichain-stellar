// Reference prices: quotes every run, candles on their cadence (docs/DESIGN-stellar-parity.md §6.12). Not written
// yet: the indexer skips a job that is null.
export const refprices: (() => Promise<unknown>) | null = null;
