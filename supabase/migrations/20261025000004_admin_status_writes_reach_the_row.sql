-- =============================================================================
-- 20261025000004 — an administrator's status write finally reaches the row
-- =============================================================================
--
-- THE FAILURE THIS FIXES
-- ----------------------
-- Admin > Providers > Delete, confirmed, answered with the app's generic
-- sentence: "Could not delete this provider. Something went wrong. Please try
-- again." The server's real answer is `STATUS_CANNOT_BE_SELF_MODIFIED`, raised
-- by `prevent_provider_self_privilege_escalation` (BEFORE UPDATE ON
-- public.provider_profiles) on the statement that stamps `deleted_at`.
--
-- WHY IT HAPPENS
-- --------------
-- `admin_delete_provider()` is SECURITY DEFINER and is called with the
-- administrator's own JWT. By the only discriminator this schema has, that is
-- a CLIENT write: `is_server_write()` is
--
--     session_user IN ('postgres','supabase_admin')
--     OR current_setting('role') = 'service_role'
--
-- and PostgREST connects as `authenticator` and does `SET ROLE authenticated`,
-- so it is false for every call the app makes — SECURITY DEFINER only changes
-- `current_user`, never `session_user`. The function's own header says so.
--
-- 20260927000028 gave the wallet guard and the profiles guard a middle branch
-- for exactly this caller, and its header names all three callers a guard on a
-- table the server also writes has to tell apart: "server, verified privileged
-- client, everyone else". It did not give the provider_profiles guard one.
-- That guard therefore refuses EVERY status change it did not receive from the
-- server, including one an administrator has just authorised in a dialog. The
-- three statements before it — the inbox row, hiding the listings, dropping
-- the device tokens — are rolled back with it, so nothing is half-deleted and
-- the provider is exactly as they were.
--
-- The same wall stands in front of every other client-called RPC that moves
-- provider_profiles.status: `admin_suspend_account` and
-- `admin_reinstate_account` (Content Control) are the two reachable from the
-- app today. Provider approval does not hit it, because that path goes through
-- an Edge Function which calls as service_role.
--
-- THE FIX
-- -------
-- The same middle branch the wallet guard already has. An administrator is
-- trusted with the whole row — which is what the INSERT guard on this very
-- table already does (20261014000000: `if not is_admin() then … end if`), so
-- the UPDATE side is the only one still answering for one caller instead of
-- three. Nothing else changes:
--
--   * the server still passes on `is_server_write()`;
--   * a provider still cannot approve, reinstate or otherwise move their own
--     status — `is_admin()` is `has_role('ADMIN')`, and a provider has none;
--   * `provider_type`, the subscription dates and the national id are now
--     reachable by an administrator too, which is deliberate: they were only
--     ever protected from the account that owns them.
--
-- WHY A PROBE AND NOT JUST THE SOURCE CHECK
-- -----------------------------------------
-- `assert_provider_status_guard_is_client_scoped` (00029) reads `prosrc`. It
-- was written for a guard whose shape is now different, and it cannot tell a
-- guard that runs from a guard that returns on its first line — the inert
-- guard 0030/0033/0034 shipped with had every right-looking string in it.
--
-- So this file also adds `assert_admin_delete_passes_the_client_guards()`,
-- which does the real thing over PostgREST (session_user = authenticator,
-- which is the only context where the guard is engaged at all): it builds a
-- scratch administrator, a scratch business and one listing, calls
-- `admin_delete_provider()` exactly as the screen does, requires the row to be
-- stamped and the listing to be hidden, and then — the half that must NOT
-- become possible — requires a non-admin to still be refused when they try to
-- move the same status. Everything is inside one sentinel block, so the whole
-- fixture is gone before the function returns. It is called by the live
-- connectivity suite, not here: a migration runs as `postgres`, which makes
-- `is_server_write()` true and the guard a no-op, so a probe run at deploy
-- time would pass without testing anything.
--
-- Deploy: one restated function, one assertion, one deploy-time source check.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The guard, telling three callers apart instead of one
-- ---------------------------------------------------------------------------
--
-- Body basis: 20260927000028_close_privilege_escalation_restore_resubmit_admin_wallet.sql,
-- which is the live definition. The ONLY change is the administrator branch
-- after the server branch; every line of that body is still here, in order.
CREATE OR REPLACE FUNCTION public.prevent_provider_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  -- 20261025000004: the middle caller. A verified administrator acting from
  -- the admin console — deleting a business, suspending one, reinstating one —
  -- is trusted the way the INSERT guard on this table already trusts them
  -- (20261014000000). Without this branch the delete RPC raised
  -- STATUS_CANNOT_BE_SELF_MODIFIED on its own final UPDATE and rolled back
  -- everything it had done, and Content Control's suspend/reinstate did the
  -- same. `is_admin()` is has_role('ADMIN') on auth.uid(): a provider calling
  -- their own row is false here and still falls through to the refusal below.
  IF public.is_admin() THEN
    RETURN new;
  END IF;

  IF new.status IS DISTINCT FROM old.status THEN
    -- Resubmission after correcting a rejected application. Allowed since
    -- 0008 and dropped by 0019, which left profile_repository.resubmitProvider
    -- failing for every rejected provider. This one transition only:
    -- self-approval and every other change still raise below.
    IF NOT (old.status = 'REJECTED' AND new.status = 'PENDING_APPROVAL') THEN
      RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED';
    END IF;
  END IF;

  IF new.provider_type IS DISTINCT FROM old.provider_type THEN
    RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED';
  END IF;

  -- Read through JSONB rather than naming the column. A GENERATED column
  -- cannot be written directly, so this only fires when registration_date
  -- changes; and if the column is absent in a given schema, a missing JSONB
  -- key is NULL instead of a runtime error, which is what 0033 was guarding
  -- against when it dropped the direct comparison.
  IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name  = 'provider_profiles'
          AND column_name = 'subscription_start_date'
     )
     AND (to_jsonb(new) ->> 'subscription_start_date')
         IS DISTINCT FROM (to_jsonb(old) ->> 'subscription_start_date') THEN
    RAISE EXCEPTION 'SUBSCRIPTION_DATES_ARE_SERVER_MANAGED';
  END IF;

  IF old.owner_national_id IS NOT NULL
     AND new.owner_national_id IS DISTINCT FROM old.owner_national_id THEN
    RAISE EXCEPTION 'NATIONAL_ID_CANNOT_BE_CHANGED';
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.prevent_provider_self_privilege_escalation() IS
  'Stops a non-admin changing the status, provider type, subscription dates or '
  'national id of a provider_profiles row, and exempts server writes '
  '(is_server_write) and verified administrators (is_admin). The '
  'administrator branch is 20261025000004: without it every client-called '
  'admin RPC that moved provider_profiles.status died on this trigger.';

