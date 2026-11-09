-- =============================================================================
-- 20261108000001 — the checkout-approval state
-- =============================================================================
--
-- WHY A NEW STATUS AND NOT A REUSED ONE
-- -------------------------------------
-- The marketing change puts an admin decision between "the buyer submitted a
-- delivery checkout" and "the order is a real, paid order". None of the
-- existing order_status values mean that:
--
--   * PENDING_PROVIDER is the provider's queue (accept / reject the listing
--     order). Reusing it would put an approval question into a screen whose
--     buttons move the order somewhere else entirely.
--   * PAYMENT_VERIFICATION means the buyer has already paid and an admin is
--     checking the proof. The new queue decides whether the platform takes the
--     order at all, and it is also where the vehicle + driver are assigned.
--
-- So AWAITING_APPROVAL is added BEFORE PENDING_PROVIDER: a new order that
-- asks for approval starts there and only reaches the provider queue once an
-- admin has approved it. Orders from older app versions never enter it — they
-- are created straight into PENDING_PROVIDER exactly as they are today, which
-- is what keeps the builds already in testers' hands working.
--
-- ONE STATEMENT PER FILE, ON PURPOSE
-- ----------------------------------
-- PostgreSQL refuses to USE a new enum value in the same transaction that
-- added it. This file therefore only adds the value; every function that
-- names AWAITING_APPROVAL lives in 20261108000002, in the next transaction.
--
-- Deploy: this file must be applied BEFORE 20261108000002.
-- =============================================================================

ALTER TYPE public.order_status
  ADD VALUE IF NOT EXISTS 'AWAITING_APPROVAL' BEFORE 'PENDING_PROVIDER';

COMMENT ON TYPE public.order_status IS
  'Order lifecycle. AWAITING_APPROVAL is the admin checkout-approval gate for '
  'delivery orders submitted by the current app; older clients create orders '
  'directly in PENDING_PROVIDER and never use it.';
