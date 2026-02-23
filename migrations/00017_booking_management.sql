-- 00017: Booking management — cancel and reschedule support
--
-- Adds columns for cancellation tracking, configurable cancellation window,
-- and SECURITY DEFINER functions for cancel/reschedule operations.

-- ---------------------------------------------------------------------------
-- 1. Add cancellation columns to bookings
-- ---------------------------------------------------------------------------

ALTER TABLE public.bookings
  ADD COLUMN cancelled_at TIMESTAMPTZ DEFAULT NULL,
  ADD COLUMN cancel_reason TEXT DEFAULT NULL;

COMMENT ON COLUMN public.bookings.cancelled_at IS 'Timestamp when booking was cancelled. NULL for non-cancelled bookings.';
COMMENT ON COLUMN public.bookings.cancel_reason IS 'Optional reason provided by the person who cancelled.';

-- Partial index for queries filtering by cancellation date
CREATE INDEX idx_bookings_cancelled_at
  ON public.bookings(cancelled_at)
  WHERE cancelled_at IS NOT NULL;

-- Partial index for queries filtering active (non-cancelled) bookings by status
CREATE INDEX idx_bookings_status_active
  ON public.bookings(status)
  WHERE status <> 'cancelled';

-- ---------------------------------------------------------------------------
-- 2. Add configurable cancellation window to businesses
-- ---------------------------------------------------------------------------

ALTER TABLE public.businesses
  ADD COLUMN cancellation_window_hours INTEGER NOT NULL DEFAULT 24;

COMMENT ON COLUMN public.businesses.cancellation_window_hours IS 'Minimum hours before appointment that cancellation/reschedule is allowed. 0 = always allowed.';

-- ---------------------------------------------------------------------------
-- 3. cancel_booking() — SECURITY DEFINER function
-- ---------------------------------------------------------------------------
-- Used by both dashboard (owner) and customer self-service flows.
-- Validates that the booking exists, is confirmed, within the cancellation
-- window, and that the caller is authorized (owner or anon via app layer).