-- ---------------------------------------------------------------------------
-- 2. The behavioural proof, run by the live suite as a client
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_admin_delete_passes_the_client_guards()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_admin    uuid := '00000000-0000-4000-8000-00000000d001';
  v_owner    uuid := '00000000-0000-4000-8000-00000000d002';
  v_provider uuid := '00000000-0000-4000-8000-00000000d003';
  v_product  uuid := '00000000-0000-4000-8000-00000000d004';
  v_result   jsonb;
  v_deleted  timestamptz;
  v_visible  int;
BEGIN
  -- The two people: the administrator who presses Delete, and the owner of the
  -- business being deleted. Fixtures, rolled back by the sentinel below.
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_admin, 'admin-delete-probe@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_owner, 'provider-owner-delete-probe@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  -- An approved business with exactly one live listing, so the statement that
  -- used to be refused (the status update) and the one before it (hiding the
  -- listings, which passes through the product write gate) are both exercised.
  INSERT INTO public.provider_profiles (id, user_id, provider_type, business_name, status)
  VALUES (v_provider, v_owner, 'SERVICE_PROVIDER', 'Delete Probe', 'APPROVED')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.products (id, provider_id, name, price, is_active, is_available)
  VALUES (v_product, v_provider, 'Delete Probe Listing', 100, true, true)
  ON CONFLICT (id) DO NOTHING;

  -- Act as the administrator, exactly as PostgREST does for a signed-in call.
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text,
                                       'role', 'authenticated')::text,
                     true);

  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'the probe administrator has no ADMIN role, so this test cannot prove anything';
  END IF;

  -- The call the screen makes. If the guard still refuses an administrator,
  -- this line is where the failure surfaces — with its own message, not a
  -- generic sentence on somebody's phone.
  v_result := public.admin_delete_provider(v_provider, 'release readiness probe');

  SELECT deleted_at INTO v_deleted
    FROM public.provider_profiles
   WHERE id = v_provider;
  IF v_deleted IS NULL THEN
    RAISE EXCEPTION 'admin_delete_provider returned without stamping deleted_at';
  END IF;

  SELECT count(*) INTO v_visible
    FROM public.products
   WHERE provider_id = v_provider
     AND (is_active OR is_available);
  IF v_visible <> 0 THEN
    RAISE EXCEPTION 'admin_delete_provider left % listing(s) still visible', v_visible;
  END IF;

  -- And the half that must NOT have become possible: the account that owns the
  -- business still cannot move its own status.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text,
                                       'role', 'authenticated')::text,
                     true);

  IF public.is_admin() THEN
    RAISE EXCEPTION 'the probe business owner is unexpectedly an administrator, so this half cannot prove anything';
  END IF;

  BEGIN
    UPDATE public.provider_profiles
       SET status = 'APPROVED'
     WHERE id = v_provider;

    RAISE EXCEPTION 'a non-admin was able to move provider_profiles.status -- the guard did not fire';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'a non-admin was able to move provider_profiles.status -- the guard did not fire' THEN
      RAISE;
    END IF;
    -- Any other error is the refusal we wanted.
    NULL;
  END;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    RAISE;
