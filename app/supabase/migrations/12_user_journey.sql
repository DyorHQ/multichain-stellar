-- 12_user_journey — a complete per-wallet "user journey" rollup over the activity log, plus a platform-wide
-- analyst aggregate. Additive only: no existing table, policy, or function is altered.
--
-- The journey is a SECURITY INVOKER view, so it inherits the RLS of public.activity / public.notifications:
-- a signed-in wallet reads exactly its own row; anon (publishable key) reads nothing. Cross-wallet platform
-- analytics go through platform_journey(), a SECURITY DEFINER function that never exposes a wallet — the same
-- pattern as the existing platform_volume().

create or replace view public.user_journey
with (security_invoker = on) as
select
  a.wallet,
  p.handle,
  p.display_name,
  min(a.occurred_at)                                                             as first_activity_at,
  max(a.occurred_at)                                                             as last_activity_at,
  count(*)                                                                       as total_events,
  -- spot (swaps)
  coalesce(sum(a.usd) filter (where a.section = 'spot'), 0)                      as spot_volume_usd,
  count(*)            filter (where a.section = 'spot')                          as spot_trades,
  -- perps (opened/closed positions only — collateral moves are deposits/withdrawals, not volume)
  coalesce(sum(a.usd) filter (where a.section = 'perps' and a.kind = 'perp'), 0) as perps_volume_usd,
  count(*)            filter (where a.section = 'perps' and a.kind = 'perp')     as perps_trades,
  -- launchpad (bonding-curve buys/sells, plus coins created)
  coalesce(sum(a.usd) filter (where a.section in ('launch','launchpad')), 0)     as launchpad_volume_usd,
  count(*)            filter (where a.section in ('launch','launchpad') and a.kind in ('buy','sell')) as launchpad_trades,
  count(*)            filter (where a.kind = 'launch')                           as launches_created,
  -- moments (mint / collect / claim)
  coalesce(sum(a.usd) filter (where a.section = 'moments'), 0)                   as moments_volume_usd,
  count(*)            filter (where a.section = 'moments')                       as moments_actions,
  -- bridge (cross-chain)
  coalesce(sum(a.usd) filter (where a.kind = 'bridge' or a.section = 'bridge'), 0) as bridge_volume_usd,
  count(*)            filter (where a.kind = 'bridge' or a.section = 'bridge')   as bridge_count,
  -- deposits / withdrawals (collateral funding + off-ramp)
  coalesce(sum(a.usd) filter (where a.kind = 'deposit'), 0)                      as deposits_usd,
  count(*)            filter (where a.kind = 'deposit')                          as deposits_count,
  coalesce(sum(a.usd) filter (where a.kind = 'withdraw'), 0)                     as withdrawals_usd,
  count(*)            filter (where a.kind = 'withdraw')                         as withdrawals_count,
  -- other wallet sends (legacy / uncategorised transfers)
  coalesce(sum(a.usd) filter (where a.kind = 'send'), 0)                         as transfers_usd,
  count(*)            filter (where a.kind = 'send')                             as transfers_count,
  -- lifetime trading volume across the four trading surfaces (excludes transfers/deposits/withdrawals/bridge)
  ( coalesce(sum(a.usd) filter (where a.section = 'spot'), 0)
  + coalesce(sum(a.usd) filter (where a.section = 'perps' and a.kind = 'perp'), 0)
  + coalesce(sum(a.usd) filter (where a.section in ('launch','launchpad') and a.kind in ('buy','sell')), 0)
  + coalesce(sum(a.usd) filter (where a.section = 'moments'), 0) )                as total_volume_usd,
  coalesce(sum(a.fee_usd), 0)                                                    as total_fees_usd,
  (select count(*) from public.notifications n where n.wallet = a.wallet)                    as notifications_count,
  (select count(*) from public.notifications n where n.wallet = a.wallet and n.read = false) as unread_notifications_count
from public.activity a
left join public.profiles p on p.wallet = a.wallet
group by a.wallet, p.handle, p.display_name;

comment on view public.user_journey is
  'Per-wallet complete journey over public.activity (spot, perps, launchpad, moments, bridge, deposits, withdrawals) joined to the profile handle. SECURITY INVOKER: a signed-in wallet reads only its own row; anon reads nothing.';

grant select on public.user_journey to anon, authenticated;

-- Platform-wide totals by domain, no wallet exposed — callable with the publishable key, like platform_volume().
create or replace function public.platform_journey(since timestamp with time zone default '1970-01-01 00:00:00+00'::timestamptz)
returns table(domain text, volume_usd numeric, actions bigint, wallets bigint)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with tagged as (
    select
      case
        when kind = 'bridge' or section = 'bridge'          then 'bridge'
        when kind = 'deposit'                               then 'deposits'
        when kind = 'withdraw'                              then 'withdrawals'
        when section = 'spot'                               then 'spot'
        when section = 'perps' and kind = 'perp'            then 'perps'
        when section in ('launch','launchpad')              then 'launchpad'
        when section = 'moments'                            then 'moments'
        else 'other'
      end as domain,
      usd, wallet
    from public.activity
    where occurred_at >= since
  )
  select domain, coalesce(sum(usd), 0) as volume_usd, count(*) as actions, count(distinct wallet) as wallets
  from tagged
  group by domain
$function$;

comment on function public.platform_journey(timestamp with time zone) is
  'Platform-wide journey totals by domain (spot/perps/launchpad/moments/bridge/deposits/withdrawals), no wallet exposed. SECURITY DEFINER, callable with the publishable key — mirrors platform_volume().';

grant execute on function public.platform_journey(timestamp with time zone) to anon, authenticated;
