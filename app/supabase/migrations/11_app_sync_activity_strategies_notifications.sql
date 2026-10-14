-- Everything the app does, recorded per wallet: actions with their transaction, dollar size and section, so the
-- Portfolio and the platform-wide totals no longer depend on chain scans alone.
create table if not exists public.activity (
  id uuid primary key default gen_random_uuid(),
  wallet text not null references public.profiles(wallet) on delete cascade,
  kind text not null,
  section text not null default 'wallet' check (section in ('spot','perps','launch','moments','wallet','strategy')),
  title text not null check (char_length(title) <= 120),
  subtitle text default '' check (char_length(subtitle) <= 300),
  tx_hash text check (tx_hash is null or tx_hash ~ '^0x[0-9a-f]{64}$'),
  usd numeric,
  fee_usd numeric,
  payload jsonb not null default '{}',
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create unique index if not exists activity_wallet_tx on public.activity (wallet, tx_hash) where tx_hash is not null;
create index if not exists activity_wallet_time on public.activity (wallet, occurred_at desc);
alter table public.activity enable row level security;
drop policy if exists "owner manages own activity" on public.activity;
create policy "owner manages own activity" on public.activity for all to authenticated
  using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

-- Strategy records (delta-neutral, market making, copied traders) so a fresh device restores them after one sign-in.
create table if not exists public.strategies (
  wallet text not null references public.profiles(wallet) on delete cascade,
  id text not null,
  kind text not null check (kind in ('delta_neutral','market_making','copy_trader')),
  data jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (wallet, id)
);
alter table public.strategies enable row level security;
drop policy if exists "owner manages own strategies" on public.strategies;
create policy "owner manages own strategies" on public.strategies for all to authenticated
  using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

-- The in-app notification center, per wallet.
create table if not exists public.notifications (
  wallet text not null references public.profiles(wallet) on delete cascade,
  id uuid not null,
  kind text not null,
  title text not null,
  body text not null default '',
  read boolean not null default false,
  data jsonb not null default '{}',
  created_at timestamptz not null default now(),
  primary key (wallet, id)
);
create index if not exists notifications_wallet_time on public.notifications (wallet, created_at desc);
alter table public.notifications enable row level security;
drop policy if exists "owner manages own notifications" on public.notifications;
create policy "owner manages own notifications" on public.notifications for all to authenticated
  using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

-- Price alerts carry the token's symbol and decimals, and the app's own id, in a payload.
alter table public.alerts add column if not exists payload jsonb not null default '{}';
alter table public.alerts add column if not exists client_id uuid;
create unique index if not exists alerts_wallet_client on public.alerts (wallet, client_id) where client_id is not null;

-- Platform-wide volume, readable by anyone: sums of the activity rows by section, with no wallet exposed.
create or replace function public.platform_volume(since timestamptz default '1970-01-01')
returns table (section text, usd numeric, actions bigint)
language sql security definer set search_path = public stable as $$
  select section, coalesce(sum(usd), 0) as usd, count(*) as actions
  from public.activity
  where occurred_at >= since
  group by section
$$;
grant execute on function public.platform_volume(timestamptz) to anon, authenticated;