CREATE OR REPLACE FUNCTION public.cancel_booking(
  _booking_id UUID,
  _cancel_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  _booking RECORD;
  _window_hours INTEGER;
BEGIN
  -- 1. Fetch booking with row lock to prevent concurrent modifications
  SELECT b.*, biz.cancellation_window_hours
  INTO _booking
  FROM public.bookings b
  JOIN public.businesses biz ON biz.id = b.business_id
  WHERE b.id = _booking_id
  FOR UPDATE OF b;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  -- 2. Authorization: authenticated users must own the business
  IF (SELECT auth.role()) = 'authenticated' THEN
    IF NOT public.is_business_owner(_booking.business_id) THEN
      RAISE EXCEPTION 'Not authorized to cancel this booking';
    END IF;
  END IF;

  -- 3. Validate status
  IF _booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Only confirmed bookings can be cancelled';
  END IF;

  -- 4. Check cancellation window
  _window_hours := _booking.cancellation_window_hours;
  IF _window_hours > 0 AND _booking.starts_at < (NOW() + (_window_hours || ' hours')::INTERVAL) THEN
    RAISE EXCEPTION 'Cancellation window has passed (% hours before appointment)', _window_hours;
  END IF;

  -- 5. Cancel the booking
  UPDATE public.bookings
  SET
    status = 'cancelled',
    cancelled_at = NOW(),
    cancel_reason = COALESCE(_cancel_reason, '')
  WHERE id = _booking_id;

  RETURN _booking_id;
END;
$$;

-- Grant to authenticated (dashboard) and anon (customer self-service via app-layer token validation)
GRANT EXECUTE ON FUNCTION public.cancel_booking TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_booking TO anon;

-- ---------------------------------------------------------------------------
-- 4. reschedule_booking() — SECURITY DEFINER function
-- ---------------------------------------------------------------------------
-- Cancels the old booking and creates a new one with the same details but
-- a new time. Uses FOR UPDATE to prevent concurrent reschedules.
-- Returns the NEW booking ID.

CREATE OR REPLACE FUNCTION public.reschedule_booking(
  _booking_id UUID,
  _new_starts_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  _booking RECORD;
  _window_hours INTEGER;
  _duration_min INTEGER;
  _new_ends_at TIMESTAMPTZ;
  _new_booking_id UUID;
BEGIN
  -- 1. Fetch booking with row lock to prevent concurrent modifications
  SELECT b.*, biz.cancellation_window_hours
  INTO _booking
  FROM public.bookings b
  JOIN public.businesses biz ON biz.id = b.business_id
  WHERE b.id = _booking_id
  FOR UPDATE OF b;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  -- 2. Authorization: authenticated users must own the business
  IF (SELECT auth.role()) = 'authenticated' THEN
    IF NOT public.is_business_owner(_booking.business_id) THEN
      RAISE EXCEPTION 'Not authorized to reschedule this booking';
    END IF;
  END IF;

  -- 3. Validate status
  IF _booking.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Only confirmed bookings can be rescheduled';
  END IF;

  -- 4. Check cancellation window
  _window_hours := _booking.cancellation_window_hours;
  IF _window_hours > 0 AND _booking.starts_at < (NOW() + (_window_hours || ' hours')::INTERVAL) THEN
    RAISE EXCEPTION 'Reschedule window has passed (% hours before appointment)', _window_hours;
  END IF;

  -- 5. Validate new time is in the future
  IF _new_starts_at <= NOW() THEN
    RAISE EXCEPTION 'New time must be in the future';
  END IF;

  -- 6. Get service duration to calculate new end time
  SELECT duration_min INTO _duration_min
  FROM public.services
  WHERE id = _booking.service_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service not found';
  END IF;

  _new_ends_at := _new_starts_at + (_duration_min || ' minutes')::INTERVAL;

  -- 7. Cancel old booking (releases the slot via status <> 'cancelled' exclusion)
  UPDATE public.bookings
  SET
    status = 'cancelled',
    cancelled_at = NOW(),
    cancel_reason = 'Rescheduled'
  WHERE id = _booking_id;

  -- 8. Create new booking with same details but new time
  INSERT INTO public.bookings (
    business_id, service_id, staff_id, customer_id,
    starts_at, ends_at, status, notes
  ) VALUES (
    _booking.business_id, _booking.service_id, _booking.staff_id, _booking.customer_id,
    _new_starts_at, _new_ends_at, 'confirmed', _booking.notes
  )
  RETURNING id INTO _new_booking_id;

  RETURN _new_booking_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reschedule_booking TO authenticated;
GRANT EXECUTE ON FUNCTION public.reschedule_booking TO anon;

-- ---------------------------------------------------------------------------
-- 5. get_booking_for_manage() — SECURITY DEFINER function
-- ---------------------------------------------------------------------------
-- Returns booking details with joined service/staff/business info.
-- Authenticated users: must own the business (multi-tenant isolation).
-- Anonymous users: the app layer validates a signed manage token before calling.
-- Defense-in-depth: UUID guessing alone is insufficient since UUIDs are 128-bit
-- random, and the app layer enforces token validation.

CREATE OR REPLACE FUNCTION public.get_booking_for_manage(
  _booking_id UUID
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
  notes TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Authorization: authenticated users must own the business
  IF (SELECT auth.role()) = 'authenticated' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.bookings b
      JOIN public.businesses biz ON biz.id = b.business_id
      WHERE b.id = _booking_id
        AND biz.owner_id = (SELECT auth.uid())
    ) THEN
      RAISE EXCEPTION 'Not authorized to view this booking';
    END IF;
  END IF;

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
    b.notes
  FROM public.bookings b
  JOIN public.businesses biz ON biz.id = b.business_id
  JOIN public.services svc ON svc.id = b.service_id
  JOIN public.staff stf ON stf.id = b.staff_id
  JOIN public.customers cust ON cust.id = b.customer_id
  WHERE b.id = _booking_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_booking_for_manage TO anon;
GRANT EXECUTE ON FUNCTION public.get_booking_for_manage TO authenticated;
