-- 20261014000000 — self-service registration is active on arrival
-- =============================================================================
--
-- WHY
-- ---
-- Every self-signup landed in PENDING_APPROVAL and waited for an administrator
-- (router redirect lib/routing/app_router.dart -> /pending-approval, status
-- written by handle_new_user, defended by the 0008 insert guards). The product
-- rule is now:
--
--   * SELF-SERVICE registration (anybody signing up in the app, user or
--     provider, with no valid staff referral code) creates an account that is
--     ACTIVE IMMEDIATELY. No admin wait, no pending screen. Registration is
--     already protected by the signup CAPTCHA, the required Privacy Policy
--     checkbox and (when enabled) the email OTP gate — that is the bar, not a
--     human approval queue.
--
--   * STAFF-ASSISTED registration (a staff member registers a provider on
--     their behalf, recognised by a VALID, ACTIVE staff referral code, which
--     handle_new_user resolves into provider_profiles.referred_by_staff_id —
--     the existing "registered_by_staff" tracking column) KEEPS the document
--     upload + admin approval requirement. Their provider_profiles row stays
--     PENDING_APPROVAL until an administrator approves it (approve_provider),
--     and provider_fulfilment_blockers() refuses every trading action with
--     ACCOUNT_NOT_APPROVED until then. The two paths cannot cross: an unknown
--     or blank code leaves referred_by_staff_id NULL and the signup is
--     ordinary self-service.
--
--   * Document verification is otherwise OPTIONAL and lives in the provider's
--     Settings ("Verify Documents"); it no longer blocks posting for
--     SERVICE_PROVIDERs (20261014000001). The VEHICLE_PROVIDER / ride gate is
--     deliberately untouched.
--
-- WHAT CHANGES (and nothing else)
-- --------------------------------
-- 1. prevent_profile_insert_privilege_escalation() and
--    prevent_provider_insert_privilege_escalation() (both from 0008) are
--    restated with ONE relaxation: a signup-time insert — GoTrue's own
--    connection carries no JWT, so auth.uid() IS NULL — may arrive as
--    APPROVED. A real client request always carries a JWT (RLS would not have
--    matched the row otherwise), so a signed-in caller is STILL refused
--    anything but PENDING_APPROVAL: the self-escalation door 0008 closed stays
--    closed. Every other clause of both guards is byte-identical.
--
-- 2. handle_new_user() is restated from 20260927000082 with the status choices
--    above, and — because approval used to be what created these two rows —
--    it now creates the provider's wallet and subscription directly for a
--    self-service provider, so the first posting cannot fail with
--    WALLET_NOT_FOUND. It also sends the keyed welcome
--    ("Welcome to Aliob") into the notifications panel through
--    notify_user_once, the same call approve_provider/approve_user use. The
--    OTP gate, the referral resolution and every other statement are
--    unchanged (the signup toggle must stay switchable back on — the static
--    harness asserts exactly that).
--
-- 3. handle_new_provider_profile() (0021) is restated so the approval request
--    it opens carries the same verdict as the row: APPROVED when the provider
--    arrived approved, PENDING_APPROVAL for a staff-assisted signup.
--
-- 4. on_registration_submitted() (20260927000130) is restated with a single
--    early return: it only announces rows that are actually PENDING. A
--    self-service signup that is born approved must not tell the applicant
--    "we received your application… waiting for review", and must not put a
--    phantom item in the admins' review queue. Every other line is
--    byte-identical.
--
-- NOT TOUCHED: submit_partner_application (an EXISTING user's upgrade still
-- inserts PENDING_APPROVAL and is still reviewed), approve/reject/suspend
-- flows, the ride/vehicle flows, the OTP gate itself, the 0008 user_id
-- clauses.

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The two insert guards, restated with the server-context relaxation.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.prevent_profile_insert_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
begin
  if not is_admin() then
    -- 20261014000000: the ONLY change. A signup insert runs on GoTrue's
    -- connection, where auth.uid() is NULL, and may be born APPROVED (Part 1:
    -- self-service registration is immediately active). A client request
    -- always carries a JWT, so the original PENDING-only rule still applies
    -- to every caller who could act on their own behalf.
    if auth.uid() is null then
      if new.status not in ('PENDING_APPROVAL', 'APPROVED') then
        raise exception 'PROFILES_MUST_START_AS_PENDING_APPROVAL_OR_APPROVED';
      end if;
    elsif new.status != 'PENDING_APPROVAL' then
      raise exception 'PROFILES_MUST_START_AS_PENDING_APPROVAL';
    end if;
  end if;
  return new;
