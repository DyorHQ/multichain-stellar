// Daily: drops reference candles past their retention (docs/DESIGN-stellar-parity.md §6.12). Not written yet: the
// indexer skips a job that is null.
export const purge: (() => Promise<unknown>) | null = null;
