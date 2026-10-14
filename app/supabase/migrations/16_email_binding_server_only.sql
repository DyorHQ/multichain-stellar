-- 16_email_binding_server_only — the email -> wallet binding must be OTP-attested, and only the email-rebind edge
-- function can prove that (it verifies a Privy email-OTP access token + a signature from the wallet, then writes with
-- the service role). Migration 15 wrote the binding straight from the client under owner RLS, which proves the caller
-- controls the WALLET but NOT that they own the EMAIL — so anyone can mint a wallet-auth session for a self-generated
-- keypair and POST arbitrary (email -> self) rows to PostgREST, squatting emails so their real owners can't sign up or
-- log in (recoverable only via the OTP forgot-password path; no fund loss, but a real onboarding DoS).
--
-- Fix: revoke every direct write. The service role used by the email-rebind function becomes the ONLY writer, so a row
-- can exist only after a Privy email OTP + a wallet signature were verified server-side. Sign-up and forgot-password
-- both go through that function now. Reads stay owner-scoped (the login gate itself reads via email_account_matches,
-- a security-definer function, so it is unaffected).
revoke insert, update, delete on public.email_accounts from authenticated;
revoke insert, update, delete on public.email_accounts from anon;
drop policy if exists "owner manages own email binding" on public.email_accounts;
create policy "owner reads own email binding" on public.email_accounts
  for select to authenticated using (wallet = app_wallet());
comment on table public.email_accounts is
  'One binding per OTP-verified email -> the wallet it derived. Written ONLY by the email-rebind edge function (service role) after it verifies a Privy email OTP + a signature from the wallet. Authenticated users may read only their own row; the login gate reads via email_account_matches().';
