-- 20261014000005 — staff oversight: what each staff member actually brought in
-- =============================================================================
--
-- WHY
-- ---
-- Part 6 of the rework. Staff-assisted registration is recognised server-side
-- by provider_profiles.referred_by_staff_id (the existing tracking column that
-- 20260924000001 and 20261014000000 both key on — a VALID staff referral code
-- at signup is what makes a signup staff-assisted). The admins' staff screen
-- already shows each staff member's approvals, sales, orders and rides
-- (staff_performance / staff_progress), but it never showed the thing this
-- rework makes central: how many providers a staff member registered, and how
-- much trade those providers produced afterwards — the aggregate that tells
-- whether a registration was any good.
--
-- WHAT IS ADDED
-- --------------
-- staff_registration_stats(p_staff_id) — ONE row of real aggregates:
--
--   providers_registered — provider_profiles rows whose referred_by_staff_id
--                          is this staff member;
--   products_posted      — the total number of listings (products rows) those
--                          providers have posted. Counted from `products`
--                          directly, not from a cached column, so it cannot
--                          drift from the catalogue the app serves.
--
-- SECURITY DEFINER with the pinned search_path, like staff_performance. The
-- numbers are aggregates with no personal data in them, granted to
-- `authenticated` exactly as staff_performance has been since 20260922000001;
-- the screen that reads it is the admin staff workspace.
--
-- The client caller (admin_staff_screen's performance dialog) lives in lib/
-- in this same release.

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.staff_registration_stats(p_staff_id uuid)
RETURNS TABLE (providers_registered bigint, products_posted bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    (SELECT count(*)
       FROM public.provider_profiles pp
      WHERE pp.referred_by_staff_id = p_staff_id) AS providers_registered,
    (SELECT count(*)
       FROM public.products pr
       JOIN public.provider_profiles pp2 ON pp2.id = pr.provider_id
      WHERE pp2.referred_by_staff_id = p_staff_id) AS products_posted;
$$;

REVOKE ALL ON FUNCTION public.staff_registration_stats(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_registration_stats(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.staff_registration_stats(uuid) IS
  'Per-staff registration oversight: how many providers this staff member '
  'registered (provider_profiles.referred_by_staff_id) and how many products '
  'those providers have posted, counted live from `products`.';
