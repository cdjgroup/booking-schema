-- 00011: SECURITY DEFINER function to compute available booking slots.
--
-- WHY a function instead of anon SELECT on bookings?
-- The bookings table intentionally has NO anonymous SELECT policy (to protect
-- customer PII). This function reads availability + bookings internally,
-- computes open time slots, and returns ONLY the available ranges.
-- Even if called directly, the caller only learns when slots are *available*,
-- never who booked what.

CREATE OR REPLACE FUNCTION public.get_available_slots(
  _staff_id UUID,
  _service_id UUID,
  _business_id UUID,
  _date DATE
)
RETURNS TABLE(slot_start TIMESTAMPTZ, slot_end TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  _duration_min INTEGER;
  _timezone TEXT;
  _day_of_week INTEGER;
  _window RECORD;
  _cursor TIMESTAMPTZ;
  _slot_end TIMESTAMPTZ;
  _window_end TIMESTAMPTZ;
BEGIN
  -- 1. Get service duration (validates service exists, is active, belongs to business)
  SELECT duration_min INTO _duration_min
  FROM public.services
  WHERE id = _service_id AND business_id = _business_id AND is_active = true;
  IF NOT FOUND THEN RETURN; END IF;

  -- 2. Get business timezone
  SELECT timezone INTO _timezone
  FROM public.businesses WHERE id = _business_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- 3. Get day of week in business timezone (0 = Sunday, matches JS Date.getDay())
  _day_of_week := EXTRACT(DOW FROM _date);

  -- 4. For each availability window on that day
  FOR _window IN
    SELECT start_time, end_time
    FROM public.availability
    WHERE staff_id = _staff_id AND day_of_week = _day_of_week
  LOOP
    -- Convert window times to TIMESTAMPTZ in business timezone
    _cursor := (_date + _window.start_time) AT TIME ZONE _timezone;
    _window_end := (_date + _window.end_time) AT TIME ZONE _timezone;

    -- Generate slots at 30-minute intervals
    WHILE _cursor + (_duration_min || ' minutes')::INTERVAL <= _window_end LOOP
      _slot_end := _cursor + (_duration_min || ' minutes')::INTERVAL;

      -- Check no overlapping non-cancelled bookings (half-open interval matches GiST constraint)
      IF NOT EXISTS (
        SELECT 1 FROM public.bookings
        WHERE staff_id = _staff_id
          AND status <> 'cancelled'
          AND starts_at < _slot_end
          AND ends_at > _cursor
      ) THEN
        -- Skip past slots
        IF _cursor > NOW() THEN
          slot_start := _cursor;
          slot_end := _slot_end;
          RETURN NEXT;
        END IF;
      END IF;

      _cursor := _cursor + INTERVAL '30 minutes';
    END LOOP;
  END LOOP;
END;
$$;

-- Grant to both anon (public booking page) and authenticated (dashboard preview)
GRANT EXECUTE ON FUNCTION public.get_available_slots TO anon;
GRANT EXECUTE ON FUNCTION public.get_available_slots TO authenticated;
