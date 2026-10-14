-- 18_close_anonymous_security_definer_rpcs — security audit 2026-09-22 (items #2 and #13).
--
-- These SECURITY DEFINER functions bypass row-level security and were executable by PUBLIC (so by anon, i.e. anyone
-- holding the app's publishable key):
--   * email_account_matches(email, wallet) — an ONLINE ORACLE for the email+password wallet: derive a wallet from a
--     guessed password, ask whether it is bound to the victim's email. The app no longer calls it: from build 12 the
--     derived wallet signs in (wallet-auth) and reads its own binding through the "owner reads own email binding" RLS
--     policy. Builds <= 11 used it for login, so email login on those builds stops working — update to build 12.
--   * platform_volume(since) / platform_journey(since) — per-domain aggregates in which several groups contain a single
--     wallet, so exact amounts and (by bisecting `since`) event times of one user's activity leaked. No app caller.
-- Execution stays with the table owner / service role only. Nothing is dropped, so this is reversible with a GRANT.

revoke execute on function public.email_account_matches(text, text) from public, anon, authenticated;
revoke execute on function public.platform_volume(timestamp with time zone) from public, anon, authenticated;
revoke execute on function public.platform_journey(timestamp with time zone) from public, anon, authenticated;