end;
$$;

CREATE OR REPLACE FUNCTION public.prevent_provider_insert_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
begin
  if not is_admin() then
    -- 20261014000000: same single relaxation as the profiles guard, same
    -- reasoning. The user_id clause below is unchanged.
    if auth.uid() is null then
      if new.status not in ('PENDING_APPROVAL', 'APPROVED') then
        raise exception 'PROVIDER_PROFILES_MUST_START_AS_PENDING_APPROVAL_OR_APPROVED';
      end if;
    elsif new.status != 'PENDING_APPROVAL' then
      raise exception 'PROVIDER_PROFILES_MUST_START_AS_PENDING_APPROVAL';
    end if;
    -- Ensure user_id matches the current user
    if new.user_id != auth.uid() then
      raise exception 'CANNOT_CREATE_PROVIDER_PROFILE_FOR_ANOTHER_USER';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. handle_new_user() — the signup trigger, restated with the new statuses.
-- ---------------------------------------------------------------------------
-- Body basis: 20260927000082_signup_otp_is_a_toggle.sql (the live definition).
-- Changed statements are exactly: the profiles/USER-approval statuses, the
-- provider status (CASE on the referral), the RETURNING capture of the new
-- provider id, the wallet/subscription rows that approval used to create, and
-- the keyed welcome. The OTP gate and the referral resolution are reproduced
-- unchanged.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin_subject boolean;
  v_provider text;
  v_referral_code text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  v_referrer_staff_id uuid;
  v_referrer_name text;
  -- 20261014000000
  v_is_provider boolean := coalesce(new.raw_user_meta_data ->> 'provider_type', '') <> '';
  v_staff_assisted boolean := false;
  v_provider_id uuid;
  v_welcome_name text;
