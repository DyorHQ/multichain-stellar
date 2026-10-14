-- Push delivery: APNs device tokens and the alert rules the watcher evaluates.

create table public.device_tokens (
  wallet text not null references public.profiles(wallet) on delete cascade,
  token text not null,
  platform text not null default 'ios' check (platform in ('ios')),
  environment text not null default 'production' check (environment in ('production','sandbox')),
  updated_at timestamptz not null default now(),
  primary key (wallet, token)
);
alter table public.device_tokens enable row level security;
create policy "owner manages own devices" on public.device_tokens for all to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

create table public.alerts (
  id uuid primary key default gen_random_uuid(),
  wallet text not null references public.profiles(wallet) on delete cascade,
  kind text not null check (kind in ('price','fill','liquidation','launch','copy')),
  market text,
  op text check (op in ('above','below')),
  threshold numeric,
  enabled boolean not null default true,
  last_fired_at timestamptz,
  created_at timestamptz not null default now()
);
create index alerts_wallet_idx on public.alerts (wallet);
create index alerts_active_idx on public.alerts (kind) where enabled;
alter table public.alerts enable row level security;
create policy "owner manages own alerts" on public.alerts for all to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());
