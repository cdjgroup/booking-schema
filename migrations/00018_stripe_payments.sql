-- 00018: Stripe payment collection — reserve-first flow
--
-- Adds payment tracking columns, updates the status CHECK constraint to
-- include 'pending_payment', modifies create_booking() to accept optional
-- status/stripe fields, and adds helper functions for webhook processing.

-- ---------------------------------------------------------------------------
-- 1. Update status CHECK constraint to include 'pending_payment'
-- ---------------------------------------------------------------------------

ALTER TABLE public.bookings DROP CONSTRAINT bookings_status_check;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_status_check
  CHECK (status IN ('confirmed', 'cancelled', 'completed', 'no_show', 'pending_payment'));

-- ---------------------------------------------------------------------------
-- 2. Add payment tracking columns
-- ---------------------------------------------------------------------------

ALTER TABLE public.bookings
  ADD COLUMN stripe_checkout_session_id TEXT DEFAULT NULL,
  ADD COLUMN stripe_payment_intent_id TEXT DEFAULT NULL,
  ADD COLUMN amount_paid_cents INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.bookings.stripe_checkout_session_id IS 'Stripe Checkout Session ID. Set at booking creation for paid services. Used by webhook to find the booking.';
COMMENT ON COLUMN public.bookings.stripe_payment_intent_id IS 'Stripe PaymentIntent ID. Set by webhook after payment succeeds. Used for refunds.';
COMMENT ON COLUMN public.bookings.amount_paid_cents IS 'Amount paid in cents. Copied from service price at booking time for display and refund calculations.';

-- Unique partial index for webhook lookups by checkout session ID.
-- The webhook receives the session ID and needs to find the booking quickly.
CREATE UNIQUE INDEX idx_bookings_stripe_session
  ON public.bookings(stripe_checkout_session_id)
  WHERE stripe_checkout_session_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Replace create_booking() to accept optional status + stripe fields
-- ---------------------------------------------------------------------------
-- The new parameters allow the booking flow to create bookings with
-- 'pending_payment' status and attach the Stripe session ID.
-- Default behavior (free bookings) is unchanged: status='confirmed'.

