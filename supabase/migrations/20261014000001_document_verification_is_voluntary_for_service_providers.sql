-- 20261014000001 — document verification is voluntary for service providers
-- =============================================================================
--
-- WHY
-- ---
-- Part 1 of the registration rework: document verification is OPTIONAL and
-- lives in the provider's Settings ("Verify Documents"). It must not block
-- posting a product or using the app. The only server rule in the way is the
-- DOCUMENTS_UNVERIFIED branch of provider_fulfilment_blockers() (20261006000003
-- restated 0113's gate and added WALLET_BELOW_MINIMUM).
--
-- WHAT CHANGES (one branch, one condition)
-- -----------------------------------------
-- provider_fulfilment_blockers() is restated from 20261006000003 with the
-- DOCUMENTS_UNVERIFIED branch wrapped in a provider-type test:
--
--   * SERVICE_PROVIDER — the document blocker is never raised. Posting,
--     accepting an order and app usage are open from the start (Part 1:
--     self-service registration is immediately active, documents are
--     voluntary). Verification still happens for anyone who uploads, and
--     staff-assisted signups are still held at PENDING_APPROVED-status by
--     20261014000000 until an administrator approves their documents, so the
--     approval requirement of the staff-assisted path is intact.
--
--   * VEHICLE_PROVIDER — the blocker is raised EXACTLY as before. The
--     ride/transportation flow is out of scope for this rework and its
--     document gate is deliberately untouched.
--
-- Every other blocker (ACCOUNT_NOT_APPROVED, ACTIVATION_FEE_UNPAID,
-- WALLET_EMPTY, WALLET_BELOW_MINIMUM, PROVIDER_NOT_FOUND) is byte-identical,
-- the function keeps its SECURITY DEFINER + search_path pinning, and its
-- GRANTs are unchanged. The `enforce_verified_documents` CEO switch still
-- decides whether the branch is consulted at all — this change only decides
-- WHICH providers the branch can block once it is on.
--
-- The static harness (check_provider_fulfilment_gate_is_wired) requires the
-- body to still NAME the DOCUMENTS_UNVERIFIED code; it does, inside the
-- vehicle-only branch.

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.provider_fulfilment_blockers(p_provider_id uuid)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id    uuid;
  v_status     text;
  v_fee_paid   boolean;
  v_balance    numeric;
  v_is_service boolean := false;
  v_allow_neg  boolean := public.get_setting_bool('allow_negative_wallet');
  v_enforce    boolean := public.get_setting_bool('enforce_verified_documents');
  v_min_wallet numeric := COALESCE(public.get_setting_numeric('posting_min_wallet_balance'), 0);
  v_post_fee   numeric := COALESCE(public.get_setting_numeric('posting_fee'), 0);
  v_required   numeric;
  v_out        text[] := '{}'::text[];
BEGIN
  IF p_provider_id IS NULL THEN
    RETURN ARRAY['PROVIDER_NOT_FOUND']::text[];
  END IF;

  SELECT pp.user_id, pp.status, pp.registration_fee_paid,
         (pp.provider_type = 'SERVICE_PROVIDER')
    INTO v_user_id, v_status, v_fee_paid, v_is_service
    FROM public.provider_profiles pp
   WHERE pp.id = p_provider_id;

  IF NOT FOUND THEN
    RETURN ARRAY['PROVIDER_NOT_FOUND']::text[];
  END IF;

  -- A suspended profile is already the subscription scheduler's own verdict
  -- (it sets SUSPENDED when the monthly fee cannot be paid), so that is the
  -- only status word worth giving: it names the cause, and it tells the
  -- provider to recharge rather than to contact support.
  IF v_status IS DISTINCT FROM 'APPROVED' THEN
    v_out := v_out || ARRAY[
      CASE WHEN v_status = 'SUSPENDED'
           THEN 'SUBSCRIPTION_UNPAID'
           ELSE 'ACCOUNT_NOT_APPROVED' END];
  END IF;

  IF COALESCE(v_fee_paid, false) IS NOT TRUE THEN
    v_out := v_out || ARRAY['ACTIVATION_FEE_UNPAID']::text[];
  END IF;

  -- 20261014000001: documents are voluntary for SERVICE_PROVIDERs (Verify
  -- Documents in Settings). The VEHICLE_PROVIDER branch keeps the gate
  -- exactly as it was — the ride flow is out of scope and untouched.
  IF v_enforce AND NOT public.provider_documents_verified(v_user_id) THEN
    IF NOT COALESCE(v_is_service, false) THEN
      v_out := v_out || ARRAY['DOCUMENTS_UNVERIFIED']::text[];
    END IF;
  END IF;

  -- The wallet, in two rules that share one read.
  SELECT balance INTO v_balance
    FROM public.wallets WHERE provider_id = p_provider_id;

  -- An unfunded provider cannot cover the platform fee, and the failure would
  -- otherwise surface at the moment a buyer is waiting. Unchanged from 0113.
  IF NOT v_allow_neg AND COALESCE(v_balance, 0) <= 0 THEN
    v_out := v_out || ARRAY['WALLET_EMPTY']::text[];
  END IF;

  -- The admin's posting minimum (20261006000003): the wallet must hold at
  -- least posting_min_wallet_balance AND enough headroom to cover the
  -- optional posting_fee. One code covers both knobs because the remedy is
  -- identical — recharge — and the app folds every WALLET_* code into the
  -- same checklist step. Runs even when allow_negative_wallet is on: that
  -- switch tolerates negative balances for fees, it does not waive the CEO's
  -- posting rule.
  v_required := GREATEST(v_min_wallet, COALESCE(v_post_fee, 0));
  IF v_required > 0 AND COALESCE(v_balance, 0) < v_required THEN
    v_out := v_out || ARRAY['WALLET_BELOW_MINIMUM']::text[];
  END IF;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.provider_fulfilment_blockers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_fulfilment_blockers(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.provider_fulfilment_blockers(uuid) IS
  'Every reason this provider may not post a listing, add a vehicle, claim a '
  'ride or accept an order. Empty array = may work. Exists so a refusal can '
  'name itself instead of saying "you cannot do that". Since 20261014000001 '
  'the DOCUMENTS_UNVERIFIED branch applies to VEHICLE_PROVIDERs only: '
  'document verification is voluntary for service providers (Settings → '
  'Verify Documents) and staff-assisted signups are held at PENDING_APPROVAL '
  'by the signup trigger instead.';
