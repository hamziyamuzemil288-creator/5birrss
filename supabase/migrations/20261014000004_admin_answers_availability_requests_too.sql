-- 20261014000004 — the admin may answer an availability request too
-- =============================================================================
--
-- WHY
-- ---
-- Part 5 of the rework. The pre-order availability gate (20261006000006)
-- delivers every "is this available?" exchange to the PROVIDER only:
-- respond_availability_request() refused anyone who was not the owning
-- provider ("NOT_YOUR_REQUEST"), and the admin queue
-- (admin_availability_screen) was read-only by construction — "an
-- administrator here is watching, not participating".
--
-- When a provider goes quiet, the buyer's 15-minute request expires and the
-- sale is lost even though the platform knows the answer. The request must
-- ALSO reach the administrator, who can answer it independently.
--
-- EITHER ANSWER IS ENOUGH — AND ONLY ONE CAN EVER LAND
-- ----------------------------------------------------
-- This is not "provider AND admin". The transition itself is the proof:
--
--   * the row is locked FOR UPDATE, its status is re-read after the lock,
--     and a row that is no longer PENDING is refused with
--     REQUEST_ALREADY_ANSWERED — so whoever answers first (provider OR
--     admin) decides, and the other party sees the answered row instead of a
--     second opinion;
--   * expiry still wins over both (REQUEST_EXPIRED), unchanged;
--   * the buyer is told the same way either way (the notify_best_effort call
--     below is byte-identical), and the order path
--     (create_order_secure) demands nothing more than an ACCEPTED,
--     unexpired, unused request — it does not know and does not care which
--     privileged human typed yes.
--
-- WHAT CHANGES (one condition)
-- ----------------------------
-- The ownership test gains `AND NOT public.is_admin()`: the caller must be
-- the owning provider OR an administrator. Everything else — the AUTH
-- requirement, the row lock, the PENDING re-check, the expiry check, the
-- reason handling, the UPDATE, the buyer notification, the GRANTs — is
-- reproduced byte-for-byte from 20261006000006.
--
-- Staff (sub-admin) accounts are deliberately NOT widened: the request
-- belongs to the provider and the platform's admin, and the staff permission
-- model has no scope for answering on a provider's behalf.
--
-- The client halves live in lib/ in this same release: the admin queue gains
-- Approve/Decline actions on PENDING rows, and BOTH the provider's and the
-- admin's request cards show the product's own cover photo (read from
-- product_images through the same lowest-sort_order rule the shared card
-- uses).

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.respond_availability_request(
  p_request_id uuid,
  p_accept boolean,
  p_reason text DEFAULT NULL
)
RETURNS public.availability_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_req public.availability_requests%ROWTYPE;
  v_name text;
  v_reason text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT * INTO v_req
    FROM public.availability_requests
   WHERE id = p_request_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'REQUEST_NOT_FOUND';
  END IF;

  -- 20261014000004: the owning provider OR an administrator. The PENDING
  -- re-check below is what makes "either" safe: both parties race for the
  -- same row, the loser is refused with REQUEST_ALREADY_ANSWERED, so an
  -- approval is always exactly one approval.
  IF NOT EXISTS (
    SELECT 1 FROM public.provider_profiles
     WHERE id = v_req.provider_id AND user_id = auth.uid()
  ) AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'NOT_YOUR_REQUEST';
  END IF;

  IF v_req.status <> 'PENDING' THEN
    RAISE EXCEPTION 'REQUEST_ALREADY_ANSWERED';
  END IF;

  IF v_req.expires_at <= now() THEN
    RAISE EXCEPTION 'REQUEST_EXPIRED';
  END IF;

  v_reason := CASE
    WHEN p_accept THEN NULL
    ELSE nullif(coalesce(btrim(p_reason), ''), '')
  END;

  UPDATE public.availability_requests
     SET status = CASE WHEN p_accept THEN 'ACCEPTED' ELSE 'REJECTED' END,
         responded_at = now(),
         reason = v_reason,
         updated_at = now()
   WHERE id = p_request_id
   RETURNING * INTO v_req;

  SELECT name INTO v_name FROM public.products WHERE id = v_req.product_id;

  PERFORM public.notify_best_effort(
    v_req.buyer_id,
    'AVAILABILITY_RESPONSE',
    CASE WHEN p_accept
         THEN 'Available — you can continue to checkout'
         ELSE 'Not available' END,
    CASE WHEN p_accept
         THEN coalesce(v_name, 'Your item') || ' is available. Continue to checkout within 15 minutes to complete your order.'
         ELSE coalesce(v_name, 'Your item') || ' is not available' ||
              coalesce(': ' || v_reason, '.') ||
              ' Find another provider.'
    END,
    jsonb_build_object(
      'availability_request_id', v_req.id,
      'product_id', v_req.product_id,
      'provider_id', v_req.provider_id,
      'accepted', p_accept,
      'reason', v_reason));

  RETURN v_req;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_availability_request(uuid, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_availability_request(uuid, boolean, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.respond_availability_request(uuid, boolean, text) IS
  'The owning provider OR an administrator accepts or declines a PENDING '
  'availability request (row-locked; a second answer and a late one are '
  'refused, so either party''s approval alone is sufficient and exactly one '
  'can land) and tells the buyer immediately.';
