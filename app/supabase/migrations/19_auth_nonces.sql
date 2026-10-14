-- 19_auth_nonces — server-issued, single-use sign-in nonces for the wallet-auth edge function (security audit
-- 2026-09-22: "the sign-in message has no single-use nonce", so a signed sign-in message could be replayed for a fresh
-- session for up to 10 minutes).
--
-- wallet-auth issues a 32-byte random nonce bound to lower(wallet) with a 5-minute expiry, and after verifying the
-- wallet's signature consumes it atomically (UPDATE … SET used_at = now() WHERE used_at IS NULL AND expires_at > now()).
-- Only the edge function touches this table, through the service role (which bypasses RLS): RLS is on with NO
-- policies and every privilege is revoked from anon/authenticated, so the API keys cannot read, mint or burn nonces.
-- The function keeps at most 10 pending nonces per wallet by evicting the oldest, and deletes every expired row on each
-- issue (an expired nonce can never be consumed), so the table only holds about 5 minutes of issuance.
--
-- Reverse: drop table public.auth_nonces;  (and redeploy the previous wallet-auth, which did not use it)

create table if not exists public.auth_nonces (
  nonce      text primary key check (nonce ~ '^[0-9a-f]{64}$'),
  wallet     text not null check (wallet ~ '^0x[0-9a-f]{40}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz
);
alter table public.auth_nonces enable row level security;
revoke all on public.auth_nonces from public, anon, authenticated;

-- Pending-per-wallet lookup (the 10-outstanding cap) and the expiry purge.
create index if not exists auth_nonces_wallet_pending_idx on public.auth_nonces (wallet, expires_at) where used_at is null;
create index if not exists auth_nonces_expires_at_idx on public.auth_nonces (expires_at);

comment on table public.auth_nonces is
  'Single-use sign-in nonces issued by the wallet-auth edge function (5-minute expiry, bound to the lowercased wallet, consumed atomically after the signature verifies). Service role only: RLS on, no policies, no anon/authenticated grants.';
