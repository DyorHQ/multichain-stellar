-- 14_sessions_and_journey_lifecycle — sign-in/sign-out session tracking, and rebuild user_journey on the profile
-- base so every user (even one with no activity yet) appears with their joined / sign-in / sign-out times.
-- Internal analytics only: user_journey is no longer granted to anon/authenticated (queried by the service role).

create table if not exists public.sessions (
  id            uuid primary key default gen_random_uuid(),
  wallet        text not null references public.profiles(wallet) on delete cascade,
  signed_in_at  timestamptz not null default now(),
  signed_out_at timestamptz,
  platform      text not null default 'ios',
  created_at    timestamptz not null default now()
);
alter table public.sessions enable row level security;
drop policy if exists "owner manages own sessions" on public.sessions;
create policy "owner manages own sessions" on public.sessions for all to authenticated
  using (wallet = app_wallet()) with check (wallet = app_wallet());
grant select, insert, update, delete on public.sessions to authenticated;
create index if not exists sessions_wallet_signed_in_idx on public.sessions (wallet, signed_in_at desc);
comment on table public.sessions is 'One row per app sign-in: signed_in_at set on sign-in, signed_out_at set on explicit sign-out (null = still signed in / ended abnormally). Feeds user_journey.';

drop view if exists public.user_journey;
create view public.user_journey with (security_invoker = on) as
with act as (
  select
    wallet,
    min(occurred_at) as first_activity_at,
    max(occurred_at) as last_activity_at,
    count(*)         as total_events,
    coalesce(sum(usd) filter (where section = 'spot'), 0)                          as spot_volume_usd,
    count(*)            filter (where section = 'spot')                            as spot_trades,
    coalesce(sum(usd) filter (where section = 'perps' and kind = 'perp'), 0)       as perps_volume_usd,
    count(*)            filter (where section = 'perps' and kind = 'perp')         as perps_trades,
    coalesce(sum(usd) filter (where section in ('launch','launchpad')), 0)         as launchpad_volume_usd,
    count(*)            filter (where section in ('launch','launchpad') and kind in ('buy','sell')) as launchpad_trades,
    count(*)            filter (where kind = 'launch')                             as launches_created,
    coalesce(sum(usd) filter (where section = 'moments'), 0)                       as moments_volume_usd,
    count(*)            filter (where section = 'moments')                         as moments_actions,
    coalesce(sum(usd) filter (where kind = 'bridge' or section = 'bridge'), 0)     as bridge_volume_usd,
    count(*)            filter (where kind = 'bridge' or section = 'bridge')       as bridge_count,
    coalesce(sum(usd) filter (where kind = 'deposit'), 0)                          as deposits_usd,
    count(*)            filter (where kind = 'deposit')                            as deposits_count,
    coalesce(sum(usd) filter (where kind = 'withdraw'), 0)                         as withdrawals_usd,
    count(*)            filter (where kind = 'withdraw')                           as withdrawals_count,
    coalesce(sum(usd) filter (where kind = 'send'), 0)                             as transfers_usd,
    count(*)            filter (where kind = 'send')                               as transfers_count,
    ( coalesce(sum(usd) filter (where section = 'spot'), 0)
    + coalesce(sum(usd) filter (where section = 'perps' and kind = 'perp'), 0)
    + coalesce(sum(usd) filter (where section in ('launch','launchpad') and kind in ('buy','sell')), 0)
    + coalesce(sum(usd) filter (where section = 'moments'), 0) )                   as total_volume_usd,
    coalesce(sum(fee_usd), 0)                                                      as total_fees_usd
  from public.activity group by wallet
),
ses as (
  select wallet, count(*) as sessions_count, min(signed_in_at) as first_sign_in_at,
         max(signed_in_at) as last_sign_in_at, max(signed_out_at) as last_sign_out_at
  from public.sessions group by wallet
),
notif as (
  select wallet, count(*) as notifications_count, count(*) filter (where not read) as unread_notifications_count
  from public.notifications group by wallet
)
select
  p.wallet, p.handle, p.display_name,
  p.created_at                                    as joined_at,
  ses.first_sign_in_at, ses.last_sign_in_at, ses.last_sign_out_at,
  coalesce(ses.sessions_count, 0)                 as sessions_count,
  act.first_activity_at, act.last_activity_at,
  coalesce(act.total_events, 0)                   as total_events,
  coalesce(act.spot_volume_usd, 0)                as spot_volume_usd,
  coalesce(act.spot_trades, 0)                    as spot_trades,
  coalesce(act.perps_volume_usd, 0)               as perps_volume_usd,
  coalesce(act.perps_trades, 0)                   as perps_trades,
  coalesce(act.launchpad_volume_usd, 0)           as launchpad_volume_usd,
  coalesce(act.launchpad_trades, 0)               as launchpad_trades,
  coalesce(act.launches_created, 0)               as launches_created,
  coalesce(act.moments_volume_usd, 0)             as moments_volume_usd,
  coalesce(act.moments_actions, 0)                as moments_actions,
  coalesce(act.bridge_volume_usd, 0)              as bridge_volume_usd,
  coalesce(act.bridge_count, 0)                   as bridge_count,
  coalesce(act.deposits_usd, 0)                   as deposits_usd,
  coalesce(act.deposits_count, 0)                 as deposits_count,
  coalesce(act.withdrawals_usd, 0)                as withdrawals_usd,
  coalesce(act.withdrawals_count, 0)              as withdrawals_count,
  coalesce(act.transfers_usd, 0)                  as transfers_usd,
  coalesce(act.transfers_count, 0)                as transfers_count,
  coalesce(act.total_volume_usd, 0)               as total_volume_usd,
  coalesce(act.total_fees_usd, 0)                 as total_fees_usd,
  coalesce(notif.notifications_count, 0)          as notifications_count,
  coalesce(notif.unread_notifications_count, 0)   as unread_notifications_count
from public.profiles p
left join act   on act.wallet   = p.wallet
left join ses   on ses.wallet   = p.wallet
left join notif on notif.wallet = p.wallet;

comment on view public.user_journey is
  'Internal analytics: one row per user (profile) = username/wallet, joined_at, sign-in/out times + session count, and the full per-domain activity rollup (spot/perps/launchpad/moments/bridge/deposits/withdrawals) with notification counts. Queried by the service role; not exposed to anon/authenticated.';

revoke all on public.user_journey from anon, authenticated;
