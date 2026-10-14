-- DyorHQ backend foundation: wallet-based auth helper, profiles, social graph, and cross-device sync.
-- Every row is owned by a wallet address (lowercased 0x-hex). RLS keys off the JWT's wallet_address claim,
-- minted by the wallet-auth Edge Function. No private keys or secrets are ever stored here.

create extension if not exists pgcrypto;

-- The caller's verified wallet address (lowercased) from the JWT, or null when unauthenticated.
create or replace function public.app_wallet() returns text
language sql stable
as $$
  select lower(nullif(current_setting('request.jwt.claims', true)::json ->> 'wallet_address', ''))
$$;

-- Keep updated_at current on any row change.
create or replace function public.touch_updated_at() returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Profiles: one per wallet, publicly readable (social), writable only by the owner.
create table public.profiles (
  wallet text primary key check (wallet ~ '^0x[0-9a-f]{40}$'),
  handle text unique check (handle ~ '^[a-z0-9_]{3,20}$'),
  display_name text check (char_length(display_name) <= 40),
  bio text check (char_length(bio) <= 280),
  avatar_url text check (avatar_url is null or char_length(avatar_url) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

create policy "profiles are public" on public.profiles for select using (true);
create policy "owner creates own profile" on public.profiles for insert to authenticated with check (wallet = public.app_wallet());
create policy "owner updates own profile" on public.profiles for update to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());
create policy "owner deletes own profile" on public.profiles for delete to authenticated using (wallet = public.app_wallet());

-- Social graph: who follows whom. Publicly readable; each wallet manages only its own follows.
create table public.follows (
  follower text not null references public.profiles(wallet) on delete cascade,
  following text not null references public.profiles(wallet) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, following),
  constraint no_self_follow check (follower <> following)
);
create index follows_following_idx on public.follows (following);
alter table public.follows enable row level security;

create policy "follows are public" on public.follows for select using (true);
create policy "owner manages own follows" on public.follows for all to authenticated using (follower = public.app_wallet()) with check (follower = public.app_wallet());

-- Cross-device watchlist: private to the owner.
create table public.watchlist (
  wallet text not null references public.profiles(wallet) on delete cascade,
  kind text not null default 'token' check (kind in ('token','perp','launch')),
  ref text not null,               -- token symbol/address, perp market id, or launch id
  created_at timestamptz not null default now(),
  primary key (wallet, kind, ref)
);
alter table public.watchlist enable row level security;
create policy "owner reads watchlist" on public.watchlist for select to authenticated using (wallet = public.app_wallet());
create policy "owner writes watchlist" on public.watchlist for all to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());

-- Cross-device app settings (non-sensitive: appearance, defaults). Private to the owner.
create table public.user_settings (
  wallet text primary key references public.profiles(wallet) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.user_settings enable row level security;
create trigger user_settings_touch before update on public.user_settings for each row execute function public.touch_updated_at();
create policy "owner reads settings" on public.user_settings for select to authenticated using (wallet = public.app_wallet());
create policy "owner writes settings" on public.user_settings for all to authenticated using (wallet = public.app_wallet()) with check (wallet = public.app_wallet());
