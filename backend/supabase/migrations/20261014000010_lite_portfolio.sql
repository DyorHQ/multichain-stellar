-- Portfolio and Recent Activity reads (docs/DESIGN-stellar-parity.md §6.7, §6.10 and §6.15; WP-18): an account's logged
-- transactions by section and time (GET /v1/activity?section=, Portfolio's network fees per section), its curve trades
-- and collects by time (Portfolio's launch and Moments figures), and its bridge and anchor transfers by time (both
-- lists). launch_trades and moment_collects have had theirs since migration 1, under the same names: created here only
-- where they are missing. Indexes only: no table or function to grant, and RLS stays as migration 4 set it.

create index if not exists tx_log_section on lite.tx_log (address, section, created_at desc);
create index if not exists launch_trades_trader on lite.launch_trades (trader, ts desc);
create index if not exists moment_collects_collector on lite.moment_collects (collector, ts desc);
create index if not exists bridge_transfers_address on lite.bridge_transfers (address, created_at desc);
create index if not exists anchor_transfers_address on lite.anchor_transfers (address, created_at desc);
