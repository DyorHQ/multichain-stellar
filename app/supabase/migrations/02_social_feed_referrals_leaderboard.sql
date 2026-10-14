-- Social: activity feed, comments, reactions, referrals, and a leaderboard cache.

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author text not null references public.profiles(wallet) on delete cascade,
  kind text not null default 'note' check (kind in ('note','trade','launch')),
  body text check (char_length(body) <= 500),
  ref jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index posts_author_idx on public.posts (author, created_at desc);
create index posts_created_idx on public.posts (created_at desc);
alter table public.posts enable row level security;
create policy "posts are public" on public.posts for select using (true);
create policy "author writes own posts" on public.posts for insert to authenticated with check (author = public.app_wallet());
create policy "author deletes own posts" on public.posts for delete to authenticated using (author = public.app_wallet());

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author text not null references public.profiles(wallet) on delete cascade,
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index comments_post_idx on public.comments (post_id, created_at);
alter table public.comments enable row level security;
create policy "comments are public" on public.comments for select using (true);
create policy "author writes own comments" on public.comments for insert to authenticated with check (author = public.app_wallet());
create policy "author deletes own comments" on public.comments for delete to authenticated using (author = public.app_wallet());

create table public.reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  wallet text not null references public.profiles(wallet) on delete cascade,
  emoji text not null default U&'\2764' check (char_length(emoji) <= 8),
  created_at timestamptz not null default now(),
  primary key (post_id, wallet)
);
alter table public.reactions enable row level security;
create policy "reactions are public" on public.reactions for select using (true);
create policy "owner manages own reactions" on public.reactions for all to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

create table public.referral_codes (
  wallet text primary key references public.profiles(wallet) on delete cascade,
  code text unique not null check (code ~ '^[A-Z0-9]{4,12}$'),
  created_at timestamptz not null default now()
);
alter table public.referral_codes enable row level security;
create policy "codes are public" on public.referral_codes for select using (true);
create policy "owner manages own code" on public.referral_codes for all to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

create table public.referrals (
  referee text primary key references public.profiles(wallet) on delete cascade,
  referrer text not null references public.profiles(wallet) on delete cascade,
  code text not null,
  created_at timestamptz not null default now(),
  constraint no_self_referral check (referee <> referrer)
);
create index referrals_referrer_idx on public.referrals (referrer);
alter table public.referrals enable row level security;
create policy "referrals readable by parties" on public.referrals for select to authenticated using (referee = public.app_wallet() or referrer = public.app_wallet());
create policy "referee records own referral" on public.referrals for insert to authenticated with check (referee = public.app_wallet());

-- Leaderboard cache: written by the stats Edge Function (service_role); public read.
create table public.leaderboard (
  wallet text not null references public.profiles(wallet) on delete cascade,
  period text not null default 'all' check (period in ('day','week','month','all')),
  pnl_usd numeric not null default 0,
  volume_usd numeric not null default 0,
  roi_pct numeric,
  win_rate numeric,
  updated_at timestamptz not null default now(),
  primary key (wallet, period)
);
create index leaderboard_rank_idx on public.leaderboard (period, pnl_usd desc);
alter table public.leaderboard enable row level security;
create policy "leaderboard is public" on public.leaderboard for select using (true);
