-- rls_auto_enable is an event-trigger function (auto-enables RLS on new public tables); it should not be
-- callable via the REST RPC surface. Event triggers still fire regardless of these grants.
revoke execute on function public.rls_auto_enable() from anon, authenticated, public;