CREATE OR REPLACE FUNCTION public.create_booking(
  _business_id UUID,
  _service_id UUID,
  _staff_id UUID,
  _customer_name TEXT,
  _customer_email TEXT,
  _customer_phone TEXT DEFAULT NULL,
  _starts_at TIMESTAMPTZ DEFAULT NULL,
  _notes TEXT DEFAULT '',
  _status TEXT DEFAULT 'confirmed',
  _stripe_checkout_session_id TEXT DEFAULT NULL,
  _amount_paid_cents INTEGER DEFAULT 0
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  _duration_min INTEGER;
  _ends_at TIMESTAMPTZ;
  _customer_id UUID;
  _booking_id UUID;
BEGIN
  -- Validate status parameter
  IF _status NOT IN ('confirmed', 'pending_payment') THEN
    RAISE EXCEPTION 'Invalid booking status: %. Must be confirmed or pending_payment', _status;
  END IF;

  -- 1. Validate service: must exist, be active, and belong to the business
  SELECT duration_min INTO _duration_min
  FROM public.services
  WHERE id = _service_id
    AND business_id = _business_id
    AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service not found or inactive';
  END IF;

  -- 2. Validate staff: must exist, be active, and belong to the business
  IF NOT EXISTS (
    SELECT 1 FROM public.staff
    WHERE id = _staff_id
      AND business_id = _business_id
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Staff not found or inactive';
  END IF;

  -- 3. Validate starts_at
  IF _starts_at IS NULL THEN
    RAISE EXCEPTION 'starts_at is required';
  END IF;

  IF _starts_at <= NOW() THEN
    RAISE EXCEPTION 'Booking must be in the future';
  END IF;

  -- 4. Calculate end time from service duration
  _ends_at := _starts_at + (_duration_min || ' minutes')::INTERVAL;

  -- 5. Upsert customer (one record per email per business)
  INSERT INTO public.customers (business_id, name, email, phone)
  VALUES (_business_id, _customer_name, _customer_email, _customer_phone)
  ON CONFLICT (business_id, email)
  DO UPDATE SET
    name = EXCLUDED.name,
    phone = COALESCE(EXCLUDED.phone, public.customers.phone),
    updated_at = NOW()
  RETURNING id INTO _customer_id;

  -- 6. Create the booking (exclusion constraint handles double-booking check)
  INSERT INTO public.bookings (
    business_id, service_id, staff_id, customer_id,
    starts_at, ends_at, status, notes,
    stripe_checkout_session_id, amount_paid_cents
  ) VALUES (
    _business_id, _service_id, _staff_id, _customer_id,
    _starts_at, _ends_at, _status, COALESCE(_notes, ''),
    _stripe_checkout_session_id, _amount_paid_cents
  )
  RETURNING id INTO _booking_id;

  RETURN _booking_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. confirm_booking_payment() — called by checkout.session.completed webhook
-- ---------------------------------------------------------------------------
-- Finds booking by stripe_checkout_session_id, validates it's still
-- pending_payment, and confirms it with the payment_intent_id.
-- SECURITY DEFINER + SET search_path for SQL injection protection.
-- Called by the webhook route via a service-role Supabase client (bypasses RLS).
-- NOT granted to anon — only the service role and authenticated users can call this.
-- FOR UPDATE row lock prevents concurrent webhook deliveries from
-- double-processing.

CREATE OR REPLACE FUNCTION public.confirm_booking_payment(
  _stripe_checkout_session_id TEXT,
  _stripe_payment_intent_id TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  _booking_id UUID;
  _booking_status TEXT;
BEGIN
  -- Find and lock the booking
  SELECT id, status INTO _booking_id, _booking_status
  FROM public.bookings
  WHERE stripe_checkout_session_id = _stripe_checkout_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No booking found for checkout session %', _stripe_checkout_session_id;
  END IF;

  -- Idempotency: if already confirmed, return silently
  IF _booking_status = 'confirmed' THEN
    RETURN _booking_id;
  END IF;

  IF _booking_status <> 'pending_payment' THEN
    RAISE EXCEPTION 'Booking % is %, expected pending_payment', _booking_id, _booking_status;
  END IF;

  -- Confirm the booking and store payment intent for refunds
  UPDATE public.bookings
  SET
    status = 'confirmed',
    stripe_payment_intent_id = _stripe_payment_intent_id
  WHERE id = _booking_id;

  RETURN _booking_id;
END;
$$;

-- Only granted to authenticated (dashboard) — webhook uses service-role client
-- which bypasses grants entirely. NOT granted to anon to reduce attack surface.
GRANT EXECUTE ON FUNCTION public.confirm_booking_payment TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. expire_pending_booking() — called by checkout.session.expired webhook
-- ---------------------------------------------------------------------------
-- Cancels a pending_payment booking when the Stripe checkout session expires
-- (default 30 min). This releases the slot held by the GiST exclusion constraint.
-- Called by the webhook route via a service-role Supabase client.
-- NOT granted to anon — only the service role and authenticated users can call this.

CREATE OR REPLACE FUNCTION public.expire_pending_booking(
  _stripe_checkout_session_id TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  _booking_id UUID;
  _booking_status TEXT;
BEGIN
  -- Find and lock the booking
  SELECT id, status INTO _booking_id, _booking_status
  FROM public.bookings
  WHERE stripe_checkout_session_id = _stripe_checkout_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No booking found for checkout session %', _stripe_checkout_session_id;
  END IF;

  -- Idempotency: if already cancelled, return silently
  IF _booking_status = 'cancelled' THEN
    RETURN _booking_id;
  END IF;

  IF _booking_status <> 'pending_payment' THEN
    RAISE EXCEPTION 'Booking % is %, expected pending_payment', _booking_id, _booking_status;
  END IF;

  -- Cancel the booking to release the slot
  UPDATE public.bookings
  SET
    status = 'cancelled',
    cancelled_at = NOW(),
    cancel_reason = 'Payment not completed'
  WHERE id = _booking_id;

  RETURN _booking_id;
END;
$$;

-- Only granted to authenticated — webhook uses service-role client.
-- NOT granted to anon to reduce attack surface.
GRANT EXECUTE ON FUNCTION public.expire_pending_booking TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. get_booking_by_checkout_session() — for post-payment success page
-- ---------------------------------------------------------------------------
-- Returns booking details by Stripe checkout session ID. Used by the
-- success page after redirect from Stripe Checkout. Same shape as
-- get_booking_for_manage for consistency.

CREATE OR REPLACE FUNCTION public.get_booking_by_checkout_session(
  _stripe_checkout_session_id TEXT
)
RETURNS TABLE(
  id UUID,
  business_id UUID,
  business_name TEXT,
  business_slug TEXT,
  business_timezone TEXT,
  cancellation_window_hours INTEGER,
  service_id UUID,
  service_name TEXT,
  service_price_cents INTEGER,
  service_duration_min INTEGER,
  staff_id UUID,
  staff_name TEXT,
  customer_name TEXT,
  customer_email TEXT,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  status TEXT,
  notes TEXT,
  amount_paid_cents INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT
    b.id,
    b.business_id,
    biz.name AS business_name,
    biz.slug AS business_slug,
    biz.timezone AS business_timezone,
    biz.cancellation_window_hours,
    b.service_id,
    svc.name AS service_name,
    svc.price_cents AS service_price_cents,
    svc.duration_min AS service_duration_min,
    b.staff_id,
    stf.name AS staff_name,
    cust.name AS customer_name,
    cust.email AS customer_email,
    b.starts_at,
    b.ends_at,
    b.status,
    b.notes,
    b.amount_paid_cents
  FROM public.bookings b
  JOIN public.businesses biz ON biz.id = b.business_id
  JOIN public.services svc ON svc.id = b.service_id
  JOIN public.staff stf ON stf.id = b.staff_id
  JOIN public.customers cust ON cust.id = b.customer_id
  WHERE b.stripe_checkout_session_id = _stripe_checkout_session_id;
END;
$$;

-- Grant to anon since the success page is public (no auth required)
GRANT EXECUTE ON FUNCTION public.get_booking_by_checkout_session TO anon;
GRANT EXECUTE ON FUNCTION public.get_booking_by_checkout_session TO authenticated;
