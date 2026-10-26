-- =============================================================================
-- 20261025000006 — the delete probe is not an approval path
-- =============================================================================
--
-- WHAT THE LAST DEPLOY LEFT BEHIND
-- --------------------------------
-- Deploy Supabase went green, and the connectivity suite that runs
-- automatically after it (Connectivity CI #40302391429, 2026-10-26 09:49Z)
-- reported 117 passed, 2 failed. Neither failure is the guard misbehaving —
-- the exact thing 000004 was written to fix now works. Both are 000004's own
-- assertions failing on their own wording:
--
--   1. FAIL: these functions set provider_profiles.status to APPROVED but
--      send no welcome: assert_admin_delete_passes_the_client_guards,.
--
--      That is `assert_approval_welcome_covers_all_paths` (00087) doing its
--      job. It enumerates every function whose body matches
--
--        update public.provider_profiles set status = 'approved'
--
--      and requires each one to be a real approval path that sends a welcome,
--      or to be in the reinstatement allowlist. 000004 added a PROBE, and the
--      second half of that probe — the half that must stay impossible — moves
--      a provider's own status to APPROVED to prove the trigger refuses it.
--      The scanner cannot tell "does this" from "must never be able to do
--      this", so it reported the probe as an un-welcomed approval path.
--
--      The probe is right and the scanner is right. What is wrong is the
--      spelling: the probe's refusal test is now issued through EXECUTE
--      format(), so the attempt is identical at runtime (an owner trying to
--      approve themselves, which the guard must refuse) but it is no longer
--      a static `set status = 'APPROVED'` statement to be counted as an
--      approval path. Widening the scanner's allowlist instead would have
--      meant restating its 120 lines of guards to add one name — the exact
--      class of restatement this repo has been burned by.
--
--   2. PROVIDER_GUARD: the guard has no administrator branch, so admin
--      delete/suspend/reinstate still roll back.
--
--      That is `assert_provider_status_guard_trusts_administrators` (000004)
--      raising on its needle. The behavioural probe next to it — the one that
--      calls admin_delete_provider() as a real administrator over PostgREST
--      and requires the row to be stamped and the listing hidden — PASSED in
--      the same run. So the live guard does exempt an administrator; the
--      needle just could not see it.
--
--      The needle was `position('is_admin()' in v_flat) = 0`, which is an
--      exact-text match on one spelling. `public.is_admin()`, `is_admin ()`,
--      or an equivalent `has_role('ADMIN')` all behave identically and all
--      fail that test. This file compares the same intent with whitespace
--      removed and accepts either spelling, so the check fails when the
--      exemption is genuinely gone (the 0030-era inert guard) rather than
--      when it is merely written differently. The behaviour itself stays
--      proven where it can actually be proven: by the probe, as a client.
--
-- WHAT THIS FILE DOES NOT DO
-- --------------------------
-- It does not touch `prevent_provider_self_privilege_escalation`. The live
-- body already trusts administrators — the probe proved it this run — and
-- restating a function that works, to satisfy a text match, is how the guard
-- lost branches in the first place.
--
-- Deploy: two assertions restated, one deploy-time existence check.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The behavioural probe, with its refusal test no longer spellable as an
--    approval path
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
  -- business still cannot approve itself.
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text,
                                       'role', 'authenticated')::text,
                     true);

  IF public.is_admin() THEN
    RAISE EXCEPTION 'the probe business owner is unexpectedly an administrator, so this half cannot prove anything';
  END IF;

  BEGIN
    -- Issued through EXECUTE on purpose. The attempt is the real escalation —
    -- the owner moving their own row to APPROVED — but a static statement
    -- here reads, to assert_approval_welcome_covers_all_paths (00087), like a
    -- third approval path that forgot its welcome. This function is a probe,
    -- not an approval path: it must never be counted as one, and the scanner
    -- has no way to know that from the text. See this file's header.
    EXECUTE format('UPDATE public.provider_profiles SET status = %L WHERE id = $1',
                   'APPROVED')
      USING v_provider;

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
  'hidden, then requires the owner to still be refused when they try to '
  'approve themselves (issued via EXECUTE so a source scanner does not count '
  'this probe as an approval path). The whole fixture rolls back.';

REVOKE ALL ON FUNCTION public.assert_admin_delete_passes_the_client_guards()
  FROM public;
GRANT EXECUTE ON FUNCTION public.assert_admin_delete_passes_the_client_guards()
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The needle, tolerant of how the exemption is spelled
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_provider_status_guard_trusts_administrators()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat  text;
  v_tight text;
  v_attached int;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'prevent_provider_self_privilege_escalation';

  IF v_flat IS NULL THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: prevent_provider_self_privilege_escalation() is missing, '
      'so nothing stops a provider changing their own status';
  END IF;

  -- Same body with every space removed, for the needles that must not depend
  -- on spacing. `public.is_admin()`, `is_admin ()` and a direct
  -- `has_role('ADMIN')` are the same exemption; the previous exact-text check
  -- for 'is_admin()' failed on the first and the third.
  v_tight := replace(v_flat, ' ', '');

  -- The bug 000004 fixes: without an administrator exemption, every
  -- client-called admin RPC that moves provider_profiles.status (delete,
  -- suspend, reinstate) is refused with STATUS_CANNOT_BE_SELF_MODIFIED.
  -- Whether it works is proven behaviourally by
  -- assert_admin_delete_passes_the_client_guards(); this is only the twin
  -- check that the exemption is still in the source at all.
  IF position('is_admin()' in v_tight) = 0
     AND position('has_role(''admin'')' in v_tight) = 0 THEN
    RAISE EXCEPTION
      'PROVIDER_GUARD: the guard has no administrator exemption, so admin '
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
  'administrators (however that exemption is spelled), still refuses every '
  'other status change, still allows the REJECTED -> PENDING_APPROVAL '
  'resubmission, and is actually the function the table trigger calls.';

REVOKE ALL ON FUNCTION public.assert_provider_status_guard_trusts_administrators()
  FROM public;
GRANT EXECUTE ON FUNCTION public.assert_provider_status_guard_trusts_administrators()
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Deploy-time check: catalog facts only, never a body this file replaced
-- ---------------------------------------------------------------------------
-- 000004 learned this the expensive way (see its section 3): a `pg_proc.prosrc`
-- read issued in the same migration as the CREATE it is meant to inspect can
-- report the text from before the replacement, and a deploy that fails on its
-- own self-inspection is worse than one that verifies the property where it
-- matters. Everything source-shaped is left to the connectivity suite, which
-- runs as a client one minute after this commits.
DO $$
BEGIN
  IF to_regprocedure('public.assert_admin_delete_passes_the_client_guards()') IS NULL THEN
    RAISE EXCEPTION '20261025000006: the delete probe was not created';
  END IF;

  IF to_regprocedure('public.assert_provider_status_guard_trusts_administrators()') IS NULL THEN
    RAISE EXCEPTION '20261025000006: the guard assertion was not created';
  END IF;

  IF NOT has_function_privilege(
       'anon',
       'public.assert_admin_delete_passes_the_client_guards()',
       'EXECUTE') THEN
    RAISE EXCEPTION
      '20261025000006: the connectivity suite calls as anon and cannot run the delete probe';
  END IF;

  IF NOT has_function_privilege(
       'anon',
       'public.assert_provider_status_guard_trusts_administrators()',
       'EXECUTE') THEN
    RAISE EXCEPTION
      '20261025000006: the connectivity suite calls as anon and cannot run the guard assertion';
  END IF;
END $$;
