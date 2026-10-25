-- =============================================================================
-- 20261025000003 — SMS and email are real preferences before they are real
-- channels
-- =============================================================================
--
-- The brief: "Keep SMS and email behind a simple on/off setting so they can be
-- added later."
--
-- `notification_preferences` (0001) has carried `push_enabled` and
-- `in_app_enabled` since the beginning, and `push_enabled` is already honoured
-- by fcm-dispatch (it loads the rows where push_enabled = false and excludes
-- them per recipient). What did not exist was any way for a person to CHANGE
-- either value: the account screen's "Notification Settings" row called
-- `_notBuiltYet`, so the setting was unreachable and the push opt-out was
-- effectively permanent-on.
--
-- Two things are added here, in the order a channel actually ships:
--
--   1. `sms_enabled` and `email_enabled`, both defaulting to FALSE. Nothing in
--      this deployment sends SMS or email, so a default of true would be a
--      promise the product cannot keep. They are stored so the preference
--      survives until the sender exists, and so the settings screen is honest
--      about what is on.
--   2. `save_notification_channels(...)` — one call that writes all four
--      switches from the settings screen.
--
-- WHY A NEW FUNCTION RATHER THAN A RESTATEMENT OF upsert_notification_preferences
-- -------------------------------------------------------------------------------
-- That function has a two-argument signature with defaults. Adding two
-- parameters to it would either (a) create a second overload, and PostgREST
-- then refuses the ambiguous call, or (b) require dropping and recreating it,
-- which breaks any caller that has not been updated in the same release. Since
-- nothing calls it yet (verified: no Dart, no test, no Edge Function), the
-- cleanest path is to leave the old callable in place and add a four-switch
-- function with a name that says what it does. There is then exactly one
-- writer per signature and no ambiguity.
--
-- in_app_enabled is deliberately NOT on the settings screen. The in-app row is
-- the record of what the platform told a person (and the audit trail behind it);
-- offering a switch that silently discards that record would make support
-- impossible. Its column stays for a future "hide the badge" behaviour that is
-- a display choice, not a storage one.
--
-- Deploy: needs a Supabase deploy (two columns, one function, one assertion).
-- =============================================================================

SET search_path = public, pg_temp;

ALTER TABLE public.notification_preferences
  ADD COLUMN IF NOT EXISTS sms_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.notification_preferences
  ADD COLUMN IF NOT EXISTS email_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.notification_preferences.sms_enabled IS
  'Stored preference for an SMS channel that has no sender yet. Default false: '
  'nothing sends SMS in this deployment.';

COMMENT ON COLUMN public.notification_preferences.email_enabled IS
  'Stored preference for an email channel that has no sender yet. Default '
  'false: nothing sends email in this deployment.';

CREATE OR REPLACE FUNCTION public.save_notification_channels(
  p_push_enabled boolean,
  p_sms_enabled boolean,
  p_email_enabled boolean
)
RETURNS public.notification_preferences
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_prefs public.notification_preferences;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  -- Only the caller's own row: there is no user id parameter, so there is
  -- nothing to point at somebody else.
  INSERT INTO public.notification_preferences AS np (
    user_id, push_enabled, in_app_enabled, sms_enabled, email_enabled)
  VALUES (v_user, coalesce(p_push_enabled, true), true,
          coalesce(p_sms_enabled, false), coalesce(p_email_enabled, false))
  ON CONFLICT (user_id) DO UPDATE SET
    push_enabled = coalesce(p_push_enabled, np.push_enabled),
    sms_enabled  = coalesce(p_sms_enabled, np.sms_enabled),
    email_enabled = coalesce(p_email_enabled, np.email_enabled)
  RETURNING * INTO v_prefs;

  RETURN v_prefs;
END;
$$;

COMMENT ON FUNCTION public.save_notification_channels(boolean, boolean, boolean) IS
  'Saves the signed-in account''s push/SMS/email switches. Push is consumed by '
  'fcm-dispatch; SMS and email are stored for senders that do not exist yet.';

REVOKE ALL ON FUNCTION public.save_notification_channels(boolean, boolean, boolean)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.save_notification_channels(boolean, boolean, boolean)
  TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'notification_preferences'
       AND column_name = 'sms_enabled'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'notification_preferences'
       AND column_name = 'email_enabled'
  ) THEN
    RAISE EXCEPTION '20261025000003 did not take: channel columns';
  END IF;

  -- A default of true would claim a channel this build cannot deliver.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'notification_preferences'
       AND column_name IN ('sms_enabled', 'email_enabled')
       AND column_default LIKE 'true%'
  ) THEN
    RAISE EXCEPTION '20261025000003: SMS/email must default to false';
  END IF;
END;
$$;