END;
$$;

COMMENT ON FUNCTION public.assert_admin_delete_passes_the_client_guards() IS
  'Runs the real admin_delete_provider() over PostgREST as a scratch '
  'administrator and requires the business to be deleted and its listing '
  'hidden, then requires a non-admin to still be refused by the status guard. '
  'The whole fixture rolls back.';

REVOKE ALL ON FUNCTION public.assert_admin_delete_passes_the_client_guards()
  FROM public;
GRANT EXECUTE ON FUNCTION public.assert_admin_delete_passes_the_client_guards()
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The live assertion the connectivity suite calls
-- ---------------------------------------------------------------------------
--
-- WHY THE SOURCE CHECK IS NOT IN A DEPLOY-TIME DO BLOCK
-- ------------------------------------------------------
-- The first version of this migration inspected pg_proc.prosrc in a DO block
-- at the end of the file, and the deploy failed on it: the block read the body
-- the function had BEFORE this file replaced it (that body has
-- is_server_write() and the refusal but no administrator branch — exactly the
-- needle that tripped). A catalog read issued inside the same migration as the
-- CREATE it is meant to inspect is not a reliable view of the result, and a
-- deploy that fails on its own self-inspection is worse than one that verifies
-- the property where it actually matters.
--
-- So the check lives HERE, as an assertion the live suite calls as a client,
-- after the transaction has committed: it reads the guard a device will hit,
-- it checks that the trigger on provider_profiles really calls this function
-- (a guard nobody attached protects nothing), and it is exercised on every
-- deploy by connectivity_test.dart next to the behavioural delete probe.
CREATE OR REPLACE FUNCTION public.assert_provider_status_guard_trusts_administrators()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
  v_attached int;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'prevent_provider_self_privilege_escalation';

  IF v_flat IS NULL THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: prevent_provider_self_privilege_escalation() is missing, '
      'so nothing stops a provider changing their own status';
  END IF;

  -- The bug this migration fixes: without this branch, every client-called
  -- admin RPC that moves provider_profiles.status (delete, suspend,
  -- reinstate) is refused with STATUS_CANNOT_BE_SELF_MODIFIED.
  IF position('is_admin()' in v_flat) = 0 THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: the guard has no administrator branch, so admin '
      'delete/suspend/reinstate still roll back';
  END IF;

  -- The server exemption must go through the shared discriminator. Branching
  -- on current_user is what made the 0030-era guards inert.
  IF position('is_server_write' in v_flat) = 0
     OR position('current_user' in v_flat) > 0 THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: the server exemption no longer consults '
      'is_server_write(), or it branches on current_user again';
  END IF;

  -- And the refusal must still be there, or the branch was "fixed" by
  -- allowing everything.
  IF position('status_cannot_be_self_modified' in v_flat) = 0 THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: the refusal is gone, so a provider can change their own status';
  END IF;

  -- The documented resubmission transition, still permitted.
  IF position('old.status = ''rejected'' and new.status = ''pending_approval'''
              in v_flat) = 0 THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: the REJECTED -> PENDING_APPROVAL resubmission exemption '
      'disappeared, so rejected providers cannot resubmit';
  END IF;

  -- The guard must be the function the trigger actually calls.
  SELECT count(*) INTO v_attached
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
   WHERE t.tgrelid = 'public.provider_profiles'::regclass
     AND NOT t.tgisinternal
     AND p.proname = 'prevent_provider_self_privilege_escalation';

  IF v_attached = 0 THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: no trigger on provider_profiles calls the guard, so '
      'the administrator branch protects nothing';
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_provider_status_guard_trusts_administrators() IS
  'True when the provider_profiles status guard exempts server writes and '
  'verified administrators, still refuses every other status change, still '
  'allows the REJECTED -> PENDING_APPROVAL resubmission, and is actually the '
  'function the table trigger calls.';

REVOKE ALL ON FUNCTION public.assert_provider_status_guard_trusts_administrators()
  FROM public;
GRANT EXECUTE ON FUNCTION public.assert_provider_status_guard_trusts_administrators()
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Self-check: only catalog facts that the following statements create, and
--    no inspection of a body replaced above (see section 3).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('public.assert_admin_delete_passes_the_client_guards()') IS NULL THEN
    RAISE EXCEPTION '20261025000004: the delete probe was not created';
  END IF;

  IF to_regprocedure('public.assert_provider_status_guard_trusts_administrators()') IS NULL THEN
    RAISE EXCEPTION '20261025000004: the guard assertion was not created';
  END IF;

  IF NOT has_function_privilege(
       'anon',
       'public.assert_provider_status_guard_trusts_administrators()',
       'EXECUTE') THEN
    RAISE EXCEPTION
      '20261025000004: the connectivity suite calls as anon and cannot run the guard assertion';
  END IF;
END $$;
