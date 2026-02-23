-- 00009: Bookings table (the core appointment entity)

CREATE TABLE public.bookings (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  service_id    UUID NOT NULL REFERENCES public.services(id) ON DELETE RESTRICT,
  staff_id      UUID NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  customer_id   UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  starts_at     TIMESTAMPTZ NOT NULL,
  ends_at       TIMESTAMPTZ NOT NULL,
  status        TEXT NOT NULL DEFAULT 'confirmed'
                CHECK (status IN ('confirmed', 'cancelled', 'completed', 'no_show')),
  notes         TEXT DEFAULT '',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT valid_booking_range CHECK (ends_at > starts_at)
);

COMMENT ON TABLE public.bookings IS 'Appointment bookings. Uses TIMESTAMPTZ for absolute UTC moments.';
COMMENT ON COLUMN public.bookings.status IS 'Text + CHECK instead of enum to avoid ALTER TYPE migration pain.';

-- Exclusion constraint: prevent double-booking for the same staff member.
-- Two bookings overlap if their time ranges overlap AND neither is cancelled.
-- btree_gist extension enables this -- it combines equality (=) and range (&&) checks.
-- This is a database-level guarantee that no two non-cancelled bookings for the
-- same staff member can overlap in time.
ALTER TABLE public.bookings
  ADD CONSTRAINT no_double_booking
  EXCLUDE USING gist (
    staff_id WITH =,
    tstzrange(starts_at, ends_at) WITH &&
  )
  WHERE (status <> 'cancelled');

CREATE INDEX idx_bookings_business ON public.bookings(business_id);
CREATE INDEX idx_bookings_service ON public.bookings(service_id);
CREATE INDEX idx_bookings_staff ON public.bookings(staff_id);
CREATE INDEX idx_bookings_customer ON public.bookings(customer_id);
CREATE INDEX idx_bookings_starts_at ON public.bookings(starts_at);
CREATE INDEX idx_bookings_status ON public.bookings(business_id, status) WHERE status = 'confirmed';
-- Composite index for dashboard calendar queries (business + time range)
CREATE INDEX idx_bookings_calendar ON public.bookings(business_id, starts_at) WHERE status <> 'cancelled';

CREATE TRIGGER set_bookings_updated_at
  BEFORE UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- RLS
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

-- Business owners can manage bookings
CREATE POLICY "Owners can read own bookings"
  ON public.bookings FOR SELECT
  TO authenticated
  USING (public.is_business_owner(business_id));

CREATE POLICY "Owners can update own bookings"
  ON public.bookings FOR UPDATE
  TO authenticated
  USING (public.is_business_owner(business_id))
  WITH CHECK (public.is_business_owner(business_id));

CREATE POLICY "Owners can delete own bookings"
  ON public.bookings FOR DELETE
  TO authenticated
  USING (public.is_business_owner(business_id));

-- No anonymous INSERT or SELECT policies on bookings directly.
-- Anonymous booking is handled via the create_booking() SECURITY DEFINER function
-- below, which validates all inputs atomically.

-- Secure booking creation function for the public booking flow.
-- Validates that the service and staff exist, are active, and belong to the
-- business. Upserts the customer record and creates the booking in one transaction.
-- Returns the new booking ID on success; raises an exception on failure.
-- Callable by anonymous users (the function itself bypasses RLS via SECURITY DEFINER).
CREATE OR REPLACE FUNCTION public.create_booking(
  _business_id UUID,
  _service_id UUID,
  _staff_id UUID,
  _customer_name TEXT,
  _customer_email TEXT,
  _customer_phone TEXT DEFAULT NULL,
  _starts_at TIMESTAMPTZ DEFAULT NULL,
  _notes TEXT DEFAULT ''
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
    starts_at, ends_at, status, notes
  ) VALUES (
    _business_id, _service_id, _staff_id, _customer_id,
    _starts_at, _ends_at, 'confirmed', COALESCE(_notes, '')
  )
  RETURNING id INTO _booking_id;

  RETURN _booking_id;
END;
$$;

-- Grant execute to anonymous users (the public booking page)
GRANT EXECUTE ON FUNCTION public.create_booking TO anon;
GRANT EXECUTE ON FUNCTION public.create_booking TO authenticated;
