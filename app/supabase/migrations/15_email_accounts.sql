-- 15_email_accounts — binds an OTP-verified email to the wallet address it derived, so email+password LOGIN can
-- stay code-free while still being impossible to use with an unverified/fake email. Additive only.
--
-- The row is written by the wallet itself after sign-up (authenticated by wallet-auth), one binding per email.
-- Login verifies through email_account_matches(): a boolean that leaks neither the address nor whether an email is
-- registered (a wrong password derives a different address, which returns false exactly like an unknown email).

create table if not exists public.email_accounts (
  email       text primary key,
  wallet      text not null,
  verified_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
alter table public.email_accounts enable row level security;
drop policy if exists "owner manages own email binding" on public.email_accounts;
create policy "owner manages own email binding" on public.email_accounts for all to authenticated
  using (wallet = app_wallet()) with check (wallet = app_wallet());
grant select, insert, update, delete on public.email_accounts to authenticated;
create index if not exists email_accounts_wallet_idx on public.email_accounts (wallet);
comment on table public.email_accounts is 'One binding per OTP-verified email → the wallet address it derived. Written by the wallet after sign-up; read by login only through email_account_matches().';

create or replace function public.email_account_matches(p_email text, p_wallet text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.email_accounts
    where email = lower(trim(p_email)) and wallet = lower(p_wallet)
  );
$function$;
grant execute on function public.email_account_matches(text, text) to anon, authenticated;
comment on function public.email_account_matches(text, text) is
  'Login gate: true iff the (OTP-verified) email is bound to exactly this wallet address. Returns only a boolean — cannot enumerate emails or addresses.';
