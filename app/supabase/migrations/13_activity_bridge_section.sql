-- 13_activity_bridge_section — allow section='bridge' (the Home Bridge feature) on activity rows.
-- Additive widening of the existing section CHECK: every current row already satisfies it, so nothing is
-- rejected. 'launchpad' is also permitted as a forward-compatible alias for 'launch'; 'strategy' is kept for
-- backward compatibility with old rows.
alter table public.activity drop constraint if exists activity_section_check;
alter table public.activity add constraint activity_section_check
  check (section = any (array['spot','perps','launch','launchpad','moments','wallet','bridge','strategy']));
