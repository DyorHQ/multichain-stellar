-- Cached index of on-chain launchpad coins for instant discovery/search. Written by the indexer (service_role).

create table public.launches (
  id text primary key,
  token_address text,
  creator text,
  name text,
  symbol text,
  description text,
  image_url text,
  socials jsonb not null default '{}'::jsonb,
  pair_token text,
  status text not null default 'active' check (status in ('active','graduated','closed')),
  price_usd numeric,
  market_cap_usd numeric,
  volume_24h_usd numeric,
  holders int,
  created_at timestamptz,
  indexed_at timestamptz not null default now()
);
create index launches_status_idx on public.launches (status, market_cap_usd desc nulls last);
create index launches_created_idx on public.launches (created_at desc nulls last);
create index launches_symbol_idx on public.launches (lower(symbol));
alter table public.launches enable row level security;
create policy "launches are public" on public.launches for select using (true);
