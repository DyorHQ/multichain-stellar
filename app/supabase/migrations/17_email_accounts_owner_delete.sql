-- 17_email_accounts_owner_delete — account deletion must remove the user's own email->wallet binding. It has no FK to
-- profiles, so it does NOT cascade when the profile row is deleted; without this, deleting an account leaves the
-- binding behind, and because the wallet is deterministic (re-derived from the same email+password) the login gate
-- (email_account_matches) still matches and lets the "deleted" account log back in. Migration 16 revoked DELETE, so
-- restore it — but only DELETE, and only owner-scoped: RLS limits it to rows whose wallet is the caller's, so you can
-- delete only a binding that points at YOUR wallet (no way to touch anyone else's). INSERT/UPDATE stay revoked
-- (those are the squatting vectors and still go through the email-rebind edge function).
grant delete on public.email_accounts to authenticated;
drop policy if exists "owner deletes own email binding" on public.email_accounts;
create policy "owner deletes own email binding" on public.email_accounts
  for delete to authenticated using (wallet = app_wallet());
