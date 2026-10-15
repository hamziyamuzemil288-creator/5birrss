-- 20261014000006 — the self-approval probe keeps its PENDING_APPROVAL pre-state
-- =============================================================================
--
-- SYMPTOM
-- -------
-- Connectivity CI #5 — the first run after Deploy Supabase #5 finally applied
-- the pending migrations — failed its one behavioural test:
--
--   ❌ a user cannot approve their own account / a non-admin is refused when
--      they try to set their status to APPROVED (failed)
--   a non-admin was able to set their own profile status to APPROVED --
--   the guard did not fire
--
-- The guard had NOT failed. The probe had gone vacuous, and its message named
-- the wrong cause.
--
-- CAUSE
-- -----
-- assert_profile_self_approval_is_refused (20260927000028) builds its fixture
-- through auth.users:
--
--   INSERT INTO auth.users (id, email, email_confirmed_at)   -- fires
--   VALUES (...) ON CONFLICT (id) DO NOTHING;                -- handle_new_user()
--
--   INSERT INTO public.profiles (id, full_name, status)
--   VALUES (v_user, 'Self Approval Probe', 'PENDING_APPROVAL')
--   ON CONFLICT (id) DO NOTHING;                            -- silent no-op
--
-- When that file was written, handle_new_user() created the profile as
-- PENDING_APPROVAL, so the second insert was a harmless duplicate of the row
-- the trigger had just made, and the row the probe attacked really was
-- PENDING_APPROVAL.
--
-- 20261014000000 changed exactly that state: a self-service signup is APPROVED
-- on arrival, so handle_new_user() now creates this profile as APPROVED. The
-- fixture's own insert then hit ON CONFLICT (id) DO NOTHING — a silent no-op —
-- and the attack
--
--   UPDATE public.profiles SET status = 'APPROVED' WHERE id = v_user;
--
-- became a write of APPROVED over APPROVED. prevent_profile_self_privilege_
-- escalation() (restated by 20260927000028) compares new.status to old.status,
-- so there was no status change for it to refuse, and it correctly stayed
-- quiet. The probe then read the row back, found APPROVED, and reported the
-- guard as broken.
--
-- This is the failure mode the file's own header warns about, one level up: a
-- behavioural probe whose fixture has drifted proves nothing while still
-- reading as a finding. The guard's source, the trigger and the attack were
-- all intact; only the starting state was gone.
--
-- THE REPAIR, and nothing else
-- ----------------------------
--   * The fixture's own insert no longer says ON CONFLICT DO NOTHING, and it
--     is preceded by a DELETE of whatever the signup trigger left behind. The
--     row the attack runs against is now the one this function writes, or the
--     function raises — a conflict can no longer pass silently.
--   * The pre-state is READ BACK and verified before the attack, and a
--     non-PENDING_APPROVAL row is reported as what it is. The probe can never
--     again pass, or fail, vacuously.
--   * trg_profiles_security's attachment is checked too. If the guard trigger
--     is ever dropped or disabled, the attack below would succeed for that
--     reason instead, and the probe would report it as "the guard did not
--     fire". Both are red, but they are different repairs, and a message that
--     cannot tell them apart is a message that sends the next person to the
--     wrong file.
--
-- The attack, the profiles.city writability half, the sentinel rollback, the
-- DECLARE block, the COMMENT and the anon grant are unchanged.

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.assert_profile_self_approval_is_refused()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e601';
  v_status text;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'self-approval-probe@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  -- 20261014000006: the insert above fires handle_new_user(), which since
  -- 20261014000000 creates this profile as APPROVED. The probe needs the row
  -- it attacks to start PENDING_APPROVAL, so the signup-produced row goes
  -- first and this function writes the pre-state itself.
  DELETE FROM public.profiles WHERE id = v_user;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Self Approval Probe', 'PENDING_APPROVAL');

  -- Read the pre-state back instead of assuming it. ON CONFLICT DO NOTHING used
  -- to hide a fixture that was already APPROVED, which made the attack a no-op
  -- and turned this assertion into a false finding against a guard that works.
  SELECT status::text INTO v_status FROM public.profiles WHERE id = v_user;
  IF v_status IS DISTINCT FROM 'PENDING_APPROVAL' THEN
    RAISE EXCEPTION 'the self-approval probe could not be put in its PENDING_APPROVAL pre-state (it is %), so this assertion cannot prove anything', coalesce(v_status, 'absent');
  END IF;

  -- And the guard trigger has to be there for the attack below to mean what it
  -- says. Without it the UPDATE succeeds because nothing is watching, and the
  -- probe's own message would blame the guard's body instead.
  IF NOT EXISTS (SELECT 1
                   FROM pg_trigger t
                   JOIN pg_class c ON c.oid = t.tgrelid
                  WHERE t.tgname = 'trg_profiles_security'
                    AND c.oid = 'public.profiles'::regclass
                    AND NOT t.tgisinternal
                    AND t.tgenabled <> 'D') THEN
    RAISE EXCEPTION 'trg_profiles_security is not attached to public.profiles, so the self-approval attack below would succeed for the wrong reason';
  END IF;

  -- Act as that user. Non-admin, which is the whole point.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  IF public.is_admin() THEN
    RAISE EXCEPTION 'the probe user is unexpectedly an admin, so this test cannot prove anything';
  END IF;

  -- The attack: approve your own account.
  BEGIN
    UPDATE public.profiles SET status = 'APPROVED' WHERE id = v_user;

    SELECT status::text INTO v_status FROM public.profiles WHERE id = v_user;
    IF v_status = 'APPROVED' THEN
      RAISE EXCEPTION 'a non-admin was able to set their own profile status to APPROVED -- the guard did not fire';
    END IF;

    -- The UPDATE was rolled back by the subtransaction, which is itself a
    -- failure: it means the row changed before the guard stopped it.
    RAISE EXCEPTION 'a non-admin UPDATE of profiles.status was not refused';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a non-admin was able to set their own profile status to APPROVED -- the guard did not fire'
         OR SQLERRM = 'a non-admin UPDATE of profiles.status was not refused' THEN
        RAISE;
      END IF;
      -- Any other error is the refusal we wanted.
      NULL;
  END;

  -- The guard must not be a blanket block: a non-privileged column still has
  -- to be writable, or CityService and the profile editor break.
  BEGIN
    UPDATE public.profiles SET city = 'Addis Ababa' WHERE id = v_user;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'a non-admin could not update profiles.city: %', SQLERRM;
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

COMMENT ON FUNCTION public.assert_profile_self_approval_is_refused() IS
  'Performs the self-approval attack as a non-admin and requires the database '
  'to refuse it, then requires an ordinary column still to be writable. '
  'Behavioural by necessity: the inert guard this replaces passed every '
  'source-text check in the suite. Since 20261014000006 the PENDING_APPROVAL '
  'pre-state is written and then read back by this function rather than '
  'inherited from handle_new_user(), which now creates it APPROVED, and the '
  'guard trigger''s attachment is asserted, so the probe cannot go '
  'vacuous or report a missing trigger as a failed guard.';

GRANT EXECUTE ON FUNCTION public.assert_profile_self_approval_is_refused() TO anon, authenticated;
