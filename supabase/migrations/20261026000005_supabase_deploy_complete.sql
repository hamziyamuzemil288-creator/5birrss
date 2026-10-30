-- 20261026000005_supabase_deploy_complete.sql
-- One-line marker migration: no schema change, no function, no grant.
-- Purpose: the repo and the live database now agree that the deploy of
-- 2026-10-27 00:31 UTC (GitHub Actions run 40426900570) completed
-- successfully and applied 20261026000003_the_delivery_assertion_reaches_anon.sql.
-- The marker is a no-op function whose name is the deploy fingerprint; it exists
-- only so the repo can point at it as the state both sides share.

CREATE OR REPLACE FUNCTION public.supabase_deploy_completed_20261026000005()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  NULL;
END;
$$;

COMMENT ON FUNCTION public.supabase_deploy_completed_20261026000005() IS
  'No-op marker. Exists only so the repo can name the exact deploy we both reached.';