BEGIN
  v_provider := NULLIF(btrim(coalesce(new.raw_app_meta_data ->> 'provider', '')), '');

  -- Signup gate (unchanged from 20260927000082). Only signals that GoTrue has
  -- already written by the time this AFTER INSERT trigger runs may be trusted:
  --   * raw_app_meta_data->>'provider' is set on the model BEFORE the insert
  --     (signup.go ToUserModel / admin.go adminUserCreate), so it is the one
  --     durable marker of a real third-party OAuth subject. email/phone are
  --     excluded: they must still prove an OTP.
  --   * staff_gateway is honoured for any caller that does manage to set it
  --     at insert time, but the deployed gateway cannot (admin.go applies
  --     app_metadata after the insert) and pre-authorises through
  --     trust_staff_gateway_email() instead.
  --   * email_confirmed_at is deliberately NOT used as a trust signal: GoTrue
  --     confirms OAuth and admin-created users in a later UPDATE, so it is
  --     null here for exactly the two paths that need to pass.
  v_is_admin_subject := (
    (new.email_confirmed_at IS NOT NULL AND new.raw_user_meta_data IS NULL)
    OR COALESCE(new.raw_app_meta_data ->> 'staff_gateway', '') = 'true'
    OR (v_provider IS NOT NULL AND v_provider NOT IN ('email', 'phone'))
  );

  IF public.signup_otp_required()
     AND NOT v_is_admin_subject
     AND NOT public.otp_verified_recently(new.email) THEN
    RAISE EXCEPTION 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
  END IF;

  IF v_referral_code <> '' THEN
    SELECT c.staff_id, s.name
      INTO v_referrer_staff_id, v_referrer_name
      FROM public.referral_codes c
      JOIN public.staff s ON s.id = c.staff_id
     WHERE upper(btrim(c.code)) = v_referral_code
       AND c.is_active
       AND s.is_active
     LIMIT 1;
  END IF;

  -- 20261014000000: a VALID staff code is what makes a signup staff-assisted.
  -- A blank or unknown code is ordinary self-service — the two registration
  -- paths are separated by this one boolean and cannot cross.
  v_staff_assisted := v_is_provider AND v_referrer_staff_id IS NOT NULL;

  -- Part 1: the profile is created APPROVED for every self-signup. The login
  -- gate (router) reads profiles.status, so an immediately-active account is
  -- never bounced to /pending-approval. Staff-assisted providers also get an
  -- APPROVED profile row: their restriction is on provider_profiles.status
  -- (trading), and locking the login itself would stop the provider from
  -- ever uploading the documents their approval is waiting on.
  INSERT INTO public.profiles (id, full_name, phone, email, national_id, status, city, kebele, street_road)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'),
    COALESCE(new.phone, new.raw_user_meta_data ->> 'phone'),
    new.email,
    new.raw_user_meta_data ->> 'national_id',
    'APPROVED'::account_status,
    COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
    NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
    NULLIF(new.raw_user_meta_data ->> 'street_road', '')
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (new.id, 'USER'::app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- The review-queue row still exists so registration history keeps its
  -- channel data, but it is born CLOSED: there is nothing to review, and a
  -- PENDING row here would keep the account in the admins' pending counters.
  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  SELECT 'USER', new.id, 'APPROVED'::account_status
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = new.id
  );

  IF v_is_provider THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status, city, kebele, street_road,
       referral_code, referred_by_staff_id, referred_by_name)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,
      COALESCE(
        new.raw_user_meta_data ->> 'business_name',
        new.raw_user_meta_data ->> 'full_name',
        'New Provider'
      ),
      new.raw_user_meta_data ->> 'national_id',
      -- Staff-assisted: PENDING until an administrator approves the documents.
      -- Self-service: active immediately (Part 1).
      CASE WHEN v_staff_assisted
           THEN 'PENDING_APPROVAL'::account_status
           ELSE 'APPROVED'::account_status END,
      COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
      NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
      NULLIF(new.raw_user_meta_data ->> 'street_road', ''),
      CASE WHEN v_referrer_staff_id IS NULL AND v_referral_code <> '' THEN v_referral_code END,
      v_referrer_staff_id,
      v_referrer_name
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    )
    RETURNING id INTO v_provider_id;
  END IF;

  -- A self-service provider is ACTIVE on arrival, and approval used to be
  -- what gave an active provider the two rows every trading action reads.
  -- Without these the first posting fails with WALLET_NOT_FOUND at the
  -- moment the provider tries to work, so they are created here — idempotent,
  -- and identical to what approve_provider() writes.
  IF v_provider_id IS NOT NULL THEN
    INSERT INTO public.wallets (provider_id, balance)
    VALUES (v_provider_id, 0)
    ON CONFLICT (provider_id) DO NOTHING;

    INSERT INTO public.subscriptions (provider_id, status, next_due_date)
    VALUES (v_provider_id, 'ACTIVE', now() + interval '1 month')
    ON CONFLICT (provider_id) DO NOTHING;
  END IF;

  -- The welcome, from the same keyed call approve_provider/approve_user use,
  -- so a retried signup path cannot double-send and the notifications panel
  -- carries the same message the in-app banner shows.
  v_welcome_name := COALESCE(NULLIF(btrim(new.raw_user_meta_data ->> 'full_name'), ''), NULL);
  PERFORM public.notify_user_once(
    'signup-welcome:' || new.id::text,
    new.id,
    'APPROVAL',
    'Welcome to Aliob',
    CASE WHEN v_staff_assisted THEN
      'Welcome to Aliob' || COALESCE(', ' || v_welcome_name, '') ||
      '. Your account was created by our team and becomes active once your documents are reviewed.'
    ELSE
      'Welcome to Aliob' || COALESCE(', ' || v_welcome_name, '') ||
      '. Your account is ready — start browsing or set up your business profile.'
    END,
    jsonb_build_object(
      'event', 'signup_welcome',
      'staff_assisted', v_staff_assisted)
  );

  RETURN new;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. handle_new_provider_profile() — the approval request mirrors the row.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.handle_new_provider_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  -- 1. Assign the provider role (skip if already present)
  insert into public.user_roles (user_id, role)
  values (
    new.user_id,
    new.provider_type::app_role   -- 'VEHICLE_PROVIDER' or 'SERVICE_PROVIDER'
  )
  on conflict (user_id, role) do nothing;

  -- 2. Create the approval request (skip if one already exists for this
  --    provider). 20261014000000: its status mirrors the row it belongs to —
  --    a self-service signup is born APPROVED (Part 1), so its request is
  --    born closed; a staff-assisted signup stays PENDING_APPROVAL and IS the
  --    item an administrator reviews.
  insert into public.approval_requests (subject_type, subject_id, status)
  values ('PROVIDER', new.id,
          CASE WHEN new.status = 'APPROVED'
               THEN 'APPROVED'::account_status
               ELSE 'PENDING_APPROVAL'::account_status END)
  on conflict do nothing;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. on_registration_submitted() — announce real submissions only.
