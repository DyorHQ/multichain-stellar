-- Copy trading (hybrid): leaders opt in; followers copy in signal or auto mode with caps.

create table public.leaders (
  wallet text primary key references public.profiles(wallet) on delete cascade,
  enabled boolean not null default true,
  fee_bps int not null default 0 check (fee_bps between 0 and 1000),
  followers int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.leaders enable row level security;
create policy "leaders are public" on public.leaders for select using (true);
create policy "owner manages own leader listing" on public.leaders for all to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

create table public.copy_relationships (
  follower text not null references public.profiles(wallet) on delete cascade,
  leader text not null references public.leaders(wallet) on delete cascade,
  mode text not null default 'signal' check (mode in ('signal','auto')),
  max_notional_usd numeric check (max_notional_usd is null or max_notional_usd > 0),
  markets text[],
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (follower, leader),
  constraint no_self_copy check (follower <> leader)
);
create index copy_leader_idx on public.copy_relationships (leader) where enabled;
alter table public.copy_relationships enable row level security;
create policy "parties read copy rels" on public.copy_relationships for select to authenticated using (follower = public.app_wallet() or leader = public.app_wallet());
create policy "follower manages own copy rels" on public.copy_relationships for all to authenticated using (follower = public.app_wallet()) with check (follower = public.app_wallet());

-- The encrypted scoped Perpl trade key a follower entrusts for AUTO execution. Never a wallet private key,
-- always encrypted at rest with a server-held key. No SELECT policy: not even the owner reads it back — only
-- the service role (which bypasses RLS) decrypts it to mirror trades.
create table public.copy_grants (
  follower text primary key references public.profiles(wallet) on delete cascade,
  encrypted_key text not null,
  created_at timestamptz not null default now()
);
alter table public.copy_grants enable row level security;
create policy "owner inserts own grant" on public.copy_grants for insert to authenticated with check (follower = public.app_wallet());
create policy "owner updates own grant" on public.copy_grants for update to authenticated using (follower = public.app_wallet()) with check (follower = public.app_wallet());
create policy "owner deletes own grant" on public.copy_grants for delete to authenticated using (follower = public.app_wallet());

create table public.copy_events (
  id uuid primary key default gen_random_uuid(),
  leader text not null references public.profiles(wallet) on delete cascade,
  follower text references public.profiles(wallet) on delete cascade,
  market text,
  side text check (side in ('long','short')),
  size numeric,
  mode text check (mode in ('signal','auto')),
  status text not null default 'signaled' check (status in ('signaled','placed','skipped','failed')),
  detail text,
  created_at timestamptz not null default now()
);
create index copy_events_follower_idx on public.copy_events (follower, created_at desc);
create index copy_events_leader_idx on public.copy_events (leader, created_at desc);
alter table public.copy_events enable row level security;
create policy "parties read copy events" on public.copy_events for select to authenticated using (follower = public.app_wallet() or leader = public.app_wallet());