-- ---------------------------------------------------------------------------
-- Restated from 20260927000130 with ONE early return at the top of the body:
-- an approval_requests row that is born APPROVED is not a submission, so it
-- is announced to nobody. Every other line is byte-identical.

CREATE OR REPLACE FUNCTION public.on_registration_submitted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_name text;
  v_label text;
  v_sent integer := 0;
  v_recipient record;
BEGIN
  -- 20261014000000: a self-service signup is approved at birth, and its
  -- request row is closed at birth. Announcing that would tell the applicant
  -- their application is "waiting for review" (it is not) and would put a
  -- phantom item in every reviewer's queue. Only PENDING rows are
  -- submissions.
  IF NEW.status <> 'PENDING_APPROVAL' THEN
    RETURN NEW;
  END IF;

  -- A PROVIDER request is addressed by provider_profiles.id, not by user id.
  -- Getting this wrong would notify a stranger whose uuid happened to collide
  -- with a profile id, so the subject_type decides rather than a COALESCE
  -- that would silently fall through to the wrong branch.
  IF NEW.subject_type = 'PROVIDER' THEN
    SELECT pp.user_id, pp.business_name INTO v_user_id, v_name
      FROM public.provider_profiles pp
     WHERE pp.id = NEW.subject_id;
  ELSE
    SELECT pr.id, pr.full_name INTO v_user_id, v_name
      FROM public.profiles pr
     WHERE pr.id = NEW.subject_id;
  END IF;

  -- An approval_request can exist for a subject that has since been removed.
  -- notify_user_once already returns NULL for a NULL user, so there is nothing
  -- to guard here beyond not looking the name up for nobody.
  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_label := CASE
    WHEN NEW.subject_type = 'PROVIDER' THEN 'your business application'
    ELSE 'your account'
  END;

  -- TO THE PERSON WHO APPLIED. Silent submission is indistinguishable from a
  -- failed one, and the status screen behind the login gate is the only place
  -- they can look -- so this is the acknowledgement, not a courtesy.
  IF public.notify_user_safe(
       'registration-submitted:' || NEW.id::text,
       v_user_id,
       'REGISTRATION_RECEIVED',
       'We received your application',
       'Thank you. We have received ' || v_label || ' and it is waiting for '
         || 'review. We will let you know as soon as there is a decision.',
       jsonb_build_object(
         'approval_request_id', NEW.id,
         'subject_type', NEW.subject_type,
         'event', 'registration_submitted')
     ) THEN
    v_sent := v_sent + 1;
  END IF;

  -- TO EVERYONE WHO CAN ACT ON IT.
  FOR v_recipient IN
    SELECT r.user_id FROM public.registration_review_recipients() r
  LOOP
    IF public.notify_user_safe(
         'registration-queued:' || NEW.id::text || ':' || v_recipient.user_id::text,
         v_recipient.user_id,
         'REGISTRATION_RECEIVED',
         'An application is waiting for review',
         coalesce(NULLIF(btrim(v_name), ''), 'Someone')
           || ' submitted ' || v_label || '.',
         jsonb_build_object(
           'approval_request_id', NEW.id,
           'subject_type', NEW.subject_type,
           'user_id', v_user_id,
           'queue', 'registrations')
       ) THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  -- DEBUG only: a trigger has no caller to return a count to.
  RAISE DEBUG 'approval_request %: % notice(s) sent', NEW.id, v_sent;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  'Signup trigger. Since 20261014000000 a self-service signup (no valid staff '
  'referral code) creates an APPROVED profile and — for providers — an '
  'APPROVED provider_profiles row with its wallet and subscription, so the '
  'account is usable the moment it exists. A VALID staff referral code marks '
  'the signup staff-assisted: the provider row stays PENDING_APPROVAL until '
  'an administrator approves the documents. The OTP gate and the referral '
  'resolution are unchanged.';

COMMENT ON FUNCTION public.on_registration_submitted() IS
  'Announces a submitted application to the applicant and to every account '
  'that can review registrations. Reached through a trigger rather than a call '
  'in each submitting function, because the three submission paths converge on '
  'one INSERT and a per-caller call is a call the next caller forgets. Since '
  '20261014000000 it ignores rows born APPROVED: a self-service signup is not '
  'a submission and has nothing to review.';
